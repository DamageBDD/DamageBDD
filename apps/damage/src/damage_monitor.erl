%% Read-only, bounded recurring probes. Bodies/credentials never enter results.
-module(damage_monitor).
-license("Apache-2.0").
-include_lib("public_key/include/public_key.hrl").
-export([options/2, request_count/1, run/4, check/4, certificate_expiry/1]).

-spec options(binary(), map()) -> {ok, map()} | {error, atom()}.
options(Profile, M) when is_map(M) ->
    try
        Allowed = option_keys(Profile),
        true = lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(M)),
        O = case Profile of
            <<"http-uptime">> -> #{<<"expected_status">> => number(M, <<"expected_status">>, 200, 200, 599),
                <<"max_ms">> => number(M, <<"max_ms">>, 3000, 100, 30000)};
            <<"content-canary">> -> #{<<"contains">> => text(maps:get(<<"contains">>, M, <<>>)),
                <<"max_ms">> => number(M, <<"max_ms">>, 3000, 100, 30000)};
            <<"tls-expiry">> -> #{<<"min_days">> => number(M, <<"min_days">>, 14, 1, 90)};
            <<"ipfs-content">> -> #{<<"max_ms">> => number(M, <<"max_ms">>, 10000, 100, 30000)};
            _ -> #{}
        end,
        {ok, O}
    catch _:_ -> {error, invalid_monitor_options} end;
options(_, _) -> {error, invalid_monitor_options}.

option_keys(<<"http-uptime">>) -> [<<"expected_status">>, <<"max_ms">>];
option_keys(<<"content-canary">>) -> [<<"contains">>, <<"max_ms">>];
option_keys(<<"tls-expiry">>) -> [<<"min_days">>];
option_keys(<<"ipfs-content">>) -> [<<"max_ms">>];
option_keys(<<"security-headers">>) -> [];
option_keys(<<"node-exposure">>) -> [];
option_keys(<<"docker-exposure">>) -> [];
option_keys(<<"nostr-relay">>) -> [];
option_keys(<<"auth-boundary">>) -> [].
number(M, K, Default, Min, Max) ->
    N = maps:get(K, M, Default),
    true = is_integer(N) andalso N >= Min andalso N =< Max,
    N.
text(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 256 ->
    true = re:run(B, <<"[\\x00-\\x1f\\x7f\"\\\\{}]">>, [{capture, none}]) =:= nomatch,
    B.

request_count(<<"node-exposure">>) -> 4;
request_count(Profile) -> _ = option_keys(Profile), 1.

-spec run(binary(), binary(), binary(), map()) -> map().
run(Profile, Url, Owner, Options0) ->
    try
        {ok, Options} = options(Profile, Options0),
        {ok, Target} = damage_monitor_target:parse_url(Url),
        case damage_monitor_target:authorize(Target, Owner) of
            ok ->
                case damage_monitor_target:pin(Target, Owner) of
                    {ok, Pinned} -> run_pinned(Profile, Pinned, Options);
                    {error, Why} -> unavailable(Why)
                end;
            {error, Why} -> unavailable(Why)
        end
    catch _:_ -> unavailable(monitor_check_failed) end.

run_pinned(<<"tls-expiry">>, Target, Options) -> tls_check(Target, Options);
run_pinned(Profile, Target, Options) ->
    check(Profile, Target, Options, fun request/4).

request(#{ip := IP, port := Port, authority := Authority, scheme := Scheme} = Target,
        Method, Path, ExtraHeaders) ->
    %% Never forward account auth, cookies, request context or proxy settings.
    Headers = [{<<"host">>, Authority}, {<<"user-agent">>, <<"DamageBDD-monitor/1">>},
        {<<"accept-encoding">>, <<"identity">>} | ExtraHeaders],
    Opts0 = #{proxy => direct, transport => case Scheme of <<"https">> -> tls; _ -> tcp end,
        protocols => [http], retry => 0, connect_timeout => 3000, timeout => 10000,
        tcp_opts => case tuple_size(IP) of 8 -> [inet6]; _ -> [inet] end,
        close => true, decode => raw, max_response_bytes => 65536},
    Opts = case Scheme of
        <<"https">> -> Opts0#{tls_opts => damage_monitor_target:tls_options(Target)};
        _ -> Opts0
    end,
    %% Gun receives a numeric literal, with original Host/SNI explicitly set.
    %% It does not follow redirects; no URL re-parsing or DNS at HTTP time.
    Started = erlang:monotonic_time(millisecond),
    try damage_gun:request(Method, inet:ntoa(IP), Port, Path, Headers, <<>>, Opts) of
        {ok, R} -> {ok, R#{elapsed_ms => erlang:monotonic_time(millisecond) - Started}};
        {error, response_too_large} -> {error, response_too_large};
        _ -> {error, network_or_tls_error}
    catch _:_ -> {error, network_or_tls_error} end.

%% Pure evaluation seam: tests supply a deterministic transport. Production
%% callers can only use the authorized/pinned run/4 entry point above.
-spec check(binary(), map(), map(), fun((map(), atom(), binary(), list()) -> term())) -> map().
check(<<"node-exposure">>, Target, _O, Fetch) ->
    Checks = [probe(Name, Method, Path, Target, Fetch) || {Name, Method, Path} <- [
        {<<"git-head">>, get, <<"/.git/HEAD">>},
        {<<"dotenv">>, head, <<"/.env">>},
        {<<"kubo-rpc">>, post, <<"/api/v0/version">>},
        {<<"go-pprof">>, get, <<"/debug/pprof/">>}
    ]],
    result(Checks);
check(<<"docker-exposure">>, Target, _O, Fetch) ->
    result([probe(<<"docker-api">>, get, <<"/version">>, Target, Fetch)]);
check(Profile, #{path := Path} = Target, O, Fetch) ->
    Headers = case Profile of
        <<"nostr-relay">> -> [{<<"accept">>, <<"application/nostr+json">>}];
        <<"ipfs-content">> -> [{<<"range">>, <<"bytes=0-1023">>}];
        _ -> []
    end,
    %% GET is intentional for uptime: HEAD can be disabled while GET works.
    R = Fetch(Target, get, Path, Headers),
    result([evaluate(Profile, R, Target, O)]).

probe(Name, Method, Path, Target, Fetch) ->
    Headers = case Method of get -> [{<<"range">>, <<"bytes=0-8191">>}]; _ -> [] end,
    exposure(Name, Fetch(Target, Method, Path, Headers)).

exposure(Name, {ok, #{status := S} = R}) when S =:= 401; S =:= 403; S =:= 404; S =:= 410 ->
    observed(Name, pass, <<"Endpoint denied or absent from this runner's network position.">>, R);
exposure(Name, {ok, #{status := S, body := Body} = R}) when S >= 200, S < 300 ->
    case fingerprint(Name, Body) of
        true -> observed(Name, fail, remediation(Name), R);
        false -> observed(Name, inconclusive,
            <<"Successful response without a service fingerprint; review routing/SPA fallback. Not proof of safety.">>, R)
    end;
exposure(Name, {ok, R}) -> observed(Name, inconclusive,
    <<"Redirect or unexpected HTTP response; check this endpoint directly. Not proof of safety.">>, R);
exposure(Name, {error, _}) -> finding(Name, inconclusive,
    <<"Request failed or exceeded the response limit; exposure was not determined.">>).

fingerprint(<<"git-head">>, Body) ->
    re:run(Body, <<"^(ref: refs/[^\\r\\n]+|[0-9a-f]{40})[\\r\\n]*$">>, [{capture, none}]) =:= match;
fingerprint(<<"dotenv">>, _Body) -> false; %% HEAD only: never retrieve possible secrets.
fingerprint(<<"kubo-rpc">>, Body) ->
    J = json(Body), is_binary(maps:get(<<"Version">>, J, undefined)) andalso maps:is_key(<<"Repo">>, J);
fingerprint(<<"docker-api">>, Body) ->
    J = json(Body), is_binary(maps:get(<<"ApiVersion">>, J, undefined)) andalso
        is_binary(maps:get(<<"Version">>, J, undefined));
fingerprint(<<"go-pprof">>, Body) ->
    binary:match(Body, <<"/debug/pprof/goroutine">>) =/= nomatch orelse
        binary:match(Body, <<"Types of profiles available">>) =/= nomatch.
remediation(<<"git-head">>) -> <<"Git metadata is reachable. Remove .git from the web root and deny dotfiles.">>;
remediation(<<"kubo-rpc">>) -> <<"Kubo RPC responds without credentials. Remove public exposure; bind the API to a private interface.">>;
remediation(<<"docker-api">>) -> <<"Docker API responds without credentials. Disable public access or require authenticated TLS/SSH.">>;
remediation(<<"go-pprof">>) -> <<"Go profiling is reachable. Restrict debug endpoints to an authenticated private listener.">>.

evaluate(Profile, {error, _}, _Target, _O) -> finding(Profile, inconclusive,
    <<"Connection, TLS, timeout or response-size failure; no successful verification.">>);
evaluate(<<"http-uptime">> = P, {ok, #{status := Status} = R}, _T, O) ->
    Pass = Status =:= maps:get(<<"expected_status">>, O) andalso fast_enough(R, O),
    verdict(P, Pass, <<"HTTP status and latency threshold">>, R);
evaluate(<<"content-canary">> = P, {ok, #{status := Status, body := Body} = R}, _T, O) ->
    Pass = Status =:= 200 andalso fast_enough(R, O) andalso
        binary:match(Body, maps:get(<<"contains">>, O)) =/= nomatch,
    verdict(P, Pass, <<"HTTP 200, expected public text and latency threshold">>, R);
evaluate(<<"auth-boundary">> = P, {ok, #{status := Status} = R}, _T, _O) ->
    verdict(P, Status =:= 401 orelse Status =:= 403,
        <<"Unauthenticated request must be rejected with HTTP 401 or 403">>, R);
evaluate(<<"nostr-relay">> = P, {ok, #{status := Status, body := Body} = R}, _T, _O) ->
    J = json(Body),
    Nips = maps:get(<<"supported_nips">>, J, undefined),
    Valid = is_list(Nips) andalso lists:all(fun(N) -> is_integer(N) andalso N >= 0 end, Nips),
    verdict(P, Status =:= 200 andalso Valid,
        <<"NIP-11 JSON with supported_nips; does not verify WebSocket event delivery">>, R);
evaluate(<<"ipfs-content">> = P, {ok, #{status := Status, body := Body} = R}, _T, O) ->
    %% A small range request proves reachability, not CID/content integrity.
    RangeOK = Status =:= 200 orelse (Status =:= 206 andalso
        re:run(header(<<"content-range">>, R), <<"^bytes 0-[0-9]+/[0-9]+$">>, [{capture, none}]) =:= match),
    verdict(P, RangeOK andalso byte_size(Body) > 0 andalso fast_enough(R, O),
        <<"Gateway returned a nonempty bounded content response; CID integrity not checked">>, R);
evaluate(<<"security-headers">> = P, {ok, #{status := Status} = R}, T, _O) ->
    CSP = header(<<"content-security-policy">>, R),
    Frame = string:lowercase(header(<<"x-frame-options">>, R)),
    HSTS = header(<<"strict-transport-security">>, R),
    Checks = [
        {<<"x-content-type-options">>, string:lowercase(header(<<"x-content-type-options">>, R)) =:= <<"nosniff">>},
        {<<"content-security-policy">>, byte_size(CSP) > 0},
        {<<"frame-protection">>, Frame =:= <<"deny">> orelse Frame =:= <<"sameorigin">> orelse
            strict_frame_policy(CSP)},
        {<<"strict-transport-security">>, maps:get(scheme, T) =:= <<"https">> andalso
            re:run(HSTS, <<"(?i)(^|;)\\s*max-age=[1-9][0-9]*(;|$)">>, [{capture, none}]) =:= match}
    ],
    Missing = [Name || {Name, false} <- Checks],
    (verdict(P, Status =:= 200 andalso Missing =:= [],
        <<"Browser security header baseline; presence is not a complete policy audit">>, R))#{missing => Missing}.

strict_frame_policy(CSP) ->
    %% A wildcard frame-ancestors directive is not protection. The starter
    %% deliberately expects 'self' or 'none'; custom ancestor allowlists need
    %% their own policy-specific feature rather than a misleading green result.
    re:run(CSP, <<"(?i)(^|;)\\s*frame-ancestors\\s+'(self|none)'\\s*(;|$)">>,
        [{capture, none}]) =:= match.

fast_enough(R, O) -> maps:get(elapsed_ms, R, 30001) =< maps:get(<<"max_ms">>, O).
header(Key, R) ->
    Headers = maps:get(headers, R, []),
    Values = [iolist_to_binary(V) || {K, V} <- Headers,
        string:lowercase(iolist_to_binary(K)) =:= Key],
    case Values of [V | _] -> string:trim(V); [] -> <<>> end.
json(B) ->
    try jsx:decode(B, [return_maps]) of M when is_map(M) -> M; _ -> #{} catch _:_ -> #{} end.
verdict(Name, true, Detail, R) -> observed(Name, pass, Detail, R);
verdict(Name, false, Detail, R) -> observed(Name, fail, Detail, R).
observed(Name, Outcome, Detail, R) ->
    (finding(Name, Outcome, Detail))#{http_status => maps:get(status, R, 0),
        elapsed_ms => maps:get(elapsed_ms, R, 0)}.
finding(Name, Outcome, Detail) -> #{check => Name, outcome => Outcome, detail => Detail}.
result(Checks) ->
    Outcomes = [maps:get(outcome, C) || C <- Checks],
    Outcome = case lists:member(fail, Outcomes) of
        true -> fail;
        false -> case lists:member(inconclusive, Outcomes) of true -> inconclusive; false -> pass end
    end,
    #{outcome => Outcome, checks => Checks}.
unavailable(Reason) -> result([finding(<<"target">>, inconclusive, atom_to_binary(Reason, utf8))]).

tls_check(#{scheme := <<"https">>, ip := IP, port := Port} = Target, O) ->
    Opts = [{active, false}, binary | damage_monitor_target:tls_options(Target)],
    case ssl:connect(IP, Port, Opts, 5000) of
        {ok, Socket} ->
            try
                {ok, Der} = ssl:peercert(Socket),
                {ok, Expiry} = certificate_expiry(Der),
                Seconds = Expiry - erlang:system_time(second),
                Days = Seconds div 86400,
                Pass = Seconds >= maps:get(<<"min_days">>, O) * 86400,
                Outcome = case Pass of true -> pass; false -> fail end,
                result([(finding(<<"tls-expiry">>, Outcome,
                    <<"Verified certificate chain/hostname and minimum remaining validity">>))#{
                        days_remaining => Days, expires_at => Expiry}])
            catch _:_ -> unavailable(tls_certificate_unreadable)
            after ssl:close(Socket) end;
        _ -> unavailable(tls_verification_failed)
    end;
tls_check(_, _) -> unavailable(https_required).

-spec certificate_expiry(binary()) -> {ok, integer()} | {error, atom()}.
certificate_expiry(Der) ->
    try
        #'OTPCertificate'{tbsCertificate = #'OTPTBSCertificate'{validity =
            #'Validity'{notAfter = Time}}} = public_key:pkix_decode_cert(Der, otp),
        DT = asn1_datetime(Time),
        {ok, calendar:datetime_to_gregorian_seconds(DT) -
            calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})}
    catch _:_ -> {error, invalid_certificate_time} end.
asn1_datetime({utcTime, Time}) ->
    <<YY:2/binary, Rest/binary>> = iolist_to_binary(Time),
    Y = binary_to_integer(YY),
    Century = case Y >= 50 of true -> 1900; false -> 2000 end,
    datetime(Century + Y, Rest);
asn1_datetime({generalTime, Time}) ->
    <<YYYY:4/binary, Rest/binary>> = iolist_to_binary(Time),
    datetime(binary_to_integer(YYYY), Rest).
datetime(Y, <<M:2/binary, D:2/binary, H:2/binary, Min:2/binary, S:2/binary, "Z">>) ->
    {{Y, binary_to_integer(M), binary_to_integer(D)},
        {binary_to_integer(H), binary_to_integer(Min), binary_to_integer(S)}}.
