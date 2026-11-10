-module(damage_erm_bridge_tests).
-include_lib("eunit/include/eunit.hrl").

%% Real framing and handlers are exercised over a loopback socket pair because
%% the build sandbox denies AF_UNIX creation. Production has no TCP fallback.
bridge_test_() ->
    {timeout, 20, [
      {"disabled listener is absent", fun disabled/0},
      {"correct capability authenticates", fun() -> fixture(fun authenticates/1) end},
      {"incorrect token is rejected", fun() -> fixture(fun bad_token/1) end},
      {"operations are scoped", fun() -> fixture(fun forbidden/1) end},
      {"capabilities expose only principal grant", fun() -> fixture(fun capabilities/1) end},
      {"revocation applies without restarting listener", fun() -> fixture(fun revoke/1) end},
      {"world-readable grants fail closed", fun() -> fixture(fun unsafe_grants/1) end},
      {"symlink grants fail closed", fun() -> fixture(fun symlink_grants/1) end},
      {"writable ancestors cannot forge grants", fun() -> fixture(fun unsafe_ancestor/1) end},
      {"strict version and request keys", fun() -> fixture(fun strict_requests/1) end},
      {"malformed JSON cannot crash handler pool", fun() -> fixture(fun malformed/1) end},
      {"oversized frames close before decoding", fun() -> fixture(fun oversized/1) end},
      {"silent clients time out", fun() -> fixture(fun silent/1) end},
      {"status does not disclose server configuration", fun() -> fixture(fun redacted_status/1) end},
      {"duplicate grants fail closed", fun() -> fixture(fun duplicate_grants/1) end},
      {"invalid limits are rejected", fun invalid_config/0}
    ]}.

disabled() ->
    ?assertEqual(ignore, damage_erm_bridge:start_link(#{})),
    ?assertEqual(ignore, damage_erm_bridge:start_link(#{enabled => false})),
    ?assertEqual(#{enabled => false}, damage_erm_bridge:status()).
invalid_config() ->
    ?assertMatch({error, invalid_bridge_config},
        damage_erm_bridge:configure(#{max_clients => 33})),
    ?assertMatch({error, invalid_bridge_config},
        damage_erm_bridge:configure(#{request_timeout_ms => 60000})),
    ?assertMatch({error, invalid_bridge_config},
        damage_erm_bridge:configure(#{socket => "/tmp/../tmp/untrusted"})).

fixture(Fun) ->
    {ok, _} = application:ensure_all_started(crypto),
    Dir = filename:join("/tmp", "damage-erm-bridge-test-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    ok = file:make_dir(Dir), ok = file:change_mode(Dir, 8#755),
    P = filename:join(Dir, "grants.config"),
    Token = << <<$a>> || _ <- lists:seq(1,64) >>,
    Grant = #{id => <<"test-user">>, token_sha256 => hex(crypto:hash(sha256, Token)),
              operations => [<<"ping">>, <<"status">>, <<"capabilities">>]},
    ok = write_grants(P, [Grant]),
    {ok, Config} = damage_erm_bridge:configure(#{socket => filename:join(Dir,"bridge.sock"),
                 grants_file => P, request_timeout_ms => 100}),
    C = #{config => Config, token => Token, grants => P, dir => Dir, grant => Grant},
    try Fun(C)
    after
        file:delete(filename:join(Dir, "real.config")),
        file:delete(P), file:del_dir(Dir)
    end.
write_grants(P, Grants) ->
    ok = file:write_file(P, io_lib:format("~p.~n", [Grants])),
    file:change_mode(P, 8#640).
hex(B) -> list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(B)))).
request(C, Op) -> #{<<"v">> => 1, <<"token">> => maps:get(token,C), <<"op">> => Op}.
reply(C, Request) ->
    wire(C, fun(S) ->
        ok = gen_tcp:send(S, jsx:encode(Request)),
        {ok, B} = gen_tcp:recv(S, 0, 1000),
        jsx:decode(B, [return_maps])
    end).
wire(C, Fun) ->
    {ok,L} = gen_tcp:listen(0,[{inet_backend,inet},binary,{ip,{127,0,0,1}},
                                  {active,false},{packet,4},{packet_size,65536}]),
    {ok,{_,Port}} = inet:sockname(L),
    {ok,Client} = gen_tcp:connect({127,0,0,1},Port,[{inet_backend,inet},binary,
                                  {active,false},{packet,4}],1000),
    {ok,Server} = gen_tcp:accept(L,1000),
    Config = maps:get(config,C),
    Pid = spawn(fun() ->
        receive {serve,S} ->
            try damage_erm_bridge:serve(S,Config)
            after gen_tcp:close(S) end
        end
    end),
    ok = gen_tcp:controlling_process(Server,Pid), Pid ! {serve,Server},
    try Fun(Client)
    after gen_tcp:close(Client),gen_tcp:close(L),exit(Pid,kill) end.
error_reply(Code) -> #{<<"v">> => 1, <<"ok">> => false, <<"error">> => Code}.

authenticates(C) ->
    ?assertEqual(#{<<"v">>=>1,<<"ok">>=>true,<<"result">>=>#{<<"pong">>=>true}},
                 reply(C,request(C,<<"ping">>))).
bad_token(C) ->
    R = (request(C,<<"ping">>))#{<<"token">> := << <<$b>> || _ <- lists:seq(1,64) >>},
    ?assertEqual(error_reply(<<"unauthorized">>),reply(C,R)).
forbidden(C) ->
    G = (maps:get(grant,C))#{operations := [<<"ping">>]},
    ok = write_grants(maps:get(grants,C),[G]),
    ?assertEqual(error_reply(<<"forbidden">>),reply(C,request(C,<<"status">>))),
    ?assertEqual(error_reply(<<"forbidden">>),reply(C,request(C,<<"rpc">>))).
capabilities(C) ->
    R = reply(C,request(C,<<"capabilities">>)),
    ?assertEqual(#{<<"principal">> => <<"test-user">>,
                   <<"operations">> => [<<"ping">>,<<"status">>,<<"capabilities">>]},
                 maps:get(<<"result">>,R)).
revoke(C) ->
    authenticates(C),
    ok = write_grants(maps:get(grants,C),[]),
    ?assertEqual(error_reply(<<"unauthorized">>),reply(C,request(C,<<"ping">>))).
unsafe_grants(C) ->
    ok = file:change_mode(maps:get(grants,C),8#644),
    ?assertEqual(error_reply(<<"authorization_unavailable">>),reply(C,request(C,<<"ping">>))).
symlink_grants(C) ->
    P = maps:get(grants,C), Real = filename:join(maps:get(dir,C),"real.config"),
    ok = file:rename(P,Real),ok = file:make_symlink(Real,P),
    ?assertEqual(error_reply(<<"authorization_unavailable">>),reply(C,request(C,<<"ping">>))).
unsafe_ancestor(C) ->
    Base = filename:join(maps:get(dir,C), "untrusted"),
    Child = filename:join(Base, "trusted-looking"),
    P = filename:join(Child, "grants.config"),
    ok = file:make_dir(Base), ok = file:change_mode(Base,8#777),
    ok = file:make_dir(Child), ok = file:change_mode(Child,8#755),
    ok = write_grants(P,[maps:get(grant,C)]),
    Config = (maps:get(config,C))#{grants_file := P},
    try
        ?assertEqual(error_reply(<<"authorization_unavailable">>),
                     reply(C#{config := Config},request(C,<<"ping">>)))
    after file:delete(P),file:del_dir(Child),file:del_dir(Base) end.
strict_requests(C) ->
    R = request(C,<<"ping">>),
    [?assertEqual(error_reply(<<"invalid_request">>),reply(C,Bad)) || Bad <-
       [R#{<<"v">> := 2}, R#{<<"module">> => <<"os">>},
        R#{<<"token">> := <<"short">>}, R#{<<"op">> := [<<"ping">>]},
        maps:remove(<<"token">>,R)]],ok.
malformed(C) ->
    wire(C,fun(S) ->
        ok = gen_tcp:send(S,<<"{malformed">>),
        {ok,B} = gen_tcp:recv(S,0,1000),
        ?assertEqual(error_reply(<<"invalid_request">>),jsx:decode(B,[return_maps]))
    end),authenticates(C).
oversized(C) ->
    wire(C,fun(S) ->
        ok = gen_tcp:send(S,binary:copy(<<"a">>,65537)),
        ?assertMatch({error,_},gen_tcp:recv(S,0,1000))
    end),authenticates(C).
silent(C) ->
    wire(C,fun(S) -> ?assertEqual({error,closed},gen_tcp:recv(S,0,1000)) end).
redacted_status(C) ->
    R = reply(C,request(C,<<"status">>)),
    Result = maps:get(<<"result">>,R),
    ?assertEqual([<<"damage_started">>,<<"damage_supervised">>,<<"ecai_started">>],
                 lists:sort(maps:keys(Result))),
    ?assert(lists:all(fun is_boolean/1,maps:values(Result))).
duplicate_grants(C) ->
    G = maps:get(grant,C),ok = write_grants(maps:get(grants,C),[G,G]),
    ?assertEqual(error_reply(<<"authorization_unavailable">>),reply(C,request(C,<<"ping">>))).
