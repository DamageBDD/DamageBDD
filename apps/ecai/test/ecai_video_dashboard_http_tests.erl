-module(ecai_video_dashboard_http_tests).
-include_lib("eunit/include/eunit.hrl").

-define(A, <<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>).
-define(B, <<"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">>).

routes_are_fixed_and_methods_restricted_test() ->
    Project = #{bindings => #{project => ?A}},
    Version = #{bindings => #{id => ?B}},
    ?assertEqual(
        {ok, <<"/v1/projects">>, json},
        ecai_video_dashboard_http:route(projects, <<"GET">>, #{})
    ),
    ?assertEqual(
        {ok, <<"/v1/projects/", ?A/binary, "/generations">>, json},
        ecai_video_dashboard_http:route(generate, <<"POST">>, Project)
    ),
    ?assertEqual(
        {ok, <<"/v1/projects/", ?A/binary, "/jobs">>, json},
        ecai_video_dashboard_http:route(project_jobs, <<"GET">>, Project)
    ),
    ?assertMatch({error, _}, ecai_video_dashboard_http:route(generate, <<"GET">>, Project)),
    ?assertMatch({error, _}, ecai_video_dashboard_http:route(projects, <<"DELETE">>, #{})),
    ?assertEqual(
        {ok, <<"/v1/versions/", ?B/binary, "/video">>, binary_video},
        ecai_video_dashboard_http:route(video, <<"GET">>, Version)
    ),
    ?assertMatch({error, _}, ecai_video_dashboard_http:route(nft_draft, <<"GET">>, Version)).

no_arbitrary_paths_test() ->
    Bad = #{bindings => #{project => <<"../../../admin">>}},
    ?assertMatch({error, _}, ecai_video_dashboard_http:route(versions, <<"GET">>, Bad)),
    ?assertMatch(
        {error, _},
        ecai_video_dashboard_http:route(
            versions,
            <<"POST">>,
            #{bindings => #{project => <<"cBADcBADcBADcBADcBADcBADcBADcBAD">>}}
        )
    ).

signed_account_isolation_test() ->
    PrincipalA = <<"ak_example_account_A">>,
    PrincipalB = <<"ak_example_account_B">>,
    TenantA = ecai_video_dashboard_http:tenant_for(PrincipalA),
    TenantB = ecai_video_dashboard_http:tenant_for(PrincipalB),
    ?assertNotEqual(TenantA, TenantB),
    ?assertEqual(45, byte_size(TenantA)),
    Secret = <<"shared-test-secret-with-at-least-32-bytes">>,
    T = <<"1791691380">>,
    Path = <<"/v1/projects">>,
    Token = ecai_video_dashboard_http:bridge_token(Secret, PrincipalA, T, <<"POST">>, Path),
    Msg = <<TenantA/binary, "\n", T/binary, "\nPOST\n", Path/binary>>,
    Signature = list_to_binary(
        string:lowercase(
            binary_to_list(
                binary:encode_hex(crypto:mac(hmac, sha256, Secret, Msg))
            )
        )
    ),
    ?assertEqual(<<"bridge1.", TenantA/binary, ".", T/binary, ".", Signature/binary>>, Token).
