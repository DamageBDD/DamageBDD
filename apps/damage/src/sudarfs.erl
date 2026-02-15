%%-------------------------------------------------------------------
%% sudarfs.erl
%%
%% SudarsanaFS: IPFS + ECAI + Æ channel commitments
%%
%% - Direct, internal API (no BDD feature layer)
%% - Stores data/files to IPFS via damage_ipfs
%% - Optionally calls an ECAI index function for each CID
%% - Batches entries and commits a root to an Æternity state channel
%%   via damage_channels:update_contract/5 on schedule or buffer limit.
%%
%% Configure:
%%  Opts = #{
%%      channel           := ChannelPid,          % required (damage_channels pid)
%%      ct                := <<"ct_job_registry">>, % AE contract id for commits
%%      ct_fun            := <<"commit_root">>,   % Sophia function name (binary)
%%      gas               := 100000,             % gas for off-chain call (logical)
%%
%%      index_fun         := {ecai_index, index_cid}, % Optional: M:F(Cid, Meta) -> ok | {ok, Id}
%%
%%      commit_interval_ms := 60000,             % Optional: periodic commit
%%      buffer_limit       := 100                % Optional: commit when N entries buffered
%%  }.
%%
%% Public API:
%%   start_link/1
%%   put/3          - store {data|file} + metadata
%%   commit_now/1   - force commit current buffer
%%   state/1        - inspect internal state
%%-------------------------------------------------------------------
-module(sudarfs).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% API
-export([
    start_link/1,
    put/3,
    commit_now/1,
    state/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    channel :: pid(),
    ct :: binary(),
    ct_fun :: binary(),
    gas :: non_neg_integer(),
    index_fun :: undefined | {module(), atom()} | fun((binary(), map()) -> any()),
    %% [#{cid := Cid, meta := Meta, ts := Ts}]
    buffer :: [map()],
    buffer_limit :: non_neg_integer(),
    commit_interval :: non_neg_integer(),
    timer_ref :: undefined | reference()
}).

%%===================================================================
%% API
%%===================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% @doc Store a thing into IPFS and enqueue for ECAI+channel commitment.
%% Spec:
%%   {data, Bin, FileName :: iodata()} | {file, Path :: iodata()}
-spec put(pid(), {data, binary(), iodata()} | {file, iodata()}, map()) ->
    {ok, map()} | {error, term()}.
put(Pid, Spec, Meta) when is_map(Meta) ->
    gen_server:call(Pid, {put, Spec, Meta}).

%% @doc Force a commit of the current buffer (even if below buffer_limit).
-spec commit_now(pid()) -> {ok, map()} | {error, term()}.
commit_now(Pid) ->
    gen_server:call(Pid, commit_now).

%% @doc Inspect current state (for debugging/metrics).
-spec state(pid()) -> map().
state(Pid) ->
    gen_server:call(Pid, state).

%%===================================================================
%% gen_server callbacks
%%===================================================================

init(Opts) when is_map(Opts) ->
    Channel = maps:get(channel, Opts),
    Ct = maps:get(ct, Opts),
    CtFun = maps:get(ct_fun, Opts, <<"commit_root">>),
    Gas = maps:get(gas, Opts, 100000),
    IndexFun = maps:get(index_fun, Opts, undefined),
    Interval = maps:get(commit_interval_ms, Opts, 0),
    BufLimit = maps:get(buffer_limit, Opts, 0),

    TimerRef =
        case Interval > 0 of
            true -> erlang:send_after(Interval, self(), commit_tick);
            false -> undefined
        end,

    S = #state{
        channel = Channel,
        ct = Ct,
        ct_fun = CtFun,
        gas = Gas,
        index_fun = IndexFun,
        buffer = [],
        buffer_limit = BufLimit,
        commit_interval = Interval,
        timer_ref = TimerRef
    },
    {ok, S}.

handle_call({put, Spec, Meta}, _From, S0) ->
    case do_ipfs_add(Spec) of
        {ok, Cid, RawResp} ->
            Ts = erlang:system_time(millisecond),
            Entry = #{cid => Cid, meta => Meta, ts => Ts},

            %% fire-and-forget ECAI index (best effort)
            ok = maybe_index(S0#state.index_fun, Cid, Meta),

            Buf1 = [Entry | S0#state.buffer],
            S1 = S0#state{buffer = Buf1},
            S2 = maybe_auto_commit(S1),
            {reply, {ok, #{cid => Cid, raw => RawResp}}, S2};
        {error, Reason} ->
            {reply, {error, Reason}, S0}
    end;
handle_call(commit_now, _From, S0) ->
    case do_commit(S0) of
        {ok, CommitInfo, S1} ->
            {reply, {ok, CommitInfo}, S1};
        {error, Reason, S1} ->
            {reply, {error, Reason}, S1}
    end;
handle_call(state, _From, S = #state{}) ->
    Map = #{
        channel => S#state.channel,
        ct => S#state.ct,
        ct_fun => S#state.ct_fun,
        gas => S#state.gas,
        buffer_len => length(S#state.buffer),
        buffer_limit => S#state.buffer_limit,
        commit_interval => S#state.commit_interval
    },
    {reply, Map, S};
handle_call(_Other, _From, S) ->
    {reply, {error, unknown_call}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(commit_tick, S0 = #state{commit_interval = Interval}) ->
    S1 =
        case do_commit(S0) of
            {ok, _CommitInfo, Sx} ->
                Sx;
            {error, _Reason, Sx} ->
                %% We log but keep running; next tick may succeed
                Sx
        end,
    %% re-arm timer
    TimerRef = erlang:send_after(Interval, self(), commit_tick),
    {noreply, S1#state{timer_ref = TimerRef}};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

code_change(_Vsn, S, _Extra) ->
    {ok, S}.

%%===================================================================
%% Internals
%%===================================================================

%% Add to IPFS via damage_ipfs

do_ipfs_add({data, Bin, FileName}) when is_binary(Bin) ->
    do_ipfs_add_inner({data, Bin, FileName});
do_ipfs_add({file, Path}) ->
    do_ipfs_add_inner({file, Path});
do_ipfs_add(Other) ->
    {error, {invalid_spec, Other}}.

do_ipfs_add_inner(Spec) ->
    case damage_ipfs:add(Spec) of
        {ok, [#{<<"Hash">> := Hash} | _] = List} ->
            {ok, Hash, List};
        {ok, []} ->
            {error, empty_ipfs_response};
        Error ->
            Error
    end.

%% Optional ECAI indexing

maybe_index(undefined, _Cid, _Meta) ->
    ok;
maybe_index({M, F}, Cid, Meta) ->
    spawn(fun() ->
        catch apply(M, F, [Cid, Meta])
    end),
    ok;
maybe_index(Fun, Cid, Meta) when is_function(Fun, 2) ->
    spawn(fun() ->
        catch Fun(Cid, Meta)
    end),
    ok;
maybe_index(Other, _Cid, _Meta) ->
    ?LOG_WARNING("sudarfs index_fun invalid: ~p", [Other]),
    ok.

%% Auto-commit when buffer_limit reached (if configured)

maybe_auto_commit(S = #state{buffer = _Buf, buffer_limit = 0}) ->
    S;
maybe_auto_commit(S = #state{buffer = Buf, buffer_limit = Limit}) ->
    case length(Buf) >= Limit of
        true ->
            case do_commit(S) of
                {ok, _Info, S1} ->
                    S1;
                {error, Reason, S1} ->
                    ?LOG_WARNING("sudarfs auto-commit failed: ~p", [Reason]),
                    S1
            end;
        false ->
            S
    end.

%% Core commit: build root from buffer and push to AE channel

do_commit(S0 = #state{buffer = []}) ->
    {error, empty_buffer, S0};
do_commit(
    S0 = #state{
        buffer = Buf,
        channel = ChPid,
        ct = CtId,
        ct_fun = FunName,
        gas = Gas
    }
) ->
    %% Deterministic order (oldest first)
    Entries = lists:reverse(Buf),
    Cids = [maps:get(cid, E) || E <- Entries],
    Count = length(Cids),
    Root = crypto:hash(sha256, term_to_binary(Cids)),

    Args = [
        Root,
        Count,
        erlang:system_time(millisecond)
    ],

    try
        %% Propose off-chain update
        {ok, Update} = damage_channels:update_contract(ChPid, CtId, FunName, Args, Gas),
        %% Locally ack (in real setup, peer would ack)
        {ok, #{round := Round, state_hash := StateHash}} =
            damage_channels:update_ack(ChPid, Update),

        CommitInfo = #{
            root => Root,
            count => Count,
            round => Round,
            state_hash => StateHash
        },

        S1 = S0#state{buffer = []},
        {ok, CommitInfo, S1}
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR("sudarfs commit failed: ~p:~p~n~p", [Class, Reason, Stack]),
            {error, Reason, S0}
    end.
