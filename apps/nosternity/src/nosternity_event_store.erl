%%--------------------------------------------------------------------
%% Aeternity-backed persistence for selected Nostr events.
%%
%% The relay hot path remains ETS/websocket based.  Selected events are queued
%% here and persisted in idempotent batches to a Nosternity-owned Sophia
%% contract.  This isolates chain latency from websocket acknowledgement.
%%--------------------------------------------------------------------
-module(nosternity_event_store).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    store/1,
    store_sync/1,
    status/0,
    contract_id/0,
    exists/1,
    get_event/1,
    get_event_count/0,
    get_event_id/1,
    get_events/2,
    get_kind_count/1,
    get_kind_event_id/2,
    should_store/2,
    validate_event/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(CONTRACT_ENV, ae_event_store_contract).
-define(DEFAULT_CONTRACT_FILE, "contracts/NostrEventStore.aes").
-define(DEFAULT_KINDS, [1, 7, 30023]).
-define(DEFAULT_MAX_EVENT_BYTES, 65536).
-define(DEFAULT_QUEUE_MAX, 5000).
-define(DEFAULT_BATCH_SIZE, 10).
-define(DEFAULT_FLUSH_MS, 2000).
-define(DEFAULT_RETRY_MS, 5000).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Fire-and-forget from relay ingress.  Validation happens before enqueue.
store(Event) ->
    gen_server:cast(?SERVER, {store, Event}).

%% Returns queue/validation status; it intentionally does not wait for mining.
store_sync(Event) ->
    gen_server:call(?SERVER, {store, Event}, 30000).

status() ->
    gen_server:call(?SERVER, status, 30000).

contract_id() ->
    gen_server:call(?SERVER, contract_id, 30000).

exists(EventId) ->
    gen_server:call(?SERVER, {query, exists, [to_bin(EventId)]}, 30000).

get_event(EventId) ->
    gen_server:call(?SERVER, {query, get_event, [to_bin(EventId)]}, 30000).

get_event_count() ->
    gen_server:call(?SERVER, {query, get_event_count, []}, 30000).

get_event_id(Index) when is_integer(Index), Index >= 0 ->
    gen_server:call(?SERVER, {query, get_event_id, [Index]}, 30000).

get_events(Offset, Limit) when
    is_integer(Offset), Offset >= 0, is_integer(Limit), Limit >= 0, Limit =< 100
->
    gen_server:call(?SERVER, {query, get_events, [Offset, Limit]}, 30000).

get_kind_count(Kind) when is_integer(Kind) ->
    gen_server:call(?SERVER, {query, get_kind_count, [Kind]}, 30000).

get_kind_event_id(Kind, Index) when is_integer(Kind), is_integer(Index), Index >= 0 ->
    gen_server:call(?SERVER, {query, get_kind_event_id, [Kind, Index]}, 30000).

init([]) ->
    Enabled = env_bool(ae_event_store_enabled, false),
    ContractFile = env_string(ae_event_store_contract_file, ?DEFAULT_CONTRACT_FILE),
    Kinds = normalize_kinds(application:get_env(nosternity, ae_event_store_kinds, ?DEFAULT_KINDS)),
    Authors = normalize_authors(application:get_env(nosternity, ae_event_store_pubkeys, all)),
    State0 = #{
        enabled => Enabled,
        contract_file => ContractFile,
        contract_id => undefined,
        auto_deploy => env_bool(ae_event_store_auto_deploy, false),
        confirm_writes => env_bool(ae_event_store_confirm_writes, true),
        kinds => Kinds,
        authors => Authors,
        max_event_bytes => env_pos_int(ae_event_store_max_event_bytes, ?DEFAULT_MAX_EVENT_BYTES),
        queue_max => env_pos_int(ae_event_store_queue_max, ?DEFAULT_QUEUE_MAX),
        batch_size => env_pos_int(ae_event_store_batch_size, ?DEFAULT_BATCH_SIZE),
        flush_ms => env_pos_int(ae_event_store_flush_ms, ?DEFAULT_FLUSH_MS),
        retry_ms => env_pos_int(ae_event_store_retry_ms, ?DEFAULT_RETRY_MS),
        queue => queue:new(),
        queued_ids => #{},
        flush_timer => undefined,
        ensure_timer => undefined,
        last_error => undefined
    },
    State1 = resolve_configured_contract(State0),
    State = maybe_schedule_ensure(State1),
    ?LOG_INFO(
        "Nosternity Aeternity event store enabled=~p contract=~p kinds=~p auto_deploy=~p",
        [Enabled, maps:get(contract_id, State), kinds_for_log(Kinds), maps:get(auto_deploy, State)]
    ),
    {ok, State}.

handle_call(status, _From, State) ->
    Reply = #{
        enabled => maps:get(enabled, State),
        contract_id => maps:get(contract_id, State),
        queue_depth => queue:len(maps:get(queue, State)),
        kinds => kinds_for_log(maps:get(kinds, State)),
        authors => authors_for_log(maps:get(authors, State)),
        auto_deploy => maps:get(auto_deploy, State),
        confirm_writes => maps:get(confirm_writes, State),
        last_error => maps:get(last_error, State)
    },
    {reply, Reply, State};
handle_call(contract_id, _From, State) ->
    case maps:get(contract_id, State) of
        undefined -> {reply, {error, contract_unavailable}, State};
        ContractId -> {reply, {ok, ContractId}, State}
    end;
handle_call({store, Event0}, _From, State0) ->
    {Reply, State} = enqueue_event(Event0, State0),
    {reply, Reply, State};
handle_call({query, Func, Args}, _From, State) ->
    {reply, query_contract(Func, Args, State), State};
handle_call(Request, _From, State) ->
    {reply, {error, {unsupported_call, Request}}, State}.

handle_cast({store, Event0}, State0) ->
    {_Reply, State} = enqueue_event(Event0, State0),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(ensure_contract, State0) ->
    State1 = State0#{ensure_timer => undefined},
    case ensure_contract(State1) of
        {ok, State2} ->
            self() ! flush,
            {noreply, State2};
        {error, Reason, State2} ->
            ?LOG_WARNING("Nosternity event-store contract unavailable: ~p", [Reason]),
            {noreply, schedule_ensure(State2#{last_error => Reason})}
    end;
handle_info(flush, State0) ->
    State1 = State0#{flush_timer => undefined},
    {noreply, flush_batch(State1)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(maps:get(flush_timer, State, undefined)),
    cancel_timer(maps:get(ensure_timer, State, undefined)),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Policy / validation
%%--------------------------------------------------------------------

should_store(Event0, Policy) when is_map(Policy) ->
    Event = damage_nostr_event:normalize_event(Event0),
    Kind = maps:get(kind, Event, undefined),
    Pubkey = maps:get(pubkey, Event, undefined),
    kind_allowed(Kind, maps:get(kinds, Policy, all)) andalso
        author_allowed(Pubkey, maps:get(authors, Policy, all)).

validate_event(Event0, MaxBytes) when is_integer(MaxBytes), MaxBytes > 0 ->
    Event = damage_nostr_event:normalize_event(Event0),
    case required_fields(Event) of
        ok ->
            Id = maps:get(id, Event),
            Pubkey = maps:get(pubkey, Event),
            Sig = maps:get(sig, Event),
            case {is_hex(Id, 64), is_hex(Pubkey, 64), is_hex(Sig, 128)} of
                {true, true, true} ->
                    case damage_nostr_event:verify(Event) of
                        {ok, VerifiedEvent} ->
                            case event_wire_size(VerifiedEvent) =< MaxBytes of
                                true -> {ok, VerifiedEvent};
                                false -> {error, event_too_large}
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                _ ->
                    {error, invalid_nostr_hex_fields}
            end;
        Error ->
            Error
    end.

required_fields(Event) ->
    Required = [id, pubkey, created_at, kind, tags, content, sig],
    case [K || K <- Required, not maps:is_key(K, Event)] of
        [] ->
            case
                {
                    maps:get(id, Event),
                    maps:get(pubkey, Event),
                    maps:get(created_at, Event),
                    maps:get(kind, Event),
                    maps:get(tags, Event),
                    maps:get(content, Event),
                    maps:get(sig, Event)
                }
            of
                {Id, Pubkey, CreatedAt, Kind, Tags, Content, Sig} when
                    is_binary(Id),
                    is_binary(Pubkey),
                    is_integer(CreatedAt),
                    is_integer(Kind),
                    is_list(Tags),
                    is_binary(Content),
                    is_binary(Sig)
                ->
                    ok;
                _ ->
                    {error, invalid_event_shape}
            end;
        Missing ->
            {error, {missing_event_fields, Missing}}
    end.

is_hex(Bin, Size) when is_binary(Bin), byte_size(Bin) =:= Size ->
    lists:all(fun is_hex_char/1, binary_to_list(Bin));
is_hex(_, _) ->
    false.

is_hex_char(C) when C >= $0, C =< $9 -> true;
is_hex_char(C) when C >= $a, C =< $f -> true;
is_hex_char(_) -> false.

event_wire_size(Event) ->
    byte_size(jsx:encode(event_wire(Event))).

event_wire(Event) ->
    #{
        <<"id">> => maps:get(id, Event),
        <<"pubkey">> => maps:get(pubkey, Event),
        <<"created_at">> => maps:get(created_at, Event),
        <<"kind">> => maps:get(kind, Event),
        <<"tags">> => maps:get(tags, Event),
        <<"content">> => maps:get(content, Event),
        <<"sig">> => maps:get(sig, Event)
    }.

contract_record(Event) ->
    #{
        id => maps:get(id, Event),
        pubkey => maps:get(pubkey, Event),
        created_at => maps:get(created_at, Event),
        kind => maps:get(kind, Event),
        tags => maps:get(tags, Event),
        content => maps:get(content, Event),
        sig => maps:get(sig, Event)
    }.

%%--------------------------------------------------------------------
%% Queue / persistence
%%--------------------------------------------------------------------

enqueue_event(_Event0, #{enabled := false} = State) ->
    {{ignored, disabled}, State};
enqueue_event(_Event0, #{contract_id := undefined, auto_deploy := false} = State) ->
    {{error, contract_unavailable}, State#{last_error => contract_unavailable}};
enqueue_event(Event0, State0) ->
    Policy = #{kinds => maps:get(kinds, State0), authors => maps:get(authors, State0)},
    case should_store(Event0, Policy) of
        false ->
            {{ignored, policy}, State0};
        true ->
            case validate_event(Event0, maps:get(max_event_bytes, State0)) of
                {ok, Event} ->
                    enqueue_valid_event(Event, State0);
                {error, Reason} ->
                    ?LOG_WARNING("Rejecting event from Aeternity store: ~p", [Reason]),
                    {{error, Reason}, State0}
            end
    end.

enqueue_valid_event(Event, State0) ->
    Id = maps:get(id, Event),
    QueuedIds = maps:get(queued_ids, State0),
    case maps:is_key(Id, QueuedIds) of
        true ->
            {{ignored, already_queued}, State0};
        false ->
            Q0 = maps:get(queue, State0),
            case queue:len(Q0) >= maps:get(queue_max, State0) of
                true ->
                    {{error, queue_full}, State0#{last_error => queue_full}};
                false ->
                    Q1 = queue:in(Event, Q0),
                    State1 = State0#{queue => Q1, queued_ids => QueuedIds#{Id => true}},
                    State2 = maybe_schedule_flush(State1),
                    {{queued, Id}, State2}
            end
    end.

maybe_schedule_flush(State = #{contract_id := undefined}) ->
    maybe_schedule_ensure(State);
maybe_schedule_flush(State) ->
    case queue:len(maps:get(queue, State)) >= maps:get(batch_size, State) of
        true ->
            cancel_timer(maps:get(flush_timer, State)),
            self() ! flush,
            State#{flush_timer => undefined};
        false ->
            case maps:get(flush_timer, State) of
                undefined ->
                    Ref = erlang:send_after(maps:get(flush_ms, State), self(), flush),
                    State#{flush_timer => Ref};
                _ ->
                    State
            end
    end.

flush_batch(State = #{enabled := false}) ->
    State;
flush_batch(State = #{contract_id := undefined}) ->
    maybe_schedule_ensure(State);
flush_batch(State0) ->
    case queue:is_empty(maps:get(queue, State0)) of
        true ->
            State0;
        false ->
            {Batch, RestQ} = take_batch(maps:get(queue, State0), maps:get(batch_size, State0), []),
            State1 = State0#{queue => RestQ},
            case persist_batch(Batch, State1) of
                ok ->
                    State2 = remove_queued_ids(Batch, State1#{last_error => undefined}),
                    maybe_continue_flush(State2);
                {error, Reason} ->
                    ?LOG_WARNING(
                        "Aeternity Nostr event batch persistence failed count=~p reason=~p",
                        [length(Batch), Reason]
                    ),
                    QRetry = queue:join(queue:from_list(Batch), RestQ),
                    State2 = State1#{queue => QRetry, last_error => Reason},
                    schedule_flush_retry(maybe_schedule_ensure(State2))
            end
    end.

persist_batch([], _State) ->
    ok;
persist_batch(Batch, State) ->
    ContractId = maps:get(contract_id, State),
    ContractFile = maps:get(contract_file, State),
    Args = [[contract_record(Event) || Event <- Batch]],
    case maps:get(confirm_writes, State) of
        true ->
            tracked_persistence_result(
                damage_ae_contract:call_tracked(
                    nosternity, ContractId, ContractFile, "put_events", Args
                )
            );
        false ->
            submit_persistence_result(
                damage_ae_contract:call(
                    nosternity, ContractId, ContractFile, "put_events", Args
                )
            )
    end.

%% With confirmation enabled, only an observed mined/confirmed receipt removes
%% the batch from the retry queue.  submitted/submission_unknown are retried;
%% the contract is idempotent, so retry cannot duplicate the stored event.
tracked_persistence_result({ok, #{status := confirmed}}) ->
    ok;
tracked_persistence_result({ok, #{status := submitted} = Meta}) ->
    {error, {submission_not_confirmed, Meta}};
tracked_persistence_result({ok, #{status := submission_unknown} = Meta}) ->
    {error, {submission_unknown, Meta}};
tracked_persistence_result({error, _} = Error) ->
    Error;
tracked_persistence_result(Other) ->
    {error, {unexpected_tracked_contract_reply, Other}}.

%% Without confirmation, transaction acceptance by the node is enough to
%% dequeue.  This mode is lower-latency but gives weaker durability semantics.
submit_persistence_result({ok, Map}) when is_map(Map) ->
    submit_persistence_result(Map);
submit_persistence_result(Map) when is_map(Map) ->
    case map_value([tx_hash, <<"tx_hash">>, "tx_hash"], Map, undefined) of
        undefined ->
            case map_value([return_type, <<"return_type">>, "return_type"], Map, undefined) of
                ok -> ok;
                <<"ok">> -> ok;
                "ok" -> ok;
                _ -> {error, {unexpected_submit_reply, Map}}
            end;
        _ ->
            ok
    end;
submit_persistence_result({error, _} = Error) ->
    Error;
submit_persistence_result(Other) ->
    {error, {unexpected_submit_reply, Other}}.

take_batch(Q, 0, Acc) ->
    {lists:reverse(Acc), Q};
take_batch(Q, N, Acc) ->
    case queue:out(Q) of
        {{value, Event}, Q1} -> take_batch(Q1, N - 1, [Event | Acc]);
        {empty, _} -> {lists:reverse(Acc), Q}
    end.

remove_queued_ids(Batch, State) ->
    Ids0 = maps:get(queued_ids, State),
    Ids = lists:foldl(fun(E, Acc) -> maps:remove(maps:get(id, E), Acc) end, Ids0, Batch),
    State#{queued_ids => Ids}.

maybe_continue_flush(State) ->
    case queue:is_empty(maps:get(queue, State)) of
        true ->
            State;
        false ->
            self() ! flush,
            State
    end.

schedule_flush_retry(State) ->
    cancel_timer(maps:get(flush_timer, State)),
    Ref = erlang:send_after(maps:get(retry_ms, State), self(), flush),
    State#{flush_timer => Ref}.

%%--------------------------------------------------------------------
%% Contract lifecycle / reads
%%--------------------------------------------------------------------

resolve_configured_contract(#{enabled := false} = State) ->
    State;
resolve_configured_contract(State) ->
    case damage_ae_contract:resolve(nosternity, ?CONTRACT_ENV) of
        {ok, ContractId} -> State#{contract_id => ContractId};
        {error, _} -> State
    end.

maybe_schedule_ensure(#{enabled := false} = State) ->
    State;
maybe_schedule_ensure(#{contract_id := ContractId} = State) when ContractId =/= undefined ->
    State;
maybe_schedule_ensure(#{auto_deploy := false} = State) ->
    State;
maybe_schedule_ensure(State) ->
    schedule_ensure(State).

schedule_ensure(#{ensure_timer := Ref} = State) when is_reference(Ref) ->
    State;
schedule_ensure(State) ->
    Ref = erlang:send_after(maps:get(retry_ms, State), self(), ensure_contract),
    State#{ensure_timer => Ref}.

ensure_contract(State) ->
    Opts = #{auto_deploy => maps:get(auto_deploy, State)},
    case
        damage_ae_contract:ensure(
            nosternity,
            ?CONTRACT_ENV,
            maps:get(contract_file, State),
            [],
            Opts
        )
    of
        {ok, ContractId} ->
            {ok, State#{contract_id => ContractId, last_error => undefined}};
        {error, Reason} ->
            {error, Reason, State}
    end.

query_contract(_Func, _Args, #{enabled := false}) ->
    {error, disabled};
query_contract(_Func, _Args, #{contract_id := undefined}) ->
    {error, contract_unavailable};
query_contract(Func, Args, State) ->
    Reply = damage_ae_contract:query(
        nosternity,
        maps:get(contract_id, State),
        maps:get(contract_file, State),
        atom_to_list(Func),
        Args
    ),
    decode_query(Func, Reply).

decode_query(Func, Reply) ->
    case query_value(Reply) of
        {ok, Value} -> decode_query_value(Func, Value);
        Error -> Error
    end.

query_value(Map) when is_map(Map) ->
    ReturnType = map_value([return_type, <<"return_type">>, "return_type"], Map, undefined),
    ReturnValue = map_value([return_value, <<"return_value">>, "return_value"], Map, undefined),
    case ReturnType of
        ok -> {ok, ReturnValue};
        <<"ok">> -> {ok, ReturnValue};
        "ok" -> {ok, ReturnValue};
        _ -> {error, {contract_query_failed, ReturnType, ReturnValue}}
    end;
query_value({error, _} = Error) ->
    Error;
query_value(Other) ->
    {error, {unexpected_query_reply, Other}}.

decode_query_value(exists, Value) when is_boolean(Value) -> {ok, Value};
decode_query_value(get_event_count, Value) when is_integer(Value) -> {ok, Value};
decode_query_value(get_kind_count, Value) when is_integer(Value) -> {ok, Value};
decode_query_value(get_event_id, Value) ->
    decode_option(Value, fun(V) -> {ok, to_bin(V)} end);
decode_query_value(get_events, Value) when is_list(Value) -> decode_contract_events(Value, []);
decode_query_value(get_kind_event_id, Value) ->
    decode_option(Value, fun(V) -> {ok, to_bin(V)} end);
decode_query_value(get_event, Value) ->
    decode_option(Value, fun decode_contract_event/1);
decode_query_value(_Func, Value) ->
    {ok, Value}.

decode_option({variant, _Arities, 0, {}}, _Fun) ->
    {error, not_found};
decode_option({variant, _Arities, 1, {Value}}, Fun) ->
    Fun(Value);
decode_option(Other, _Fun) ->
    {error, {unexpected_option_value, Other}}.

decode_contract_events([], Acc) ->
    {ok, lists:reverse(Acc)};
decode_contract_events([Value | Rest], Acc) ->
    case decode_contract_event(Value) of
        {ok, Event} -> decode_contract_events(Rest, [Event | Acc]);
        {error, _} = Error -> Error
    end.

decode_contract_event({tuple, Value}) ->
    decode_contract_event(Value);
decode_contract_event(Value) when is_map(Value) ->
    {ok, damage_nostr_event:normalize_event(Value)};
decode_contract_event(Value) when is_tuple(Value), tuple_size(Value) =:= 7 ->
    [Id, Pubkey, CreatedAt, Kind, Tags, Content, Sig] = tuple_to_list(Value),
    {ok,
        damage_nostr_event:normalize_event(#{
            id => to_bin(Id),
            pubkey => to_bin(Pubkey),
            created_at => CreatedAt,
            kind => Kind,
            tags => Tags,
            content => to_bin(Content),
            sig => to_bin(Sig)
        })};
decode_contract_event(Value) when is_list(Value), length(Value) =:= 7 ->
    decode_contract_event(list_to_tuple(Value));
decode_contract_event(Other) ->
    {error, {unexpected_event_record, Other}}.

%%--------------------------------------------------------------------
%% Config helpers
%%--------------------------------------------------------------------

normalize_kinds(all) ->
    all;
normalize_kinds(Kinds) when is_list(Kinds) ->
    Normalized = [K || Item <- Kinds, {ok, K} <- [normalize_kind(Item)]],
    case Normalized of
        [] -> maps:from_list([{K, true} || K <- ?DEFAULT_KINDS]);
        _ -> maps:from_list([{K, true} || K <- Normalized])
    end;
normalize_kinds(_) ->
    maps:from_list([{K, true} || K <- ?DEFAULT_KINDS]).

normalize_kind(K) when is_integer(K), K >= 0 -> {ok, K};
normalize_kind(post) -> {ok, 1};
normalize_kind(posts) -> {ok, 1};
normalize_kind(text_note) -> {ok, 1};
normalize_kind(reaction) -> {ok, 7};
normalize_kind(reactions) -> {ok, 7};
normalize_kind(article) -> {ok, 30023};
normalize_kind(articles) -> {ok, 30023};
normalize_kind(long_form) -> {ok, 30023};
normalize_kind(_) -> error.

normalize_authors(all) ->
    all;
normalize_authors(Authors) when is_list(Authors) ->
    maps:from_list([{to_bin(A), true} || A <- Authors]);
normalize_authors(_) ->
    all.

kind_allowed(_Kind, all) -> true;
kind_allowed(Kind, Kinds) when is_integer(Kind), is_map(Kinds) -> maps:is_key(Kind, Kinds);
kind_allowed(_, _) -> false.

author_allowed(_Pubkey, all) ->
    true;
author_allowed(Pubkey, Authors) when is_binary(Pubkey), is_map(Authors) ->
    maps:is_key(Pubkey, Authors);
author_allowed(_, _) ->
    false.

kinds_for_log(all) -> all;
kinds_for_log(Kinds) when is_map(Kinds) -> lists:sort(maps:keys(Kinds)).

authors_for_log(all) -> all;
authors_for_log(Authors) when is_map(Authors) -> maps:size(Authors).

env_bool(Key, Default) ->
    case application:get_env(nosternity, Key, Default) of
        true -> true;
        false -> false;
        _ -> Default
    end.

env_pos_int(Key, Default) ->
    case application:get_env(nosternity, Key, Default) of
        I when is_integer(I), I > 0 -> I;
        _ -> Default
    end.

env_string(Key, Default) ->
    case application:get_env(nosternity, Key, Default) of
        B when is_binary(B) -> binary_to_list(B);
        L when is_list(L), L =/= [] -> L;
        _ -> Default
    end.

cancel_timer(Ref) when is_reference(Ref) ->
    erlang:cancel_timer(Ref),
    ok;
cancel_timer(_) ->
    ok.

map_value([], _Map, Default) ->
    Default;
map_value([Key | Rest], Map, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> map_value(Rest, Map, Default)
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).
