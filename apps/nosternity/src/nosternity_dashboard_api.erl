%% Browser-facing dashboard API. Protocol relay endpoints stay independent.
-module(nosternity_dashboard_api).
-export([trails/0, init/2, filter_events/2]).
trails() -> [trails:trail(P, ?MODULE, #{action => A}, #{}) || {P,A} <- [
    {"/api/nosternity/feed", feed}, {"/api/nosternity/analytics", analytics},
    {"/api/nosternity/account", account}, {"/api/nosternity/preferences", preferences},
    {"/api/nosternity/events", events}]].
init(Req0, #{action := A} = State) ->
    Req = nosternity_auth_http:no_store(Req0),
    try route(A, Req) of R -> {ok, R, State}
    catch _:_ -> {ok, err(auth_unavailable, Req), State} end.
route(A, Req) ->
    Method = case A of analytics -> <<"GET">>; account -> <<"GET">>; _ -> <<"POST">> end,
    case {cowboy_req:method(Req) =:= Method, nosternity_auth_http:allowed(Req)} of
        {false, _} -> err(method_not_allowed, Req);
        {_, false} -> err(origin_rejected, Req);
        {true, true} ->
            {Peer,_} = cowboy_req:peer(Req),
            case nosternity_auth:attempt({dashboard, Peer}) of
                ok -> handle(A, Req);
                {error, Why} -> err(Why, Req)
            end
    end.
handle(analytics, Req) ->
    reply(#{relay => nosternity_relay:status(), dashboard => nosternity_auth:metrics()}, Req);
handle(account, Req) -> account_result(nosternity_auth:account(nosternity_auth_http:token(Req)), Req);
handle(A, Req) ->
    case nosternity_auth_http:read_json(Req) of
        {ok, Body, _, R} -> dispatch(A, Body, R);
        {error, Why, R} -> err(Why, R)
    end.
dispatch(preferences, P, Req) ->
    account_result(nosternity_auth:update(nosternity_auth_http:token(Req), P), Req);
dispatch(events, Event, Req) ->
    case nosternity_auth_http:session(Req) of
        {ok, #{provider := nostr, subject := Pub}} ->
            case nosternity_filter:validate_event(Event) of
                {ok, #{pubkey := Pub, kind := Kind} = Valid} ->
                    case lists:member(Kind, [0,1,3,5,7,10000,30023]) of
                        true -> case nosternity_relay:publish_event(Valid) of
                            ok -> nosternity_auth_http:reply(202, #{accepted => true, id => maps:get(id, Valid)}, Req);
                            _ -> err(event_rejected, Req)
                        end;
                        false -> err(event_kind_not_allowed, Req)
                    end;
                _ -> err(event_author_or_signature_invalid, Req)
            end;
        _ -> err(nostr_login_required, Req)
    end;
dispatch(feed, Obj, Req) ->
    case feed_filter(Obj, nosternity_auth_http:session(Req), Req) of
        {ok, []} -> reply(#{results => [], total => 0, hidden => 0, sampled => true}, Req);
        {ok, Fs} ->
            T0 = erlang:monotonic_time(millisecond),
            case nosternity_relay:search(Fs) of
                {ok, #{results := Results}} ->
                    Prefs = case nosternity_auth:account(nosternity_auth_http:token(Req)) of
                        {ok, #{preferences := P}} -> P;
                        _ -> #{<<"spam">> => true, <<"duplicates">> => true}
                    end,
                    {Visible, Hidden} = filter_events(Results, Prefs),
                    Elapsed = erlang:monotonic_time(millisecond) - T0,
                    Metric = case maps:get(<<"query">>, Obj, <<>>) of <<>> -> feed; _ -> search end,
                    nosternity_auth:observe(Metric, Elapsed, Hidden),
                    Json = nosternity_search_http:search_json(#{results => Visible, total => length(Visible)}),
                    reply(Json#{hidden => Hidden, sampled => true, candidate_count => length(Results), duration_ms => Elapsed}, Req);
                _ -> err(search_unavailable, Req)
            end;
        {error, Why} -> err(Why, Req)
    end.
feed_filter(Obj, Session, Req) ->
    try
        true = maps:without([<<"scope">>, <<"query">>, <<"kind">>, <<"limit">>], Obj) =:= #{},
        Scope = maps:get(<<"scope">>, Obj, <<"global">>),
        Query = maps:get(<<"query">>, Obj, <<>>),
        true = is_binary(Query) andalso byte_size(Query) =< 1024,
        Limit = maps:get(<<"limit">>, Obj, 50),
        true = is_integer(Limit) andalso Limit >= 1 andalso Limit =< min(100, nosternity_filter:max_limit()),
        Kinds = case maps:get(<<"kind">>, Obj, <<"all">>) of <<"all">> -> [1,30023]; 1 -> [1]; 30023 -> [30023] end,
        F0 = #{<<"kinds">> => Kinds, <<"limit">> => Limit},
        F = case Query of <<>> -> F0; _ -> F0#{<<"search">> => Query} end,
        case Scope of
            <<"global">> -> {ok, [F]};
            <<"saved">> ->
                case nosternity_auth:account(nosternity_auth_http:token(Req)) of
                    {ok, #{preferences := #{<<"bookmarks">> := []}}} -> {ok, []};
                    {ok, #{preferences := #{<<"bookmarks">> := Ids}}} -> {ok, [F#{<<"ids">> => Ids}]};
                    _ -> {error, unauthorized}
                end;
            _ -> personal_filter(Scope, Session, F)
        end
    catch _:_ -> {error, invalid_request} end.
personal_filter(Scope, {ok, #{provider := nostr, subject := Pub}}, F) ->
    case Scope of
        <<"account">> -> {ok, [F#{<<"authors">> => [Pub]}]};
        <<"following">> ->
            case nosternity_relay:search([#{<<"kinds">> => [3], <<"authors">> => [Pub], <<"limit">> => 1}]) of
                {ok, #{results := [#{event := #{tags := Tags}} | _]}} ->
                    Authors = lists:sublist(lists:usort([P || [<<"p">>, P | _] <- Tags, valid_hex(P)]), nosternity_config:get(max_filter_values)),
                    case Authors of [] -> {ok, []}; _ -> {ok, [F#{<<"authors">> => Authors}]} end;
                {ok, _} -> {ok, []};
                _ -> {error, search_unavailable}
            end;
        _ -> {error, invalid_request}
    end;
personal_filter(_, _, _) -> {error, nostr_login_required}.

filter_events(Results, P) ->
    {Rev, _Seen, Hidden} = lists:foldl(fun(#{event := Event} = R, {Acc, Seen, N}) ->
        Text = string:lowercase(string:trim(maps:get(content, Event, <<>>))),
        Pub = maps:get(pubkey, Event),
        Duplicated = maps:get(<<"duplicates">>, P, true) andalso Text =/= <<>> andalso maps:is_key(Text, Seen),
        Muted = lists:member(Pub, maps:get(<<"muted">>, P, [])) orelse
            lists:any(fun(W) -> W =/= <<>> andalso binary:match(Text, string:lowercase(W)) =/= nomatch end, maps:get(<<"words">>, P, [])),
        Spam = maps:get(<<"spam">>, P, true) andalso obvious_spam(Text),
        case Duplicated orelse Muted orelse Spam of
            true -> {Acc, Seen#{Text => true}, N + 1};
            false -> {[R | Acc], Seen#{Text => true}, N}
        end
    end, {[], #{}, 0}, Results),
    {lists:reverse(Rev), Hidden}.
obvious_spam(T) ->
    length(binary:matches(T, [<<"https://">>, <<"http://">>])) > 4 orelse
    lists:any(fun(W) -> binary:match(T, W) =/= nomatch end,
        [<<"guaranteed profit">>, <<"double your bitcoin">>, <<"claim your airdrop">>]).
valid_hex(B) when is_binary(B), byte_size(B) =:= 64 -> re:run(B, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match;
valid_hex(_) -> false.
account_result({ok, Body}, Req) -> reply(Body, Req);
account_result({error, Why}, Req) -> err(Why, Req).
reply(B, R) -> nosternity_auth_http:reply(200, B, R).
err(W, R) -> nosternity_auth_http:error_reply(W, R).
