-module(ecai_llm_settings_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

connection() ->
    #{<<"id">> => <<"unit-local">>, <<"provider">> => <<"ollama">>, <<"enabled">> => false,
      <<"host">> => <<"127.0.0.1">>, <<"port">> => 11434, <<"transport">> => <<"tcp">>,
      <<"default_model">> => <<"fixture-model">>, <<"models">> => <<"all">>,
      <<"roles">> => [<<"patch">>], <<"weight">> => 1, <<"max_inflight">> => 1,
      <<"timeout_ms">> => 30000, <<"connect_timeout_ms">> => 1000,
      <<"max_output_tokens">> => 4096, <<"temperature">> => null,
      <<"auth_type">> => <<"none">>, <<"credential_ref">> => <<>>}.
config(C) -> #{<<"connections">> => [C], <<"remote_roles">> => [], <<"route_chat">> => false,
    <<"runtime">> => #{<<"health_interval_ms">> => 30000, <<"health_timeout_ms">> => 5000,
        <<"failure_threshold">> => 2, <<"queue_timeout_ms">> => 300000,
        <<"cluster_attempts">> => 3}}.
validate(C) -> ecai_llm_settings:validate(config(C), []).

valid_local_test() ->
    ?assertMatch({ok, [#{provider := ollama, enabled := false}]}, validate(connection())).
empty_registry_is_valid_test() ->
    ?assertEqual({ok, []}, ecai_llm_settings:validate((config(connection()))#{<<"connections">> => []}, [])).
unknown_fields_test() ->
    ?assertEqual({error, unexpected_connection_fields}, validate((connection())#{<<"tls_opts">> => []})).
endpoint_ssrf_test() ->
    ?assertEqual({error, endpoint_not_allowed}, validate((connection())#{<<"host">> => <<"169.254.169.254">>})),
    ?assertEqual({error, endpoint_not_allowed}, validate((connection())#{<<"port">> => 22})).
undeclared_environment_test() ->
    ?assertEqual({error, environment_reference_not_allowed}, validate((connection())#{
        <<"auth_type">> => <<"environment">>, <<"credential_ref">> => <<"AWS_SECRET_ACCESS_KEY">>})).
duplicate_id_test() ->
    C = connection(),
    ?assertEqual({error, duplicate_connection_id}, ecai_llm_settings:validate(
        (config(C))#{<<"connections">> => [C,C]}, [])).
unknown_role_test() ->
    ?assertMatch({error, _}, validate((connection())#{<<"roles">> => [<<"execute_shell">>]})).
claude_remote_consent_test() ->
    C = (connection())#{<<"provider">> => <<"anthropic">>, <<"host">> => <<"api.anthropic.com">>,
        <<"port">> => 443, <<"transport">> => <<"tls">>, <<"enabled">> => true,
        <<"auth_type">> => <<"environment">>, <<"credential_ref">> => <<"ANTHROPIC_API_KEY">>},
    ?assertEqual({error, remote_role_not_allowed}, validate(C)),
    ?assertMatch({ok, [#{provider := anthropic}]}, ecai_llm_settings:validate(
        (config(C))#{<<"remote_roles">> => [<<"patch">>]}, [])),
    ?assertEqual({error, endpoint_not_allowed}, validate(C#{<<"transport">> => <<"tcp">>})).
new_disabled_model_discovery_test() ->
    ?assertMatch({ok, [_]}, validate((connection())#{<<"default_model">> => <<>>})),
    ?assertMatch({error, _}, validate((connection())#{<<"default_model">> => <<>>, <<"enabled">> => true})).
inherited_key_cannot_change_destination_test() ->
    Base = [#{id => <<"unit-local">>, provider => ollama, host => "127.0.0.1", port => 11434}],
    C = (connection())#{<<"auth_type">> => <<"inherited">>, <<"host">> => <<"localhost">>},
    ?assertEqual({error, inherited_credential_endpoint_changed}, ecai_llm_settings:validate(config(C), Base)).
header_injection_key_test() ->
    ?assertMatch({error, _}, validate((connection())#{<<"api_key">> => <<"long-key\r\nx-evil: yes">>})).
credential_reference_scope_test() ->
    ?assertEqual({error, invalid_credential_reference}, validate((connection())#{
        <<"auth_type">> => <<"vault">>, <<"credential_ref">> => <<"node-wallet-key">>})).

settings_roundtrip_test_() -> {timeout, 30, fun settings_roundtrip/0}.
settings_roundtrip() ->
    {ok, _} = application:ensure_all_started(crypto),
    Keys = [code_model_nodes, code_model_health_interval_ms, code_model_health_timeout_ms,
            code_model_failure_threshold, code_model_queue_timeout_ms, code_model_cluster_attempts],
    Before = [{K, application:get_env(ecai, K)} || K <- Keys],
    TermKey = {ecai_llm_settings, active}, PreviousTerm = persistent_term:get(TermKey, absent),
    Root = filename:join(os:getenv("TMPDIR", "/tmp"), "ecai-llm-settings-" ++
           integer_to_list(erlang:unique_integer([positive, monotonic]))),
    File = filename:join([Root, "registry", "settings.json"]),
    try
        %% Disabled fixture: startup/reconfigure probes perform no networking.
        application:set_env(ecai, code_model_nodes, [#{id => <<"unit-local">>, provider => ollama,
            enabled => false, host => "127.0.0.1", port => 11434, default_model => <<"fixture-model">>}]),
        {ok, _} = ecai_llm_settings:start_link(#{file => File}),
        {ok, _} = ecai_ollama_pool:start_link(#{state_root => Root}),
        #{revision := 0, config := C0} = ecai_llm_settings:status(),
        Bad = #{<<"revision">> => 0, <<"config">> => C0#{<<"unknown">> => true}},
        ?assertMatch({error, _}, ecai_llm_settings:update(Bad, <<"unit-operator">>)),
        ?assertEqual(0, ecai_llm_settings:revision()),
        C1 = C0#{<<"route_chat">> => true},
        B1 = #{<<"revision">> => 0, <<"config">> => C1},
        ?assertMatch({ok, #{revision := 1}}, ecai_llm_settings:update(B1, <<"unit-operator">>)),
        ?assertEqual({error, stale_revision}, ecai_llm_settings:update(B1, <<"unit-operator">>)),
        ?assert(ecai_llm_settings:route_chat()),
        ?assertEqual(#{timeout => 5000}, ecai_llm_settings:code_options(#{
            provider => ollama, model => <<"legacy">>, timeout => 5000})),
        #{pool := #{revision := 1}} = ecai_llm_settings:status(),
        {ok, FI} = file:read_file_info(File), ?assertEqual(8#600, FI#file_info.mode band 8#777),
        {ok, Bytes} = file:read_file(File),
        ?assertEqual(nomatch, binary:match(Bytes, <<"api_key">>)),
        ok = gen_server:stop(ecai_llm_settings),
        {ok, _} = ecai_llm_settings:start_link(#{file => File}),
        ?assertEqual(1, ecai_llm_settings:revision()),
        Empty = C1#{<<"connections">> => []},
        ?assertMatch({ok, #{revision := 2}}, ecai_llm_settings:update(
            #{<<"revision">> => 1, <<"config">> => Empty}, <<"unit-operator">>)),
        ?assertEqual({ok, []}, ecai_llm_settings:nodes()),
        ?assertEqual([], maps:get(nodes, ecai_ollama_pool:status())),
        ?assertEqual({ok, #{}}, ecai_ollama_pool:evaluation_configurations()),
        Route = #{<<"provider">> => <<"ollama">>, <<"model">> => <<"explicit-model">>},
        ?assertEqual({ok,3},ecai_llm_settings:update_bdd(
            #{<<"revision">> => 2,<<"route">> => Route},<<"unit-operator">>)),
        ?assertEqual(#{provider => ollama,model => <<"explicit-model">>,routing_revision => 3},
            ecai_llm_settings:bdd_options()),
        ?assertMatch(#{connections := [],remote_allowed := false},ecai_llm_settings:bdd_status()),
        ?assertEqual({error,stale_revision},ecai_llm_settings:update_bdd(
            #{<<"revision">> => 2,<<"route">> => Route},<<"unit-operator">>)),
        %% An older provider editor must not reset a saved authoring preference.
        ?assertMatch({ok,#{revision := 4}},ecai_llm_settings:update(
            #{<<"revision">> => 3,<<"config">> => maps:remove(<<"bdd_route">>,Empty)},<<"unit-operator">>)),
        ?assertMatch(#{route := Route},ecai_llm_settings:bdd_status()),
        ok = gen_server:stop(ecai_llm_settings),
        {ok,_} = ecai_llm_settings:start_link(#{file => File}),
        ?assertMatch(#{route := Route,revision := 4},ecai_llm_settings:bdd_status())
    after
        stop(ecai_ollama_pool), stop(ecai_llm_settings),
        [restore(K, V) || {K,V} <- Before],
        case PreviousTerm of absent -> persistent_term:erase(TermKey); _ -> persistent_term:put(TermKey, PreviousTerm) end,
        file:del_dir_r(Root)
    end.
stop(Name) -> case whereis(Name) of undefined -> ok; _ -> gen_server:stop(Name) end.
restore(K, undefined) -> application:unset_env(ecai, K);
restore(K, {ok, V}) -> application:set_env(ecai, K, V).


bdd_route_validation_test_() ->
    C = config(connection()),
    Route = #{<<"provider">> => <<"ollama">>, <<"model">> => <<>>},
    [?_assertMatch({ok,_},ecai_llm_settings:validate(C#{<<"bdd_route">> => Route},[])),
     ?_assertMatch({ok,_},ecai_llm_settings:validate(C#{<<"bdd_route">> => Route#{<<"provider">> => <<"any">>}},[])),
     ?_assertMatch({error,_},ecai_llm_settings:validate(C#{<<"bdd_route">> => Route#{<<"host">> => <<"attacker.invalid">>}},[])),
     ?_assertMatch({error,_},ecai_llm_settings:validate(C#{<<"bdd_route">> => Route#{<<"provider">> => <<"arbitrary">>}},[])),
     ?_assertMatch({error,_},ecai_llm_settings:validate(C#{<<"bdd_route">> => Route#{<<"model">> => binary:copy(<<"x">>,257)}},[]))].

probe_uses_saved_timeouts_and_revision_fence_test() ->
    C0 = connection(), C = C0#{<<"connect_timeout_ms">> => 18000},
    Config0 = config(C),
    Config = Config0#{<<"runtime">> => (maps:get(<<"runtime">>, Config0))#{<<"health_timeout_ms">> => 20000}},
    S0 = #{base => [], probes => #{}, snapshot => #{revision => 7, config => Config}},
    {reply, {ok, Opts, Target}, S1} = ecai_llm_settings:handle_call(
        {probe_options, #{<<"revision">> => 7, <<"id">> => <<"unit-local">>}}, {self(), make_ref()}, S0),
    ?assertEqual(20000, maps:get(health_timeout, Opts)),
    ?assertEqual(18000, maps:get(connect_timeout, Opts)),
    ?assertEqual(<<"fixture-model">>, maps:get(default_model, Target)),
    ?assertMatch({reply, true, _}, ecai_llm_settings:handle_call({probe_current, 7}, {self(), make_ref()}, S1)),
    ?assertMatch({reply, false, _}, ecai_llm_settings:handle_call({probe_current, 6}, {self(), make_ref()}, S1)).

inherited_proxy_and_response_cap_are_preserved_test() ->
    Base = [#{id => <<"unit-local">>, provider => ollama, host => "127.0.0.1", port => 11434,
              proxy => auto, max_response_bytes => 4096}],
    {ok, [N]} = ecai_llm_settings:validate(config(connection()), Base),
    ?assertEqual(auto, maps:get(proxy, N)),
    ?assertEqual(4096, maps:get(max_response_bytes, N)).

deployment_nodes_are_visible_without_implicit_merge_test() ->
    Base = [#{id => <<"declared-lan">>, host => "192.0.2.20", port => 11434,
              enabled => false, api_key_secret => <<"DO-NOT-EXPOSE-REFERENCE">>}],
    Config = (config(connection()))#{<<"connections">> => []},
    S = #{base => Base, snapshot => #{revision => 2, source => dashboard, config => Config}},
    {reply, Public, S} = ecai_llm_settings:handle_call(status, {self(), make_ref()}, S),
    ?assertEqual([], maps:get(<<"connections">>, maps:get(config, Public))),
    [Declared] = maps:get(deployment_connections, Public),
    ?assertEqual(<<"declared-lan">>, maps:get(<<"id">>, Declared)),
    ?assertEqual(<<"inherited">>, maps:get(<<"auth_type">>, Declared)),
    ?assertEqual(<<>>, maps:get(<<"credential_ref">>, Declared)).
