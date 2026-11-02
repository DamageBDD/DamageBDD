%% Authoritative starter catalogue. Rendering is deterministic and network-free.
-module(damage_schedule_templates).
-license("Apache-2.0").
-export([catalog/0, render/2]).

catalog() -> [
    template(<<"http-uptime">>, <<"HTTP uptime & latency">>, <<"Availability">>,
        <<"Notice downtime and slow responses with one small GET check.">>,
        <<"*/15 * * * *">>, false, [url(<<"https://node.example.com/health">>),
            number(<<"expected_status">>, <<"Expected HTTP status">>, 200, 200, 599),
            number(<<"max_ms">>, <<"Maximum response time (ms)">>, 3000, 100, 30000)]),
    template(<<"content-canary">>, <<"Page content canary">>, <<"Availability">>,
        <<"Catch a broken deployment or unexpected landing page using expected public text.">>,
        <<"0 * * * *">>, false, [url(<<"https://node.example.com/">>),
            #{key => <<"contains">>, label => <<"Expected public text">>, type => <<"text">>,
                placeholder => <<"All systems operational">>, max_length => 256, required => true},
            number(<<"max_ms">>, <<"Maximum response time (ms)">>, 3000, 100, 30000)]),
    template(<<"tls-expiry">>, <<"TLS certificate expiry">>, <<"Security">>,
        <<"Verify HTTPS trust and hostname; fail before the certificate gets too close to expiry.">>,
        <<"0 9 * * *">>, false, [url(<<"https://node.example.com/">>),
            number(<<"min_days">>, <<"Minimum days remaining">>, 14, 1, 90)]),
    template(<<"security-headers">>, <<"Web security headers">>, <<"Security">>,
        <<"Check HSTS, nosniff, CSP and frame-protection headers on an HTTPS web page.">>,
        <<"0 9 * * *">>, false, [url(<<"https://node.example.com/">>)]),
    template(<<"node-exposure">>, <<"Self-hosted node exposure">>, <<"Security">>,
        <<"Check Git metadata, .env availability, Kubo RPC and Go debug endpoints. Read-only; not an exploit or CVE scan.">>,
        <<"0 9 * * *">>, true, [url(<<"https://node.example.com/">>)]),
    template(<<"docker-exposure">>, <<"Docker API exposure">>, <<"Security">>,
        <<"Check whether a deliberately selected Docker listener returns its version without credentials. No containers or commands are created.">>,
        <<"0 9 * * *">>, true, [url(<<"https://node.example.com:2376/">>)]),
    template(<<"ipfs-content">>, <<"IPFS content availability">>, <<"Decentralized">>,
        <<"Request the first 1 KiB of a gateway CID to catch missing content. This is a reachability check, not a CID integrity proof.">>,
        <<"0 * * * *">>, false, [url(<<"https://gateway.example.com/ipfs/YOUR_CID">>),
            number(<<"max_ms">>, <<"Maximum response time (ms)">>, 10000, 100, 30000)]),
    template(<<"nostr-relay">>, <<"Nostr relay information">>, <<"Decentralized">>,
        <<"Check NIP-11 HTTP metadata and supported_nips. Does not publish events or prove WebSocket delivery.">>,
        <<"*/15 * * * *">>, false, [url(<<"https://relay.example.com/">>)]),
    template(<<"auth-boundary">>, <<"Protected endpoint guard">>, <<"Security">>,
        <<"Check that an unauthenticated request still receives HTTP 401 or 403 after deployment.">>,
        <<"0 * * * *">>, true, [url(<<"https://node.example.com/admin">>)])
].

template(Id, Title, Category, Description, Cron, Security, Fields) ->
    #{id => Id, title => Title, category => Category, description => Description,
        cron_spec => Cron, timezone => <<"UTC">>, window_days => 7,
        security_check => Security, fields => Fields, requests_per_run => damage_monitor:request_count(Id),
        consent_required => true,
        authorization => <<"Only monitor systems you own or are authorized to test. Verify the exact host in Settings > Domains, or ask the operator for an owner-scoped target grant. Private targets require an explicit operator grant.">>}.
url(Placeholder) -> #{key => <<"target_url">>, label => <<"Target HTTP(S) URL">>, type => <<"url">>,
    placeholder => Placeholder, max_length => 2048, required => true}.
number(Key, Label, Default, Min, Max) -> #{key => Key, label => Label, type => <<"number">>,
    default => Default, min => Min, max => Max, required => true}.

-spec render(binary(), map()) -> {ok, map()} | {error, atom()}.
render(Id, Params) when is_binary(Id), is_map(Params) ->
    case [T || #{id := I} = T <- catalog(), I =:= Id] of
        [] -> {error, unknown_schedule_template};
        [Template] -> render_template(Template, Params)
    end;
render(_, _) -> {error, invalid_template_parameters}.

render_template(#{id := Id, title := Title, fields := Fields} = T, Params) ->
    try
        Allowed = [<<"authorized">> | [maps:get(key, F) || F <- Fields]],
        true = lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(Params)),
        true = maps:get(<<"authorized">>, Params, false) =:= true,
        {ok, Target} = damage_monitor_target:parse_url(maps:get(<<"target_url">>, Params, <<>>)),
        true = valid_target(Id, Target),
        OptionsIn = maps:without([<<"target_url">>, <<"authorized">>], Params),
        {ok, Options} = damage_monitor:options(Id, OptionsIn),
        Url = maps:get(url, Target),
        Feature = iolist_to_binary([
            <<"Feature: ">>, Title, <<" - ">>, Url, <<"\n\n">>,
            <<"  # Starter template v1. No target requests occur during budget preview.\n">>,
            <<"  # Each live run checks ownership and pins an allowed destination.\n">>,
            <<"  Scenario: Recurring verification of an authorized endpoint\n">>,
            <<"    Given I monitor the authorized URL \"">>, Url, <<"\"\n">>,
            <<"    When I run the \"">>, Id, <<"\" monitor with options\n">>,
            <<"      \"\"\"\n      ">>, jsx:encode(Options), <<"\n      \"\"\"\n">>,
            <<"    Then the monitor check must pass\n">>
        ]),
        {ok, #{template_id => Id, feature => Feature, target_url => Url,
            cron_spec => maps:get(cron_spec, T), timezone => <<"UTC">>, window_days => 7,
            requests_per_run => maps:get(requests_per_run, T),
            note => <<"Draft only. Review the feature and calculate the budget before enabling. Ownership is rechecked at execution; preview does not contact the target. Targets and expected text appear in feature/report artifacts: do not include secrets.">>}}
    catch _:_ -> {error, invalid_or_unauthorized_template_parameters} end.

valid_target(Id, #{scheme := Scheme, path := Path}) ->
    case Id of
        <<"tls-expiry">> -> Scheme =:= <<"https">>;
        <<"security-headers">> -> Scheme =:= <<"https">>;
        <<"node-exposure">> -> Path =:= <<"/">>;
        <<"docker-exposure">> -> Path =:= <<"/">>;
        <<"ipfs-content">> -> re:run(Path, <<"^/ipfs/[A-Za-z0-9]{20,128}(/.*)?$">>, [{capture, none}]) =:= match;
        _ -> true
    end.
