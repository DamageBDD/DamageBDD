%% Separate private REST surface. No anonymous/operator-mode owner fallback;
%% identity comes exclusively from damage_auth's authenticated request state.
-module(ecai_private_http).
-export([
    trails/0,
    init/2,
    is_authorized/2,
    allowed_methods/2,
    content_types_accepted/2,
    content_types_provided/2,
    from_json/2,
    to_json/2,
    dispatch/4
]).
-define(MAX_BODY_BYTES, 1048576).

trails() ->
    [
        trails:trail(
            "/ecai/private/:corpus/" ++ atom_to_list(Action),
            ?MODULE,
            #{action => Action},
            #{
                post => #{
                    tags => ["ECAI Private Index"],
                    produces => ["application/json"]
                }
            }
        )
     || Action <- [index, search, fetch, ask]
    ].
init(Req, State) ->
    process_flag(sensitive, true),
    {cowboy_rest, Req, State}.
is_authorized(Req, State) -> damage_http:is_authorized(Req, State).
allowed_methods(Req, State) -> {[<<"POST">>], Req, State}.
content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.
content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.
to_json(Req, State) -> {<<"{}">>, Req, State}.

from_json(Req0, #{action := Action} = State) ->
    case damage_auth:authenticated_account(State) of
        {ok, Principal} when is_binary(Principal), byte_size(Principal) > 0 ->
            Corpus = cowboy_req:binding(corpus, Req0),
            case read_body(Req0, [], 0, erlang:monotonic_time(millisecond) + 15000) of
                {ok, Body, Req1} ->
                    Result =
                        try
                            Data = jsx:decode(Body, [return_maps]),
                            dispatch(Action, Corpus, Principal, Data)
                        catch
                            _:_ -> {error, invalid_request}
                        end,
                    reply(Req1, State, Result);
                {error, Req1} ->
                    reply(Req1, State, {error, payload_too_large})
            end;
        _ ->
            reply(Req0, State, {error, unauthenticated})
    end.

read_body(Req0, Acc, Size, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false -> {error, Req0};
        true -> read_body_part(Req0, Acc, Size, Deadline, min(5000, Remaining))
    end.

read_body_part(Req0, Acc, Size, Deadline, Period) ->
    case cowboy_req:read_body(Req0, #{length => 65536, period => Period}) of
        {Status, Part, Req1} when Status =:= ok; Status =:= more ->
            NewSize = Size + byte_size(Part),
            case NewSize > ?MAX_BODY_BYTES of
                true ->
                    {error, Req1};
                false when Status =:= ok ->
                    {ok, iolist_to_binary(lists:reverse([Part | Acc])), Req1};
                false ->
                    read_body(Req1, [Part | Acc], NewSize, Deadline)
            end
    end.

%% Exported for boundary tests. Caller-supplied owner/key/path/provider fields
%% are rejected, not ignored. Batch IDs are 32 lowercase random hex characters.
dispatch(
    index,
    Corpus,
    Principal,
    #{<<"batch_id">> := Batch, <<"records">> := Records} = Data
) when
    map_size(Data) =:= 2
->
    ecai_disk_indexer:index_private(Corpus, Principal, Batch, Records);
dispatch(search, Corpus, Principal, #{<<"query">> := Query} = Data) ->
    case lists:sort(maps:keys(Data)) -- [<<"query">>, <<"limit">>] of
        [] ->
            ecai_private_index:search(
                Corpus,
                Principal,
                Query,
                maps:get(<<"limit">>, Data, 8)
            );
        _ ->
            {error, invalid_request}
    end;
dispatch(fetch, Corpus, Principal, #{<<"id">> := Id} = Data) when
    map_size(Data) =:= 1
->
    ecai_private_index:fetch(Corpus, Principal, Id);
dispatch(
    ask,
    Corpus,
    Principal,
    #{<<"question">> := Question, <<"destination">> := Dest} = Data
) when
    map_size(Data) =:= 2
->
    ecai_llm_bridge:ask(Corpus, Principal, Question, Dest);
dispatch(_, _, _, _) ->
    {error, invalid_request}.

reply(Req, State, Result) ->
    {Code, Payload} =
        case Result of
            {ok, Value} ->
                {200, #{ok => true, result => json_safe(Value)}};
            {error, Reason} when is_atom(Reason) ->
                {status(Reason), #{ok => false, error => atom_to_binary(Reason, utf8)}};
            _ ->
                {503, #{ok => false, error => <<"private_operation_failed">>}}
        end,
    Req1 = cowboy_req:reply(
        Code,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"no-store, private">>,
            <<"pragma">> => <<"no-cache">>,
            <<"x-content-type-options">> => <<"nosniff">>
        },
        jsx:encode(Payload),
        Req
    ),
    {stop, Req1, State}.

%% Existing ingest commitments are raw bytes; encode those fields for JSON.
json_safe(Map) when is_map(Map) ->
    maps:from_list([
        {K,
            case
                lists:member(K, [
                    chunk_content_sha256,
                    index_fields_sha256,
                    chunk_id,
                    event_id
                ])
            of
                true when is_binary(V) -> binary:encode_hex(V);
                _ -> json_safe(V)
            end}
     || {K, V} <- maps:to_list(Map)
    ]);
json_safe(List) when is_list(List) -> [json_safe(V) || V <- List];
json_safe(V) ->
    V.

status(unauthenticated) -> 401;
status(forbidden) -> 403;
status(llm_destination_forbidden) -> 403;
status(remote_llm_forbidden) -> 403;
status(not_found) -> 404;
status(batch_already_exists) -> 409;
status(payload_too_large) -> 413;
status(invalid_request) -> 400;
status(invalid_query) -> 400;
status(invalid_utf8) -> 400;
status(private_operation_timeout) -> 504;
status(_) -> 503.
