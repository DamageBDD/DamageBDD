%% Bounded, back-pressured requests to the explicitly supported music sources.
%% The per-request worker prevents stale HTTP messages reaching the caller.
-module(erm_dj_http).
-export([get/1, get/2, validate_url/1]).

-define(MAX_BYTES, 268435456).

get(Url) -> get(Url, #{}).
get(Url, Opts) when is_map(Opts) ->
    Max = maps:get(max_bytes, Opts, 2097152),
    Timeout = maps:get(timeout, Opts, 20000),
    case is_integer(Max) andalso Max > 0 andalso Max =< ?MAX_BYTES andalso
         is_integer(Timeout) andalso Timeout > 0 andalso Timeout =< 120000 of
        false -> {error, invalid_limits};
        true ->
            case validate_url(Url) of
                {ok, Safe} -> get_allowed(Safe, Max, Timeout);
                E -> E
            end
    end;
get(_, _) -> {error, invalid_options}.

get_allowed(Url, Max, Timeout) ->
            Ref = make_ref(), Parent = self(),
            {Pid, Mon} = spawn_opt(fun() ->
                Result = try
                    {ok, _} = application:ensure_all_started(ssl),
                    {ok, _} = application:ensure_all_started(gun),
                    request(Url, Max, erlang:monotonic_time(millisecond) + Timeout, 3)
                catch
                    Class:Reason -> {error, {http_failed, Class, Reason}}
                end,
                Parent ! {Ref, Result}
            end, [link, monitor]),
            receive
                {Ref, Result} ->
                    unlink(Pid), demonitor(Mon, [flush]), flush_exit(Pid), Result;
                {'DOWN', Mon, process, Pid, Reason} ->
                    unlink(Pid), flush_exit(Pid), {error, {http_worker, Reason}}
            after Timeout + 1000 ->
                unlink(Pid),
                exit(Pid, kill),
                receive {'DOWN', Mon, process, Pid, _} -> ok end,
                receive {Ref, _} -> ok after 0 -> ok end,
                flush_exit(Pid),
                {error, timeout}
            end.

flush_exit(Pid) ->
    receive {'EXIT', Pid, _} -> ok after 0 -> ok end.

%% HTTPS and exact hosts only. In particular suffix matches, userinfo,
%% nonstandard ports, fragments and URL control characters are rejected.
validate_url(Url0) ->
    try
        Url = unicode:characters_to_binary(Url0),
        true = is_binary(Url) andalso byte_size(Url) =< 8192,
        nomatch = re:run(Url, <<"[\\x00-\\x20\\x7f\\\\]">>),
        P = uri_string:parse(Url),
        <<"https">> = maps:get(scheme, P),
        Host = string:lowercase(maps:get(host, P)),
        true = lists:member(Host, [<<"ektoplazm.com">>, <<"www.ektoplazm.com">>]),
        true = maps:get(port, P, 443) =:= 443,
        false = maps:is_key(userinfo, P),
        false = maps:is_key(fragment, P),
        {ok, uri_string:recompose(P#{host => Host})}
    catch _:_ -> {error, untrusted_url}
    end.

request(_, _, _, N) when N < 0 -> {error, too_many_redirects};
request(Url0, Max, Deadline, Redirects) ->
    case validate_url(Url0) of
        {error, _} = E -> E;
        {ok, Url} ->
            #{host := Host} = P = uri_string:parse(Url),
            SSL = [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
                   {server_name_indication, binary_to_list(Host)},
                   {customize_hostname_check,
                    [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
            case gun:open(binary_to_list(Host), 443,
                          #{transport => tls, tls_opts => SSL, protocols => [http],
                            retry => 0, connect_timeout => remaining(Deadline)}) of
                {error, R} -> {error, {connect, R}};
                {ok, Conn} ->
                    try
                        case gun:await_up(Conn, remaining(Deadline)) of
                            {ok, http} ->
                                Path0 = maps:get(path, P, <<"/">>),
                                Path = case Path0 of <<>> -> <<"/">>; _ -> Path0 end,
                                Target = case maps:find(query, P) of
                                    {ok, Q} -> <<Path/binary, "?", Q/binary>>;
                                    error -> Path
                                end,
                                Stream = gun:get(Conn, Target,
                                    [{<<"accept-encoding">>, <<"identity">>},
                                     {<<"user-agent">>, <<"DamageBDD-ERM-ECDJ/0.1 (+https://damagebdd.com)">>}],
                                    #{flow => 1}),
                                response(Conn, Stream, Url, Max, Deadline, Redirects);
                            {error, R} -> {error, {connect, R}}
                        end
                    after
                        gun:close(Conn)
                    end
            end
    end.

response(C, S, Url, Max, D, Redirects) ->
    receive
        {gun_response, C, S, Fin, 200, Headers} ->
            case check_headers(Headers, Max) of
                ok when Fin =:= fin -> {ok, <<>>};
                ok -> body(C, S, Max, D, 0, []);
                E -> E
            end;
        {gun_response, C, S, _, Code, Headers}
          when Code =:= 301; Code =:= 302; Code =:= 303; Code =:= 307; Code =:= 308 ->
            case lists:keyfind(<<"location">>, 1, Headers) of
                {_, Location} ->
                    %% Close the old response before following; redirect bodies
                    %% are never downloaded or buffered.
                    gun:close(C),
                    request(uri_string:resolve(Location, Url), Max, D, Redirects - 1);
                false -> {error, missing_redirect_location}
            end;
        {gun_response, C, S, _, Code, _} -> {error, {http_status, Code}};
        {gun_inform, C, S, _, _} -> response(C, S, Url, Max, D, Redirects);
        {gun_error, C, S, Reason} -> {error, {transport, Reason}};
        {gun_error, C, Reason} -> {error, {transport, Reason}};
        {gun_down, C, _, Reason, _} -> {error, {transport, Reason}}
    after remaining(D) -> {error, timeout}
    end.

body(C, S, Max, D, N, Acc) ->
    receive
        {gun_data, C, S, Fin, B} ->
            Next = N + byte_size(B),
            case Next =< Max of
                false -> {error, size_limit_exceeded};
                true when Fin =:= fin -> {ok, iolist_to_binary(lists:reverse([B | Acc]))};
                true ->
                    gun:update_flow(C, S, 1),
                    body(C, S, Max, D, Next, [B | Acc])
            end;
        {gun_trailers, C, S, _} -> {ok, iolist_to_binary(lists:reverse(Acc))};
        {gun_error, C, S, Reason} -> {error, {transport, Reason}};
        {gun_error, C, Reason} -> {error, {transport, Reason}};
        {gun_down, C, _, Reason, _} -> {error, {transport, Reason}}
    after remaining(D) -> {error, timeout}
    end.

check_headers(Headers, Max) ->
    Encoding = proplists:get_value(<<"content-encoding">>, Headers, <<"identity">>),
    case string:lowercase(Encoding) of
        <<"identity">> -> check_length(proplists:get_value(<<"content-length">>, Headers), Max);
        _ -> {error, unsupported_content_encoding}
    end.
check_length(undefined, _) -> ok;
check_length(B, Max) ->
    try binary_to_integer(B) of
        N when N >= 0, N =< Max -> ok;
        _ -> {error, size_limit_exceeded}
    catch _:_ -> {error, invalid_content_length}
    end.
remaining(D) -> max(0, D - erlang:monotonic_time(millisecond)).
