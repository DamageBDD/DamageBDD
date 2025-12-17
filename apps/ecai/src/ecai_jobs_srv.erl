%%-------------------------------------------------------------------
%% ecai_jobs_srv.erl
%% - In-memory job manager for ECAI chunk mining jobs
%% - Wraps AE contract calls via damage_ae.erl
%% - Provides a clean API for HTTP + internal publishers
%%-------------------------------------------------------------------
-module(ecai_jobs_srv).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, stop/0]).
-export([
    % (OwnerAk, MarketCt, Paths, RewardDamage, TtlBlocks) -> {ok, JobIds}
    publish_chunks/5,
    % (FilterMap) -> Jobs
    list/1,
    % (JobId) -> {ok, Job} | {error, not_found}
    get/1,
    % (JobId, MinerAk) -> {ok, Job}
    claim/2,
    % (JobId, MinerAk, AttestationHexOrBin, EvidenceRefOpt) -> {ok, Job}
    submit/4,
    % (JobId, AdminAk) -> {ok, Job}
    pay/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(job, {
    %% local integer id
    id,
    %% os:system_time(second)
    created_at,
    %% <<"ak_...">>
    owner_ak,
    %% <<"ct_...">>
    market_ct,
    %% binary() local path or ipfs ref
    chunk_path,
    %% 32 bytes
    chunk_hash,
    %% integer (token base units)
    reward_damage,
    %% integer
    ttl_blocks,
    deadline_height = undefined,
    %% open | claimed | submitted | paid | cancelled
    status = open,
    miner_ak = undefined,
    attestation = undefined,
    evidence_ref = undefined,
    %% on-chain returned job id (if you return one)
    chain_job_id = undefined,
    chain_tx_hash = undefined
}).

-record(state, {
    next_id = 1,
    %% #{Id => #job{}}
    jobs = #{},
    %% #{ChunkHashBin => Id}
    by_hash = #{}
}).

%%% =========================
%%% Public API
%%% =========================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

stop() ->
    gen_server:call(?MODULE, stop).

publish_chunks(OwnerAk, MarketCt, Paths, RewardDamage, TtlBlocks) ->
    gen_server:call(
        ?MODULE, {publish_chunks, OwnerAk, MarketCt, Paths, RewardDamage, TtlBlocks}, 60000
    ).

list(Filter) ->
    gen_server:call(?MODULE, {list, Filter}).

get(Id) ->
    gen_server:call(?MODULE, {get, Id}).

claim(Id, MinerAk) ->
    gen_server:call(?MODULE, {claim, Id, MinerAk}).

submit(Id, MinerAk, Attestation, EvidenceRefOpt) ->
    gen_server:call(?MODULE, {submit, Id, MinerAk, Attestation, EvidenceRefOpt}).

pay(Id, AdminAk) ->
    gen_server:call(?MODULE, {pay, Id, AdminAk}, 60000).

%%% =========================
%%% gen_server
%%% =========================
init(_Init) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call(stop, _From, S) ->
    {stop, normal, ok, S};
handle_call({publish_chunks, OwnerAk0, MarketCt0, Paths0, RewardDamage, TtlBlocks}, _From, S0) ->
    OwnerAk = to_bin(OwnerAk0),
    MarketCt = to_bin(MarketCt0),
    Paths = [to_bin(P) || P <- Paths0],

    %% If you want chain deadline height, you can query it via damage_ae:get_ae_node/0+status,
    %% but we keep it simple here.

    {S1, Ids} =
        lists:foldl(
            fun(Path, {SAcc, IdAcc}) ->
                case new_job(SAcc, OwnerAk, MarketCt, Path, RewardDamage, TtlBlocks) of
                    {ok, SAcc1, JobId} ->
                        %% Optional: push create_job to chain here
                        %% If your market contract entrypoint is create_job(chunk_hash, chunk_ref, reward, ttl):
                        %% chain_create_job(OwnerAk, MarketCt, JobRec)
                        {SAcc1, [JobId | IdAcc]};
                    {error, _} = Err ->
                        ?LOG_WARNING("publish_chunks failed for ~p: ~p", [Path, Err]),
                        {SAcc, IdAcc}
                end
            end,
            {S0, []},
            Paths
        ),

    {reply, {ok, lists:reverse(Ids)}, S1};
handle_call({list, Filter}, _From, S = #state{jobs = Jobs}) ->
    %% Filter = #{status => open|claimed|..., miner_ak => <<"ak_...">>, owner_ak => ...}
    StatusF = maps:get(status, Filter, any),
    MinerF = maps:get(miner_ak, Filter, any),
    OwnerF = maps:get(owner_ak, Filter, any),
    L =
        [
            job_to_map(J)
         || {_Id, J} <- maps:to_list(Jobs),
            match_filter(J, StatusF, MinerF, OwnerF)
        ],
    {reply, {ok, L}, S};
handle_call({get, Id}, _From, S = #state{jobs = Jobs}) ->
    case maps:get(Id, Jobs, undefined) of
        undefined -> {reply, {error, not_found}, S};
        J -> {reply, {ok, job_to_map(J)}, S}
    end;
handle_call({claim, Id, MinerAk0}, _From, S0 = #state{jobs = Jobs}) ->
    MinerAk = to_bin(MinerAk0),
    case maps:get(Id, Jobs, undefined) of
        undefined ->
            {reply, {error, not_found}, S0};
        #job{status = open} = J0 ->
            J1 = J0#job{status = claimed, miner_ak = MinerAk},
            S1 = S0#state{jobs = maps:put(Id, J1, Jobs)},
            %% Optional: chain claim(job_id) here via damage_ae:contract_call_payfor_user/5
            {reply, {ok, job_to_map(J1)}, S1};
        #job{} ->
            {reply, {error, not_open}, S0}
    end;
handle_call({submit, Id, MinerAk0, Att0, Evidence0}, _From, S0 = #state{jobs = Jobs}) ->
    MinerAk = to_bin(MinerAk0),
    Att = normalize_attestation(Att0),
    Evidence = normalize_opt_bin(Evidence0),

    case maps:get(Id, Jobs, undefined) of
        undefined ->
            {reply, {error, not_found}, S0};
        #job{status = claimed, miner_ak = MinerAk} = J0 ->
            J1 = J0#job{status = submitted, attestation = Att, evidence_ref = Evidence},
            S1 = S0#state{jobs = maps:put(Id, J1, Jobs)},
            %% Optional: chain submit(job_id, attestation, evidence_ref)
            {reply, {ok, job_to_map(J1)}, S1};
        #job{status = claimed} ->
            {reply, {error, not_miner}, S0};
        #job{} ->
            {reply, {error, not_claimed}, S0}
    end;
handle_call({pay, Id, AdminAk0}, _From, S0 = #state{jobs = Jobs}) ->
    AdminAk = to_bin(AdminAk0),
    case maps:get(Id, Jobs, undefined) of
        undefined ->
            {reply, {error, not_found}, S0};
        #job{status = submitted, market_ct = MarketCt} = J0 ->
            %% Chain pay(JobId):
            %% damage_ae:contract_call_payfor_user(#{public_key=>AdminAk, private_key=>...}, MarketCt, "contracts/ECAIJobMarket.aes", "pay", [ChainJobId])
            %% You already have pay-for plumbing in damage_ae.erl :contentReference[oaicite:3]{index=3}
            %% For now: mark as paid locally.
            J1 = J0#job{status = paid},
            S1 = S0#state{jobs = maps:put(Id, J1, Jobs)},
            ?LOG_INFO("Paid job ~p by ~p via market ~p", [Id, AdminAk, MarketCt]),
            {reply, {ok, job_to_map(J1)}, S1};
        #job{} ->
            {reply, {error, not_submitted}, S0}
    end;
handle_call(Other, _From, S) ->
    ?LOG_WARNING("Unhandled call: ~p", [Other]),
    {reply, {error, unhandled}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Info, S) -> {noreply, S}.
terminate(_Reason, _S) -> ok.
code_change(_V, S, _E) -> {ok, S}.

%%% =========================
%%% Internal helpers
%%% =========================
new_job(
    S0 = #state{next_id = Id, jobs = Jobs, by_hash = ByHash},
    OwnerAk,
    MarketCt,
    Path,
    RewardDamage,
    TtlBlocks
) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Hash = crypto:hash(sha256, Bin),
            case maps:get(Hash, ByHash, undefined) of
                undefined ->
                    J = #job{
                        id = Id,
                        created_at = os:system_time(second),
                        owner_ak = OwnerAk,
                        market_ct = MarketCt,
                        chunk_path = Path,
                        chunk_hash = Hash,
                        reward_damage = RewardDamage,
                        ttl_blocks = TtlBlocks
                    },
                    S1 = S0#state{
                        next_id = Id + 1,
                        jobs = maps:put(Id, J, Jobs),
                        by_hash = maps:put(Hash, Id, ByHash)
                    },
                    {ok, S1, Id};
                _ExistingId ->
                    {error, duplicate_chunk}
            end;
        Err ->
            Err
    end.

match_filter(#job{} = J, StatusF, MinerF, OwnerF) ->
    (StatusF =:= any orelse J#job.status =:= StatusF) andalso
        (MinerF =:= any orelse J#job.miner_ak =:= MinerF) andalso
        (OwnerF =:= any orelse J#job.owner_ak =:= OwnerF).

job_to_map(#job{} = J) ->
    #{
        id => J#job.id,
        created_at => J#job.created_at,
        owner_ak => J#job.owner_ak,
        market_ct => J#job.market_ct,
        chunk_path => J#job.chunk_path,
        chunk_hash => hex(J#job.chunk_hash),
        reward_damage => J#job.reward_damage,
        ttl_blocks => J#job.ttl_blocks,
        deadline_height => J#job.deadline_height,
        status => atom_to_binary(J#job.status, utf8),
        miner_ak => J#job.miner_ak,
        attestation => maybe_hex(J#job.attestation),
        evidence_ref => J#job.evidence_ref,
        chain_job_id => J#job.chain_job_id,
        chain_tx_hash => J#job.chain_tx_hash
    }.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).

normalize_attestation(B) when is_binary(B), byte_size(B) =:= 32 -> B;
normalize_attestation(Hex) when is_binary(Hex) ->
    %% accept 64-char hex
    case byte_size(Hex) of
        64 -> hex_to_bin(Hex);
        _ -> Hex
    end;
normalize_attestation(L) when is_list(L) ->
    normalize_attestation(unicode:characters_to_binary(L)).

normalize_opt_bin(undefined) -> undefined;
normalize_opt_bin(null) -> undefined;
normalize_opt_bin(B) when is_binary(B) -> B;
normalize_opt_bin(L) when is_list(L) -> unicode:characters_to_binary(L).

hex(Bin) ->
    list_to_binary([io_lib:format("~2.16.0b", [X]) || <<X:8>> <= Bin]).

maybe_hex(undefined) -> undefined;
maybe_hex(Bin) -> hex(Bin).

hex_to_bin(HexBin) ->
    hex_to_bin(binary_to_list(HexBin), []).
hex_to_bin([], Acc) ->
    list_to_binary(lists:reverse(Acc));
hex_to_bin([A, B | Rest], Acc) ->
    V = list_to_integer([A, B], 16),
    hex_to_bin(Rest, [V | Acc]).
