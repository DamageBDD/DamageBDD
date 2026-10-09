%% Durable dashboard orchestration over the existing shard queue/reward ledger.
%% One coordinator; private trusted Erlang cluster; explicit bounded payment grant.
-module(ecai_index_pool).
-behaviour(gen_server).
-import(ecai_index_pool_util, [need/1, ensure/2, guarded/1, hash/1, field/2, object/1, text/1]).
-export([start_link/0, snapshot/0, quote/2, create/3, operation/3, control/4,
         authorized/3, register_plan/2, rpc/3, prepare/2, build_quote/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(st, {tab, data, runner = undefined, operation = undefined, timer}).
-define(TAB, ecai_index_pool_dets).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
snapshot() -> gen_server:call(?MODULE, snapshot, 5000).
quote(Actor, Body) -> gen_server:call(?MODULE, {quote, Actor, Body}, 10000).
create(Actor, Key, Body) -> gen_server:call(?MODULE, {create, Actor, Key, Body}, 30000).
operation(Actor, Action, Body) -> gen_server:call(?MODULE, {operation, Actor, Action, Body}, 5000).
control(Actor, Id, Action, Body) -> gen_server:call(?MODULE, {control, Actor, Id, Action, Body}, 10000).
authorized(Id, Mode, Contract) -> gen_server:call(?MODULE, {authorized, Id, Mode, Contract}, 5000).
register_plan(Actor, Path) ->
    %% Operator-shell import only. HTTP clients choose jobs, not filesystem paths.
    guarded(fun() ->
        admin(Actor), P = validate_plan(Path),
        need(gen_server:call(?MODULE, {register_plan, P}, 10000))
    end).

init([]) ->
    process_flag(trap_exit, true),
    File = filename:join(ecai_paths:state_dir(), "ecai/index-pool.dets"),
    ok = filelib:ensure_dir(File),
    {ok, Tab} = dets:open_file(?TAB, [{file, File}, {type, set}]),
    D = case dets:lookup(Tab, state) of
        [] -> #{schema => 1, plans => #{}, peers => #{}, jobs => #{}, channels => #{}, operation => null};
        [{state, #{schema := 1} = Saved}] -> Saved
    end,
    %% No channel opening/payment on init. Resume only previously granted jobs.
    S = #st{tab = Tab, data = D#{operation => null}},
    persist(S), _ = file:change_mode(File, 8#600),
    {ok, schedule(S)}.

handle_call(snapshot, _From, S) -> {reply, public(S#st.data), S};
handle_call({quote, A, B}, _From, S) ->
    {reply, guarded(fun() -> admin(A), quote_public(build_quote(A, B, S#st.data)) end), S};
handle_call({create, A, Key, B}, _From, S) ->
    case guarded(fun() ->
        admin(A), ensure(is_binary(Key) andalso byte_size(Key) > 0 andalso byte_size(Key) =< 128, invalid_idempotency_key),
        Q = build_quote(A, B, S#st.data),
        ensure(maps:get(quote_hash, Q) =:= maps:get(<<"quote_hash">>, B), quote_changed),
        ensure(maps:get(<<"confirm">>, B) =:= <<"create funded indexing job">>, confirmation_required),
        Id = hash({reward_campaign_v1, A, Key}),
        Jobs = maps:get(jobs, S#st.data),
        case maps:find(Id, Jobs) of
            {ok, Old} -> ensure(maps:get(quote_hash, Old) =:= maps:get(quote_hash, Q), idempotency_conflict), Old;
            error ->
                ensure(map_size(Jobs) < 32, pool_capacity),
                ensure(not lists:any(fun(J) -> maps:get(owner, J) =:= A andalso
                    maps:get(plan_id, J) =:= maps:get(plan_id, Q) end, maps:values(Jobs)), plan_already_contracted),
                Q#{id => Id, owner => A, key => Key, stage => draft, active => false,
                   auto_pay => false, results => #{}, created_at => erlang:system_time(second),
                   updated_at => erlang:system_time(second), cursor => 0, last_error => null}
        end
    end) of
        {ok, J} ->
            S1 = put_job(J, S), persist(S1),
            {reply, {ok, public_job(J)}, S1};
        E -> {reply, E, S}
    end;
handle_call({register_plan, Plan}, _From, S) ->
    Plans = maps:get(plans, S#st.data), Id = maps:get(id, Plan),
    S1 = S#st{data = (S#st.data)#{plans => Plans#{Id => Plan}}}, persist(S1),
    {reply, {ok, plan_public(Plan)}, S1};
handle_call({operation, A, Action, Body}, _From, #st{operation = undefined} = S) ->
    case guarded(fun() -> admin(A), ensure(lists:member(Action, [join, prepare, channels, reconcile, refund]), invalid_action) end) of
        {ok, _} ->
            Parent = self(), Ref = make_ref(), Data = S#st.data,
            {Pid, Mon} = spawn_opt(fun() ->
                Result = guarded(fun() -> run_operation(A, Action, Body, Data) end),
                Parent ! {operation_done, Ref, Result}
            end, [link, monitor]),
            Op = #{id => ecai_index_job_codec:id_hex(crypto:strong_rand_bytes(12)), kind => Action,
                   state => working, started_at => erlang:system_time(second)},
            S1 = S#st{operation = #{pid => Pid, mon => Mon, ref => Ref, actor => A, kind => Action},
                data = (S#st.data)#{operation => Op}}, persist(S1),
            {reply, {ok, Op}, S1};
        E -> {reply, E, S}
    end;
handle_call({operation, _, _, _}, _From, S) -> {reply, {error, operation_in_progress}, S};
handle_call({control, A, Id, Action, B}, _From, S) ->
    case guarded(fun() ->
        admin(A), J = maps:get(Id, maps:get(jobs, S#st.data)),
        ensure(maps:get(owner, J) =:= A, job_owner_required),
        ensure(maps:get(<<"quote_hash">>, B) =:= maps:get(quote_hash, J), quote_changed),
        case Action of
            pause -> J#{active => false, auto_pay => false, control_revision => maps:get(control_revision, J, 0) + 1};
            start ->
                C = need(ecai_index_rewards:campaign(Id)),
                ensure(maps:get(state, C) =:= funded, campaign_not_funded),
                Auto = maps:get(<<"auto_pay">>, B, false), ensure(is_boolean(Auto), invalid_auto_pay),
                Cfg = application:get_env(ecai, index_rewards_config, #{}),
                ensure(not Auto orelse maps:get(payments_enabled, Cfg, false) =:= true, payments_disabled),
                Confirmation = case Auto of true -> <<"start and pay verified segments">>; false -> <<"start funded indexing">> end,
                ensure(maps:get(<<"confirm">>, B, <<>>) =:= Confirmation, confirmation_required),
                J#{active => true, auto_pay => Auto, finished => false, control_revision => maps:get(control_revision, J, 0) + 1, authorization_at => erlang:system_time(second), last_error => null};
            _ -> throw({pool, invalid_action})
        end
    end) of
        {ok, J1} -> S1 = put_job(J1, S), persist(S1), {reply, {ok, public_job(J1)}, S1};
        E -> {reply, E, S}
    end;
handle_call({authorized, Id, Mode, Contract}, _From, S) ->
    Allowed = case maps:find(Id, maps:get(jobs, S#st.data)) of
        {ok, J} -> application:get_env(ecai, index_pool_enabled, false) =:= true andalso
            application:get_env(ecai, index_rewards_enabled, false) =:= true andalso
            maps:get(quote_hash, J) =:= Contract andalso maps:get(active, J, false)
            andalso ecai_node_admin:is_node_admin(maps:get(owner, J))
            andalso (Mode =/= pay orelse maps:get(auto_pay, J, false));
        error -> false
    end,
    {reply, Allowed, S};
handle_call(_, _From, S) -> {reply, {error, unsupported_call}, S}.
handle_cast(_, S) -> {noreply, S}.

handle_info(tick, #st{runner = undefined} = S) ->
    Jobs = maps:values(maps:get(jobs, S#st.data)),
    Runnable = [J || J <- Jobs, (maps:get(active, J, false) andalso not maps:get(finished, J, false)) orelse lists:member(maps:get(stage, J), [draft, awaiting_funding])],
    Sorted = lists:sort(fun(A, B) -> maps:get(last_tick, A, 0) =< maps:get(last_tick, B, 0) end, Runnable),
    S1 = case Sorted of
        [] -> S;
        [J | _] ->
            Parent = self(), Ref = make_ref(), Id = maps:get(id, J),
            {Pid, Mon} = spawn_opt(fun() ->
                Result = ecai_index_pool_runner:step(J),
                Parent ! {runner_done, Ref, Id, Result}
            end, [link, monitor]),
            S#st{runner = #{pid => Pid, mon => Mon, ref => Ref, id => Id, control_revision => maps:get(control_revision, J, 0)}}
    end,
    {noreply, schedule(S1)};
handle_info(tick, S) -> {noreply, schedule(S)};
handle_info({runner_done, Ref, Id, Result}, #st{runner = #{ref := Ref, mon := Mon, control_revision := Rev}} = S) ->
    erlang:demonitor(Mon, [flush]),
    J = maps:get(Id, maps:get(jobs, S#st.data)),
    %% Preserve concurrent Pause/Start decisions; a worker cannot restore grants.
    Next = case Result of
        {ok, Delta0} ->
            Delta = case Rev =:= maps:get(control_revision, J, 0) of
                true -> Delta0;
                false -> maps:remove(finished, Delta0)
            end,
            Merged = maps:merge(J, maps:without([active, auto_pay, authorization_at, control_revision], Delta)),
            case maps:get(finished, Merged, false) of
                true -> Merged#{active => false, auto_pay => false};
                false -> Merged
            end;
        {error, R} ->
            Stage = case maps:get(stage, J) of draft -> draft; awaiting_funding -> awaiting_funding; _ -> needs_attention end,
            J#{active => false, auto_pay => false, last_error => R, stage => Stage}
    end,
    S1 = put_job(Next#{last_tick => erlang:system_time(millisecond), updated_at => erlang:system_time(second)}, S#st{runner = undefined}),
    persist(S1), {noreply, S1};
handle_info({operation_done, Ref, Result}, #st{operation = #{ref := Ref, mon := Mon, kind := Kind}} = S) ->
    erlang:demonitor(Mon, [flush]),
    D = case Result of
        {ok, V} -> apply_operation(Kind, V, S#st.data);
        _ -> S#st.data
    end,
    Op0 = maps:get(operation, D),
    Op = case Result of {ok, _} -> Op0#{state => complete}; {error, R} -> Op0#{state => failed, error => R} end,
    S1 = S#st{operation = undefined, data = D#{operation => Op}}, persist(S1), {noreply, S1};
handle_info({'DOWN', Mon, process, _, _}, #st{runner = #{mon := Mon, id := Id}} = S) ->
    J = maps:get(Id, maps:get(jobs, S#st.data)),
    S1 = put_job(J#{active => false, auto_pay => false, last_error => runner_interrupted}, S#st{runner = undefined}),
    persist(S1), {noreply, S1};
handle_info({'DOWN', Mon, process, _, _}, #st{operation = #{mon := Mon}} = S) ->
    Op = (maps:get(operation, S#st.data))#{state => failed, error => operation_interrupted},
    S1 = S#st{operation = undefined, data = (S#st.data)#{operation => Op}}, persist(S1), {noreply, S1};
handle_info(_, S) -> {noreply, S}.

schedule(S) ->
    Ms = application:get_env(ecai, index_pool_tick_ms, 1000),
    ensure(is_integer(Ms) andalso Ms >= 250 andalso Ms =< 30000, invalid_pool_tick_ms),
    S#st{timer = erlang:send_after(Ms, self(), tick)}.
persist(S) -> ok = dets:insert(S#st.tab, {state, S#st.data}), ok = dets:sync(S#st.tab).
put_job(J, S) -> Jobs = maps:get(jobs, S#st.data), S#st{data = (S#st.data)#{jobs => Jobs#{maps:get(id, J) => J}}}.
terminate(_, S) ->
    erlang:cancel_timer(S#st.timer),
    lists:foreach(fun(undefined) -> ok; (#{pid := Pid}) -> exit(Pid, shutdown) end, [S#st.runner, S#st.operation]),
    dets:sync(S#st.tab), dets:close(S#st.tab), ok.
code_change(_, S, _) -> {ok, S}.
admin(A) -> ensure(ecai_node_admin:is_node_admin(A), node_admin_required).

run_operation(A, join, B, _Data) ->
    Name = maps:get(<<"node">>, B), N = ecai_index_pool_util:node_named(Name),
    Nonce = ecai_index_job_codec:id_hex(crypto:strong_rand_bytes(32)),
    Offer = need(rpc(N, offer, [node(), Nonce])),
    ensure(maps:get(nonce, Offer) =:= Nonce andalso maps:get(node_name, Offer) =:= Name
        andalso maps:get(coordinator, Offer) =:= atom_to_binary(node(), utf8), participation_challenge_mismatch),
    Binding = maps:with([account, lightning_node, network, node_name, pipeline_sha256, coordinator, nonce], Offer),
    Message = <<"ecai-index-pool:v1:", (hash(Binding))/binary>>,
    ensure(maps:get(message, Offer) =:= Message, participation_message_mismatch),
    Pubkey = maps:get(lightning_node, Offer),
    Checked = object(damage_cln:check_index_pool_message(Message, maps:get(signature, Offer), Pubkey)),
    ensure(field(verified, Checked) =:= true andalso field(pubkey, Checked) =:= Pubkey, lightning_identity_not_proven),
    Config = application:get_env(ecai, index_rewards_config, #{}),
    ensure(maps:get(network, Offer) =:= maps:get(network, Config, <<"regtest">>), lightning_network_mismatch),
    ensure(maps:get(pipeline_sha256, Offer) =:= ecai_index_pool_peer:pipeline(), worker_pipeline_mismatch),
    ensure(Pubkey =/= maps:get(treasury_node, Config), worker_is_treasury),
    ok = need(ecai_index_rewards:register_participant(A, maps:get(account, Offer), Pubkey)),
    Offer#{observed_at => erlang:system_time(second), enabled => true};
run_operation(A, prepare, B, _Data) -> prepare(A, maps:get(<<"job_id">>, B));
run_operation(_A, channels, _B, _Data) -> channel_snapshot();
run_operation(A, reconcile, B, Data) ->
    Id = maps:get(<<"id">>, B), J = maps:get(Id, maps:get(jobs, Data)),
    ensure(maps:get(owner, J) =:= A, job_owner_required),
    C = need(ecai_index_rewards:campaign(Id)),
    case [P || P <- maps:get(payouts, C), lists:member(maps:get(state, P), [uncertain, paying, retryable])] of
        [P | _] -> need(ecai_index_rewards:reconcile(A, Id, maps:get(id, P)));
        [] -> need(ecai_index_rewards:refresh_funding(A, Id))
    end;
run_operation(A, refund, B, Data) ->
    Id = maps:get(<<"id">>, B), J = maps:get(Id, maps:get(jobs, Data)),
    ensure(maps:get(owner, J) =:= A andalso not maps:get(active, J), pause_before_refund),
    ensure(maps:get(<<"confirm">>, B, <<>>) =:= <<"refund unallocated funds">>, confirmation_required),
    C = need(ecai_index_rewards:campaign(Id)),
    case maps:get(state, C) of closed -> ok; _ -> need(ecai_index_rewards:close(A, Id)) end,
    need(ecai_index_rewards:refund(A, Id)).
apply_operation(join, V, D) -> Ps = maps:get(peers, D), D#{peers => Ps#{maps:get(node_name, V) => V}};
apply_operation(prepare, V, D) -> Ps = maps:get(plans, D), D#{plans => Ps#{maps:get(id, V) => V}};
apply_operation(channels, V, D) -> D#{channels => V};
apply_operation(_, _, D) -> D.

rpc(N, Method, Args) ->
    ensure(N =:= node() orelse lists:member(N, application:get_env(ecai, indexing_worker_nodes, [])), node_not_operator_allowlisted),
    try case N =:= node() of
        true -> apply(ecai_index_pool_peer, Method, Args);
        false -> erpc:call(N, ecai_index_pool_peer, Method, Args, 15000)
    end catch _:_ -> {error, participant_unavailable} end.

prepare(A, Id) ->
    admin(A), J = need(ecai_index_jobs_srv:get(Id)),
    ensure(lists:member(maps:get(<<"state">>, J), [<<"paused">>, <<"canceled">>, <<"failed">>,
        <<"completed">>, <<"ready_to_mint">>, <<"minted">>]), stop_source_job_before_segmenting),
    S0 = need(ecai_index_job_codec:normalize_spec(maps:get(<<"spec">>, J))),
    Kind = maps:get(kind, S0),
    S1 = case Kind of
        wikipedia_jsonl -> S0;
        yelp_ndjson -> S0;
        wikimedia_visibility ->
            Result = maps:get(<<"result">>, J, #{}),
            ensure(is_map(Result), normalized_source_not_ready),
            M = maps:get(<<"material_files">>, Result, []),
            Paths = [maps:get(<<"path">>, F) || F <- M, maps:get(<<"role">>, F) =:= <<"normalized_records">>],
            ensure(Paths =/= [], normalized_source_not_ready),
            S0#{kind => wikipedia_jsonl, source => #{paths => Paths}, options => #{batch_size => 1}};
        _ -> throw({pool, unsupported_source_kind})
    end,
    lists:foreach(fun ecai_index_pool_util:shared_path/1, maps:get(paths, maps:get(source, S1))),
    Root = ecai_index_pool_util:shared_root(), Target = maps:get(target, S1),
    Spec = S1#{owner => A, target => Target#{mode => live_search, base_dir => text(filename:join(Root, "pool-output"))},
               finalize => #{auto_mint => false, build_nft_manifest => false, publish_ipfs => false}},
    Limits = application:get_env(ecai, index_pool_shard_limits,
        #{max_shard_bytes => 8388608, max_line_bytes => 2097152, max_lines_per_shard => 1000, max_shards => 256}),
    PlanPath = case ecai_index_shards:plan(Spec, filename:join(Root, "pool-plans"), Limits) of
        {ok, F, _} -> F;
        {error, {plan_already_exists, F}} -> F;
        {error, R} -> throw({pool, R})
    end,
    (validate_plan(PlanPath))#{source_job_id => Id}.
validate_plan(Path0) ->
    Path = ecai_index_pool_util:shared_path(Path0),
    Plan = need(ecai_index_shards:read_plan(Path)), Es = maps:get(entries, Plan),
    ensure(length(Es) > 0 andalso length(Es) =< 256, pool_plan_segment_limit),
    ensure(map_size(maps:get(receipts, Plan, #{})) =:= 0, plan_already_dispatched),
    Ordinals = [maps:get(ordinal, E) || E <- Es],
    {ok, _Terms, Units} = ecai_index_reward_contract:shards(Path, Ordinals, #{}),
    lists:foreach(fun(E) ->
        Ps = maps:get(paths, maps:get(source, maps:get(spec, E))),
        lists:foreach(fun ecai_index_pool_util:shared_path/1, Ps),
        ok = need(ecai_index_source:verify_paths(Ps, maps:get(source_identity, E))),
        ensure(maps:get(bytes, E) > 0, empty_segment)
    end, Es),
    #{id => maps:get(group_id, Plan), path => text(Path), plan => Plan, units => Units,
      label => text(maps:get(index_id, maps:get(target, maps:get(original_spec, Plan)))),
      prepared_at => erlang:system_time(second)}.

build_quote(A, B, D) ->
    PlanId = maps:get(<<"plan_id">>, B), P = maps:get(PlanId, maps:get(plans, D)),
    Ns = maps:get(<<"nodes">>, B),
    ensure(is_list(Ns) andalso Ns =/= [] andalso length(Ns) =< 16 andalso length(lists:usort(Ns)) =:= length(Ns), invalid_participant_selection),
    Sorted = lists:sort(Ns), Peers = maps:get(peers, D),
    Members = [begin
        _ = ecai_index_pool_util:node_named(N), V = maps:get(N, Peers),
        ensure(maps:get(enabled, V, false), participant_not_enabled),
        maps:with([node_name, account, lightning_node, network, pipeline_sha256], V)
    end || N <- Sorted],
    ensure(length(lists:usort([maps:get(account, V) || V <- Members])) =:= length(Members) andalso
        length(lists:usort([maps:get(lightning_node, V) || V <- Members])) =:= length(Members), duplicate_participant_identity),
    Cfg = application:get_env(ecai, index_rewards_config, #{}),
    Treasury = maps:get(treasury_node, Cfg), Network = maps:get(network, Cfg, <<"regtest">>),
    Refund = maps:get(<<"refund_node">>, B, maps:get(A, maps:get(participants, Cfg, #{}), undefined)),
    ensure(is_binary(Refund) andalso re:run(Refund, <<"^(02|03)[0-9a-f]{64}$">>, [{capture, none}]) =:= match, refund_lightning_node_required),
    ensure(Refund =/= Treasury, external_refund_wallet_required),
    Pipeline = ecai_index_pool_peer:pipeline(),
    ensure(lists:all(fun(V) -> maps:get(network, V) =:= Network andalso maps:get(pipeline_sha256, V) =:= Pipeline
        andalso maps:get(lightning_node, V) =/= Treasury andalso maps:get(account, V) =/= A
        andalso maps:get(lightning_node, V) =/= Refund end, Members), participant_identity_or_pipeline_changed),
    VPercent = maps:get(<<"verifier_percent">>, B, 0),
    ensure(VPercent =:= 0 orelse length(Members) >= 2, independent_verifier_node_required),
    Budget = need(ecai_index_pool_budget:quote(maps:get(units, P), maps:get(<<"budget_sats">>, B),
        VPercent, maps:get(<<"fee_sats">>, B, 1))),
    ensure(maps:get(budget_msat, Budget) =< maps:get(max_budget_msat, Cfg, 10000000), treasury_budget_limit),
    ensure(maps:get(fee_cap_msat, Budget) =< maps:get(max_fee_msat, Cfg, 1000), treasury_fee_limit),
    Local = #{node_name => atom_to_binary(node(), utf8), account => A, lightning_node => Refund,
              network => Network, pipeline_sha256 => Pipeline, unpaid_local_verifier => true},
    Units = maps:get(units, P),
    Assignments = maps:from_list([begin
        N = maps:get(ordinal, U), I = lists:nth(((N - 1) rem length(Members)) + 1, Members),
        V = case VPercent of 0 -> Local; _ -> lists:nth((N rem length(Members)) + 1, Members) end,
        {maps:get(id, U), #{ordinal => N, indexer => I, verifier => V}}
    end || U <- Units]),
    Contract = #{schema => <<"ecai-index-participation/v1">>, owner => A, plan_id => PlanId,
        budget => Budget, assignments => Assignments, refund_node => Refund,
        node_consents => [maps:get(N, Peers) || N <- Sorted],
        verification_policy => <<"full-independent-rebuild/v1">>,
        treasury_node => Treasury, network => Network},
    QuoteHash = hash(Contract),
    Terms = (maps:with([budget_msat, index_msat, verify_msat, fee_cap_msat, unit_prices], Budget))#{
        plan_root => PlanId, unit_ids => [maps:get(id, U) || U <- Units], participation_contract => QuoteHash,
        allocation_policy => <<"source-bytes-largest-remainder/v1">>},
    #{quote_hash => QuoteHash, plan_id => PlanId, label => maps:get(label, P),
      contract => Contract, terms => Terms, plan => maps:get(plan, P), units => Units}.

channel_snapshot() ->
    M = object(damage_cln:list_peerchannels()), Cs = field(channels, M), ensure(is_list(Cs), invalid_cln_response),
    #{observed_at => erlang:system_time(second), source => damage_cln,
      advisory_only => true, channels => [#{peer_id => field(peer_id, C), channel_id => field(channel_id, C),
        short_channel_id => field(short_channel_id, C), state => field(state, C), connected => field(peer_connected, C),
        spendable_msat => ecai_index_pool_util:msat(field(spendable_msat, C)),
        receivable_msat => ecai_index_pool_util:msat(field(receivable_msat, C))} || C <- Cs]}.
quote_public(Q) -> maps:with([quote_hash, plan_id, label, contract], Q).
plan_public(P) -> #{id => maps:get(id, P), label => maps:get(label, P), segments => length(maps:get(units, P)),
    source_bytes => lists:sum([maps:get(bytes, U) || U <- maps:get(units, P)]),
    source_job_id => maps:get(source_job_id, P, null)}.
public_job(J) -> maps:without([plan, key, terms], J).
public(D) -> D#{plans => [plan_public(P) || P <- maps:values(maps:get(plans, D))],
    jobs => [public_job(J) || J <- maps:values(maps:get(jobs, D))],
    peers => maps:values(maps:get(peers, D)), available_nodes => ecai_index_pool_util:node_names()}.
