%% Bounded JSON API for the local Nostr relay and public retrieval bridge.
-module(nosternity_search_http).
-export([init/2, trails/0]).

-ifdef(TEST).
-export([authorize/2, query_filters/1, decode_body/1, search_json/1]).
-endif.

-define(MAX_BODY_BYTES, 65536).

trails() ->
    [
        trails:trail(Path, ?MODULE, #{action => Action}, #{})
     || {Path, Action} <- [
            {"/api/nostr/search", search},
            {"/api/nostr/events", events},
            {"/api/nostr/context", context},
            {"/api/nostr/ask", ask},
            {"/api/nostr/status", status}
        ]
    ].

init(Req, #{action := Action} = State) ->
    try dispatch(cowboy_req:method(Req), Action, Req) of
        Req1 -> {ok, Req1, State}
    catch
        %% Details of runtime/provider failures must never be sent to clients.
        _:_ -> {ok, reply_error(503, service_unavailable, Req), State}
    end.

dispatch(<<"GET">>, status, Req) ->
    reply(200, nosternity_relay:status(), Req);
dispatch(<<"GET">>, search, Req) ->
    case byte_size(cowboy_req:qs(Req)) =< 4096 of
        false -> reply_error(414, query_too_large, Req);
        true ->
            case query_filters(cowboy_req:parse_qs(Req)) of
                {ok, Filters} -> search(Filters, Req);
                {error, Reason} -> reply_error(400, Reason, Req)
            end
    end;
dispatch(<<"POST">>, ask, Req) ->
    %% Reject before reading/decoding a body or starting any inference work.
    case authorize(cowboy_req:header(<<"authorization">>, Req), os:getenv("NOSTERNITY_LLM_API_TOKEN")) of
        ok -> read_request(ask, Req);
        {error, auth_not_configured} -> reply_error(503, auth_not_configured, Req);
        {error, unauthorized} ->
            reply(401, #{error => unauthorized}, Req, #{<<"www-authenticate">> => <<"Bearer">>})
    end;
dispatch(<<"POST">>, Action, Req) when Action =:= search; Action =:= events; Action =:= context ->
    read_request(Action, Req);
dispatch(_, Action, Req) ->
    Allowed = case Action of status -> <<"GET">>; search -> <<"GET, POST">>; _ -> <<"POST">> end,
    reply(405, #{error => method_not_allowed}, Req, #{<<"allow">> => Allowed}).

read_request(Action, Req) ->
    case json_content_type(cowboy_req:header(<<"content-type">>, Req, <<>>)) of
        false -> reply_error(415, expected_json, Req);
        true ->
            Deadline = erlang:monotonic_time(millisecond) + 10000,
            case read_body(Req, [], 0, Deadline) of
                {ok, Body, Req1} ->
                    case decode_body(Body) of
                        {ok, Object} -> handle(Action, Object, Req1);
                        {error, Reason} -> reply_error(400, Reason, Req1)
                    end;
                {error, body_timeout, Req1} -> reply_error(408, body_timeout, Req1);
                {error, Reason, Req1} -> reply_error(413, Reason, Req1)
            end
    end.

json_content_type(Header) ->
    [Type | _] = binary:split(Header, <<";">>, [global]),
    string:lowercase(string:trim(Type)) =:= <<"application/json">>.

read_body(Req, Chunks, Size, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    case Remaining > 0 of
        false -> {error, body_timeout, Req};
        true -> read_body_chunk(Req, Chunks, Size, Deadline, Remaining)
    end.

read_body_chunk(Req, Chunks, Size, Deadline, Remaining) ->
    case cowboy_req:body_length(Req) of
        Length when is_integer(Length), Length > ?MAX_BODY_BYTES ->
            {error, body_too_large, Req};
        _ ->
            case cowboy_req:read_body(Req, #{length => 16384, period => min(5000, Remaining)}) of
                {Tag, Chunk, Req1} when Tag =:= ok; Tag =:= more ->
                    NewSize = Size + byte_size(Chunk),
                    if
                        NewSize > ?MAX_BODY_BYTES -> {error, body_too_large, Req1};
                        Tag =:= ok -> {ok, iolist_to_binary(lists:reverse([Chunk | Chunks])), Req1};
                        true -> read_body(Req1, [Chunk | Chunks], NewSize, Deadline)
                    end
            end
    end.

decode_body(Body) when is_binary(Body), byte_size(Body) =< ?MAX_BODY_BYTES ->
    try jsx:decode(Body, [return_maps]) of
        Object when is_map(Object) -> {ok, Object};
        _ -> {error, invalid_json_object}
    catch _:_ -> {error, invalid_json} end;
decode_body(_) -> {error, body_too_large}.

handle(search, #{<<"filters">> := Filters} = Object, Req) when map_size(Object) =:= 1 ->
    search(Filters, Req);
handle(search, _, Req) -> reply_error(400, invalid_request, Req);
handle(events, Event, Req) ->
    case nosternity_relay:publish_event(Event) of
        ok -> reply(202, #{accepted => true, id => maps:get(<<"id">>, Event, <<>>)}, Req);
        {error, Reason} -> reply_error(400, publish_error(Reason), Req)
    end;
handle(context, Object, Req) -> bridge_result(nosternity_llm_bridge:context(Object), Req);
handle(ask, Object, Req) -> bridge_result(nosternity_llm_bridge:ask(Object), Req).

search(Filters, Req) ->
    case nosternity_filter:valid_filters(Filters) of
        {ok, Valid} ->
            case nosternity_relay:search(Valid) of
                {ok, Result} -> reply(200, search_json(Result), Req);
                {error, invalid_filters} -> reply_error(400, invalid_filters, Req);
                _ -> reply_error(503, search_unavailable, Req)
            end;
        _ -> reply_error(400, invalid_filters, Req)
    end.

search_json(#{results := Results, total := Total}) ->
    #{results => [
        #{event => nosternity_filter:wire(maps:get(event, Result)), score => maps:get(score, Result, 0)}
     || Result <- Results
    ], total => Total}.

query_filters(Pairs) when is_list(Pairs) ->
    Map = maps:from_list(Pairs),
    Q = maps:get(<<"q">>, Map, undefined),
    DefaultLimit = integer_to_binary(nosternity_filter:default_limit()),
    Limit = parse_limit(maps:get(<<"limit">>, Map, DefaultLimit)),
    Allowed = maps:without([<<"q">>, <<"limit">>], Map) =:= #{},
    Unique = length(Pairs) =:= map_size(Map),
    case Allowed andalso Unique andalso valid_query(Q) andalso Limit =/= error of
        true -> nosternity_filter:valid_filters([#{<<"search">> => Q, <<"limit">> => Limit}]);
        false -> {error, invalid_query}
    end.

valid_query(Q) when is_binary(Q), byte_size(Q) > 0, byte_size(Q) =< 1024 ->
    case unicode:characters_to_binary(Q, utf8, utf8) of
        Q -> string:trim(Q) =/= <<>>;
        _ -> false
    end;
valid_query(_) -> false.

parse_limit(Bin) when is_binary(Bin), byte_size(Bin) =< 5 ->
    Max = nosternity_filter:max_limit(),
    try binary_to_integer(Bin) of
        N when N > 0, N =< Max -> N;
        _ -> error
    catch _:_ -> error end;
parse_limit(_) -> error.

authorize(_, false) -> {error, auth_not_configured};
authorize(_, []) -> {error, auth_not_configured};
authorize(_, <<>>) -> {error, auth_not_configured};
authorize(Header, Token) when is_list(Token) -> authorize(Header, list_to_binary(Token));
authorize(<<"Bearer ", Provided/binary>>, Expected) when
    is_binary(Expected), byte_size(Expected) > 0,
    byte_size(Provided) > 0, byte_size(Provided) =< 4096
->
    case equal_hash(crypto:hash(sha256, Provided), crypto:hash(sha256, Expected), 0) of
        0 -> ok;
        _ -> {error, unauthorized}
    end;
authorize(_, _) -> {error, unauthorized}.

equal_hash(<<>>, <<>>, Diff) -> Diff;
equal_hash(<<A, As/binary>>, <<B, Bs/binary>>, Diff) -> equal_hash(As, Bs, Diff bor (A bxor B)).

bridge_result({ok, Result}, Req) -> reply(200, Result, Req);
bridge_result({error, Reason}, Req) ->
    Status = case Reason of
        invalid_request -> 400;
        invalid_filters -> 400;
        context_too_large -> 413;
        llm_request_failed -> 502;
        _ -> 503
    end,
    reply_error(Status, Reason, Req).

publish_error(invalid_event) -> invalid_event;
publish_error(invalid_signature) -> invalid_signature;
publish_error(event_too_large) -> event_too_large;
publish_error(_) -> event_rejected.

reply_error(Status, Reason, Req) -> reply(Status, #{error => Reason}, Req).
reply(Status, Body, Req) -> reply(Status, Body, Req, #{}).
reply(Status, Body, Req, ExtraHeaders) ->
    Headers = maps:merge(#{
        <<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"cache-control">> => <<"no-store">>,
        <<"x-content-type-options">> => <<"nosniff">>
    }, ExtraHeaders),
    cowboy_req:reply(Status, Headers, jsx:encode(Body), Req).
