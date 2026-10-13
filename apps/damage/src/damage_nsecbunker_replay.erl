%%--------------------------------------------------------------------
%% Replay/idempotency guard.
%% Same {requester_pubkey, request_id} may only refer to the same payload hash.
%%--------------------------------------------------------------------
-module(damage_nsecbunker_replay).

-behaviour(gen_server).

-export([start_link/0, check_and_mark/3, reset/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec check_and_mark(binary(), binary(), binary()) ->
    ok | {ok, duplicate_same_payload} | {error, replay_conflict}.
check_and_mark(RequesterPubkey, RequestId, PayloadSha256) ->
    gen_server:call(?SERVER, {check_and_mark, RequesterPubkey, RequestId, PayloadSha256}).

reset() ->
    gen_server:call(?SERVER, reset).

init([]) ->
    Table = ets:new(?MODULE, [set, private]),
    {ok, #{table => Table}}.

handle_call(
    {check_and_mark, RequesterPubkey, RequestId, PayloadSha256}, _From, #{table := Table} = State
) ->
    Key = {RequesterPubkey, RequestId},
    Reply =
        case ets:lookup(Table, Key) of
            [] ->
                ets:insert(Table, {Key, PayloadSha256}),
                ok;
            [{Key, PayloadSha256}] ->
                {ok, duplicate_same_payload};
            [{Key, _DifferentPayload}] ->
                {error, replay_conflict}
        end,
    {reply, Reply, State};
handle_call(reset, _From, #{table := Table} = State) ->
    ets:delete_all_objects(Table),
    {reply, ok, State};
handle_call(_Other, _From, State) ->
    {reply, {error, bad_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
