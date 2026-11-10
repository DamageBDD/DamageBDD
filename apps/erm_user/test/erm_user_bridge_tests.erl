-module(erm_user_bridge_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

credential_private_and_digest_test() ->
    with_dir(fun(D) ->
        P = filename:join(D, "private/damage.token"),
        {ok, Digest} = erm_user_credentials:create(P),
        ?assertEqual(64, byte_size(Digest)),
        {ok, Token} = erm_user_config:read_token(P),
        ?assertNotEqual(Token, Digest),
        ?assertEqual({ok, Digest}, erm_user_credentials:create(P)),
        {ok, #file_info{mode = Mode}} = file:read_file_info(P),
        ?assertEqual(0, Mode band 8#077),
        ?assertEqual({ok, Digest}, erm_user_credentials:create(P))
    end).
credential_refuses_world_readable_test() ->
    with_dir(fun(D) ->
        P = filename:join(D, "damage.token"),
        ok = file:write_file(P, binary:copy(<<"a">>, 64)),
        ok = file:change_mode(P, 8#644),
        ?assertEqual({error, unsafe_credential}, erm_user_config:read_token(P)),
        ?assertEqual({error, existing_credential_not_private}, erm_user_credentials:create(P))
    end).
credential_refuses_symlink_test() ->
    with_dir(fun(D) ->
        P = filename:join(D, "target"), Link = filename:join(D, "link"),
        {ok, _} = erm_user_credentials:create(P), ok = file:make_symlink(P, Link),
        ?assertEqual({error, unsafe_credential}, erm_user_config:read_token(Link)),
        ?assertEqual({error, existing_credential_not_private}, erm_user_credentials:create(Link))
    end).
credential_rejects_unsafe_ancestor_test() ->
    with_dir(fun(D) ->
        Bad = filename:join(D, "writable"), ok = file:make_dir(Bad),
        ok = file:change_mode(Bad, 8#777),
        ?assertMatch({error, _}, erm_user_credentials:create(filename:join(Bad, "private/token")))
    end).
credential_rejects_symlink_ancestor_test() ->
    with_dir(fun(D) ->
        Real = filename:join(D, "real"), Link = filename:join(D, "link"),
        ok = file:make_dir(Real), ok = file:change_mode(Real, 8#700),
        ok = file:make_symlink(Real, Link),
        ?assertMatch({error, _}, erm_user_credentials:create(filename:join(Link, "token")))
    end).
credential_invalid_encoding_test() ->
    with_dir(fun(D) ->
        P = filename:join(D, "token"),
        ok = file:write_file(P, <<"not-a-token">>), ok = file:change_mode(P, 8#600),
        ?assertEqual({error, invalid_credential}, erm_user_config:read_token(P))
    end).
config_refuses_damage_application_test() ->
    with_dir(fun(D) ->
        P = filename:join(D, "user.config"),
        ok = file:write_file(P, <<"[{damage,[{port,1}]}].\n">>),
        ok = file:change_mode(P, 8#600),
        ?assertEqual({error, forbidden_user_config_application}, erm_user_config:load_user_config(P))
    end).
config_only_user_apps_test() ->
    with_dir(fun(D) ->
        P = filename:join(D, "user.config"),
        ok = file:write_file(P, <<"[{erm,[{media_enabled,false}]},{erm_user,[{local_distribution,false}]}].\n">>),
        ok = file:change_mode(P, 8#600),
        ?assertEqual(ok, erm_user_config:load_user_config(P)),
        ?assertEqual({ok, false}, application:get_env(erm, media_enabled))
    end).
unsupported_operation_test() ->
    ?assertEqual({error, unsupported_operation},
        erm_user_bridge:request({erlang, halt, []}, #{bridge_server_uid => erm_user_config:uid()})).
limits_test() ->
    ?assertMatch({error, _}, erm_user_bridge:options(#{request_timeout_ms => 4000})),
    ?assertMatch({error, _}, erm_user_bridge:options(#{connect_timeout_ms => 0})),
    ?assertMatch({error, _}, erm_user_bridge:server_uid(#{bridge_server_uid => -1})).
path_validation_test() ->
    ?assertEqual({error, unsafe_socket_path}, erm_user_config:validate_socket("relative.sock", 0)),
    ?assertEqual({error, unsafe_socket_path}, erm_user_config:validate_socket("/run/../tmp/socket", 0)).
server_user_resolution_test() ->
    ?assertEqual({ok, 0}, erm_user_bridge:server_uid(#{bridge_server_user => "root"})),
    ?assertEqual({error, unknown_bridge_server_user},
        erm_user_bridge:server_uid(#{bridge_server_user => "erm-user-no-such-account-923875"})).

%% The production connector is Unix-domain only. These tests use a loopback
%% fixture for the framing/decoder, allowing restricted CI sandboxes to verify
%% real packet4 traffic without adding a TCP production fallback.
protocol_success_test() ->
    ?assertEqual({ok, #{<<"pong">> => true}}, exchange_reply(
        jsx:encode(#{v => 1, ok => true, result => #{pong => true}}))).
protocol_authorization_test() ->
    ?assertEqual({error, unauthorized}, exchange_reply(
        jsx:encode(#{v => 1, ok => false, error => <<"unauthorized">>}))),
    ?assertEqual({error, forbidden}, exchange_reply(
        jsx:encode(#{v => 1, ok => false, error => <<"forbidden">>}))).
protocol_redacts_peer_error_test() ->
    ?assertEqual({error, remote_error}, exchange_reply(
        jsx:encode(#{v => 1, ok => false, error => <<"secret-token-do-not-log">>}))).
protocol_rejects_extra_fields_test() ->
    ?assertEqual({error, invalid_response}, exchange_reply(
        jsx:encode(#{v => 1, ok => true, result => #{}, token => <<"secret">>}))).
protocol_rejects_invalid_json_test() ->
    ?assertEqual({error, invalid_response}, exchange_reply(<<"invalid-json">>)).
protocol_rejects_large_response_test() ->
    ?assertEqual({error, invalid_response}, exchange_reply(binary:copy(<<"a">>, 65537))).
protocol_timeout_test() ->
    {Listener, Port} = listener(),
    Parent = self(),
    Peer = spawn(fun() ->
        {ok, S} = gen_tcp:accept(Listener),
        {ok, _} = gen_tcp:recv(S, 0, 1000), Parent ! waiting,
        receive stop -> gen_tcp:close(S) after 1000 -> gen_tcp:close(S) end
    end),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port, [binary,{packet,4},{active,false}],1000),
    ?assertEqual({error, timeout}, erm_user_bridge:exchange(Client, request(), 20)),
    receive waiting -> ok after 1000 -> error(no_fixture) end,
    Peer ! stop, gen_tcp:close(Client), gen_tcp:close(Listener).

exchange_reply(Reply) ->
    {L, Port} = listener(),
    Parent = self(),
    spawn(fun() ->
        {ok, S} = gen_tcp:accept(L),
        {ok, Raw} = gen_tcp:recv(S, 0, 1000),
        Parent ! {fixture_request, jsx:decode(Raw, [return_maps])},
        gen_tcp:send(S, Reply), gen_tcp:close(S)
    end),
    {ok, C} = gen_tcp:connect({127,0,0,1}, Port,
        [binary,{packet,4},{packet_size,65536},{active,false}], 1000),
    Result = erm_user_bridge:exchange(C, request(), 1000),
    receive {fixture_request, R} -> ?assertEqual(request(), R)
    after 1000 -> error(no_request) end,
    gen_tcp:close(C), gen_tcp:close(L), Result.
listener() ->
    {ok, L} = gen_tcp:listen(0,[binary,{packet,4},{active,false},{ip,{127,0,0,1}}]),
    {ok, {_, Port}} = inet:sockname(L), {L, Port}.
request() -> #{<<"v">> => 1, <<"op">> => <<"ping">>, <<"token">> => binary:copy(<<"a">>,64)}.
with_dir(F) ->
    D = filename:join("/tmp", "erm-user-test-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(D), ok = file:change_mode(D, 8#700),
    try F(D) after file:del_dir_r(D) end.
