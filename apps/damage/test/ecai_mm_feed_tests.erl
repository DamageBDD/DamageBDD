-module(ecai_mm_feed_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

depth() ->
    #{
        <<"code">> => 0,
        <<"data">> => #{
            <<"a">> => [[<<"0.0101">>, <<"1000">>, 1]],
            <<"b">> => [[<<"0.0099">>, <<"1000">>, 1]]
        }
    }.
ticker() ->
    #{
        <<"code">> => <<"0">>,
        <<"data">> => [
            #{<<"symbol">> => <<"damageusdt">>, <<"price">> => <<"0.01">>},
            #{<<"symbol">> => <<"btcusdt">>, <<"price">> => <<"95000">>}
        ]
    }.

decode_test() ->
    ?assertMatch({ok, #{bid := 0.0099, ask := 0.0101}}, ecai_mm_feed:decode_depth(depth())),
    ?assertMatch({ok, #{btc_usdt := 95000.0}}, ecai_mm_feed:decode_prices(ticker())).

invalid_market_test() ->
    Bad = depth(),
    Data = maps:get(<<"data">>, Bad),
    Crossed = Bad#{<<"data">> => Data#{<<"a">> => [[<<"0.008">>, <<"1">>]]}},
    ?assertMatch({error, _}, ecai_mm_feed:decode_depth(Crossed)),
    ?assertMatch({error, _}, ecai_mm_feed:decode_prices(#{<<"code">> => 0, <<"data">> => []})).

adapter_test() ->
    Get = fun(Path) ->
        case lists:prefix("/v1/market/depth/", Path) of
            true -> {ok, depth()};
            false -> {ok, ticker()}
        end
    end,
    {ok, Snapshot} = ecai_mm_feed:fetch(Get),
    ?assertEqual(0.0099, maps:get(bid, Snapshot)),
    ?assertEqual(95000.0, maps:get(btc_usdt, Snapshot)),
    ?assertEqual(<<"coinstore">>, maps:get(source, Snapshot)).

%% Exercise the exact TLS policy used by https_get/1 without contacting an
%% exchange or depending on the host's CA bundle. This placeholder is only
%% passed through the option builder; it is never used in a TLS handshake.
tls_policy_preserves_peer_verification_test() ->
    CACerts = [<<"test-ca-placeholder">>],
    Opts = ecai_mm_feed:tls_options(CACerts),
    ?assertEqual(verify_peer, proplists:get_value(verify, Opts)),
    ?assertEqual(CACerts, proplists:get_value(cacerts, Opts)),
    ?assertEqual("api.coinstore.com", proplists:get_value(server_name_indication, Opts)),
    ?assertEqual(undefined, proplists:get_value(verify_fun, Opts)),
    Check = proplists:get_value(customize_hostname_check, Opts),
    ?assert(is_function(proplists:get_value(match_fun, Check), 2)),
    ?assertEqual(undefined, proplists:get_value(fail_callback, Check)).

https_hostname_accepts_reported_sans_test() ->
    %% Reproduce the exact SAN names from the reported TLS failure.
    Cert = hostname_certificate(["coinstore.com", "*.coinstore.com"]),
    ?assert(hostname_matches(Cert, "api.coinstore.com")).

https_hostname_accepts_exact_san_test() ->
    Cert = hostname_certificate(["api.coinstore.com"]),
    ?assert(hostname_matches(Cert, "api.coinstore.com")),
    ?assert(hostname_matches(Cert, "API.COINSTORE.COM")).

https_wildcard_is_limited_to_one_label_test() ->
    Cert = hostname_certificate(["*.coinstore.com"]),
    ?assert(hostname_matches(Cert, "api.coinstore.com")),
    ?assertNot(hostname_matches(Cert, "deep.api.coinstore.com")),
    %% A wildcard alone does not cover the bare domain.
    ?assertNot(hostname_matches(Cert, "coinstore.com")).

https_hostname_rejects_unrelated_hosts_test() ->
    Cert = hostname_certificate(["coinstore.com", "*.coinstore.com"]),
    lists:foreach(
        fun(Host) -> ?assertNot(hostname_matches(Cert, Host)) end,
        ["api.coinstore.com.evil.example", "api.coinstore.net", "notcoinstore.com"]
    ).

https_hostname_rejects_wrong_certificate_test() ->
    Cert = hostname_certificate(["example.com", "*.example.com"]),
    ?assertNot(hostname_matches(Cert, "api.coinstore.com")).

tls_failure_is_not_bypassed_test() ->
    Reason = {failed_connect, [
        {to_address, {"api.coinstore.com", 443}},
        {inet, [inet], {tls_alert, {bad_certificate, "test certificate failure"}}}
    ]},
    Get = fun(Path) ->
        case lists:prefix("/v1/market/depth/", Path) of
            true -> {error, Reason};
            false -> {ok, ticker()}
        end
    end,
    ?assertEqual({error, {depth_request, Reason}}, ecai_mm_feed:fetch(Get)).

hostname_matches(Cert, Host) ->
    Opts = ecai_mm_feed:tls_options([]),
    Check = proplists:get_value(customize_hostname_check, Opts),
    public_key:pkix_verify_hostname(Cert, [{dns_id, Host}], Check).

%% This decoded record is a hostname-only fixture, not a signed certificate.
%% These tests check hostname policy, not certificate-chain validity. The
%% production ssl client still checks the real chain with verify_peer.
hostname_certificate(Names) ->
    #'OTPCertificate'{
        tbsCertificate = #'OTPTBSCertificate'{
            subject = {rdnSequence, []},
            extensions = [
                #'Extension'{
                    extnID = ?'id-ce-subjectAltName',
                    critical = false,
                    extnValue = [{dNSName, Name} || Name <- Names]
                }
            ]
        }
    }.
