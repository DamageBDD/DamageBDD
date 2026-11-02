-module(ecai_model_internals_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

safe_defaults_test() ->
    C = ecai_model_internals:defaults(),
    ?assertEqual(ok, ecai_model_internals:validate(C)),
    ?assertEqual(false, maps:get(<<"enabled">>, C)),
    ?assertEqual([<<"patch">>], maps:get(<<"roles">>, C)),
    ?assert(lists:all(fun(V) -> V =:= null end, maps:values(maps:get(<<"ollama">>, C)))).

unknown_fields_and_code_rejected_test() ->
    C = ecai_model_internals:defaults(),
    lists:foreach(fun(K) ->
        ?assertMatch({error, _}, ecai_model_internals:validate(C#{K => <<"untrusted">>}))
    end, [<<"host">>, <<"auth">>, <<"api_key">>, <<"adapter_path">>, <<"processor">>, <<"activation_hook">>]),
    O = maps:get(<<"ollama">>, C),
    ?assertMatch({error, _}, ecai_model_internals:validate(C#{<<"ollama">> => O#{<<"provider">> => <<"evil">>}})),
    ?assertMatch({error, _}, ecai_model_internals:validate(C#{<<"enabled">> => <<"true">>})).

ranges_and_roles_test() ->
    C = ecai_model_internals:defaults(), O = maps:get(<<"ollama">>, C),
    lists:foreach(fun({K, V}) ->
        ?assertMatch({error, _}, ecai_model_internals:validate(C#{<<"ollama">> => O#{K => V}}))
    end, [{<<"temperature">>, 3}, {<<"seed">>, -1}, {<<"seed">>, 2.5}, {<<"top_p">>, 0},
          {<<"min_p">>, 2}, {<<"top_k">>, false}, {<<"num_ctx">>, 1000000}, {<<"max_output_tokens">>, 0}]),
    lists:foreach(fun(Roles) ->
        ?assertMatch({error, _}, ecai_model_internals:validate(C#{<<"roles">> => Roles}))
    end, [[], [<<"chat">>], [<<"patch">>, <<"patch">>], <<"patch">>]),
    ?assertMatch({error, _}, ecai_model_internals:validate(C#{<<"system_suffix">> => binary:copy(<<"a">>, 2049)})),
    ?assertMatch({error, _}, ecai_model_internals:validate(C#{<<"system_suffix">> => <<255>>})).

preview_and_provider_isolation_test() ->
    C = enabled(),
    {ok, O} = ecai_model_internals:preview(#{<<"config">> => C, <<"provider">> => <<"ollama">>, <<"role">> => <<"patch">>}),
    OP = maps:get(options, O),
    ?assertEqual(true, maps:get(active, O)),
    ?assertEqual(42, maps:get(seed, OP)),
    ?assertEqual(ecai_model_internals:repair_schema(), maps:get(format, OP)),
    {ok, P} = ecai_model_internals:preview(#{<<"config">> => C, <<"provider">> => <<"openai">>, <<"role">> => <<"patch">>}),
    PP = maps:get(options, P),
    ?assertEqual(2048, maps:get(max_output_tokens, PP)),
    ?assertNot(maps:is_key(seed, PP)),
    ?assertNot(maps:is_key(format, PP)),
    ?assertNot(maps:is_key(temperature, PP)),
    {ok, NotSelected} = ecai_model_internals:preview(#{<<"config">> => C, <<"provider">> => <<"ollama">>, <<"role">> => <<"audit">>}),
    ?assertEqual(false, maps:get(active, NotSelected)),
    ?assertMatch({error, _}, ecai_model_internals:preview(#{<<"config">> => C, <<"provider">> => <<"http://evil">>, <<"role">> => <<"patch">>})).

pin_and_scope_test() ->
    with_server(fun(_File) ->
        {ok, _} = ecai_model_internals:update(#{<<"revision">> => 0, <<"config">> => enabled()}, <<"admin">>),
        Original = #{provider => ollama, model => <<"pinned-model">>, host => <<"trusted-host">>,
                     auth => #{type => bearer, token => <<"secret">>}, system => <<"Existing system">>},
        Pinned = ecai_model_internals:prepare(json, patch, Original),
        {ok, _} = ecai_model_internals:update(#{<<"revision">> => 1, <<"config">> => ecai_model_internals:defaults()}, <<"admin">>),
        Applied = ecai_model_internals:apply_policy(Pinned),
        ?assertEqual(42, maps:get(seed, Applied)),
        ?assertEqual(1, maps:get(revision, maps:get(model_internals, Applied))),
        ?assertEqual(maps:get(auth, Original), maps:get(auth, Applied)),
        ?assertEqual(maps:get(host, Original), maps:get(host, Applied)),
        ?assertEqual(maps:get(model, Original), maps:get(model, Applied)),
        ?assertMatch(<<"Existing system", _/binary>>, maps:get(system, Applied)),
        ?assertEqual(Original, ecai_model_internals:prepare(json, patch, Original)),
        ?assertEqual(Original, ecai_model_internals:prepare(native_chat, patch, Original)),
        ?assertEqual(Original, ecai_model_internals:prepare(json, chat, Original)),
        %% Caller-supplied snapshots cannot activate a disabled node policy.
        ?assertEqual(Original, ecai_model_internals:prepare(json, patch, Original#{model_internals_snapshot => #{bad => true}}))
    end).

restart_conflict_and_permissions_test() ->
    with_server(fun(File) ->
        C = enabled(),
        {ok, Saved} = ecai_model_internals:update(#{<<"revision">> => 0, <<"config">> => C}, <<"admin-a">>),
        ?assertEqual(1, maps:get(revision, Saved)),
        ?assertMatch({error, stale_revision}, ecai_model_internals:update(#{<<"revision">> => 0, <<"config">> => C}, <<"admin-b">>)),
        ?assertMatch({error, invalid_update}, ecai_model_internals:update(#{<<"revision">> => 1, <<"config">> => C, <<"actor">> => <<"forged">>}, <<"admin-a">>)),
        {ok, Info} = file:read_file_info(File),
        ?assertEqual(8#600, Info#file_info.mode band 8#777),
        ok = gen_server:stop(ecai_model_internals),
        {ok, _} = ecai_model_internals:start_link(#{file => File}),
        Current = ecai_model_internals:status(),
        ?assertEqual(C, maps:get(config, Current)),
        ?assertEqual(maps:get(config_sha256, Saved), maps:get(config_sha256, Current)),
        ?assertEqual(1, maps:get(revision, Current))
    end).

concurrent_updates_test() ->
    with_server(fun(_File) ->
        Parent = self(), B = #{<<"revision">> => 0, <<"config">> => enabled()},
        [spawn(fun() -> Parent ! {saved, ecai_model_internals:update(B, Actor)} end) || Actor <- [<<"a">>, <<"b">>]],
        R1 = receive {saved, R} -> R after 5000 -> timeout end,
        R2 = receive {saved, T} -> T after 5000 -> timeout end,
        ?assertEqual(1, length([ok || {ok, _} <- [R1, R2]])),
        ?assertEqual(1, length([ok || {error, stale_revision} <- [R1, R2]]))
    end).

bounded_sanitized_observations_test() ->
    with_server(fun(_File) ->
        [ecai_model_internals:observe(#{role => patch, model => <<"test">>, prompt => <<"private">>,
             auth => <<"credential">>, model_internals => #{revision => 1, prompt => <<"private">>}}) || _ <- lists:seq(1, 40)],
        S = ecai_model_internals:status(), Observed = maps:get(observations, S),
        ?assertEqual(32, length(Observed)),
        ?assert(lists:all(fun(E) -> not maps:is_key(prompt, E) andalso not maps:is_key(auth, E)
            andalso not maps:is_key(prompt, maps:get(model_internals, E)) end, Observed)),
        ?assertEqual(false, maps:get(observations_durable, S))
    end).

native_options_and_metadata_test() ->
    %% TEST-only accessors exercise the actual serializers/receipt identity.
    O = ecai_ollama_client:ollama_generation_options(#{temperature => 0, seed => 42, top_k => 20,
        top_p => 0.9, min_p => 0.1, num_ctx => 4096, repeat_penalty => 1.1, max_output_tokens => 500, auth => <<"secret">>}),
    ?assertEqual(42, maps:get(<<"seed">>, O)),
    ?assertEqual(500, maps:get(<<"num_predict">>, O)),
    ?assertNot(maps:is_key(<<"auth">>, O)),
    Effective = ecai_ollama_pool:output_options(#{system => <<"instructions">>, seed => 7,
        format => ecai_model_internals:repair_schema(), auth => <<"secret">>, model_internals => #{revision => 2}}),
    ?assert(maps:is_key(system, Effective)), ?assert(maps:is_key(seed, Effective)),
    ?assert(maps:is_key(format, Effective)), ?assertNot(maps:is_key(auth, Effective)),
    P = #{revision => 1, config_sha256 => <<"hash">>, applied => [seed]},
    Attempt = ecai_patch_worker:record_inference_attempt(1, #{model_internals => P, auth => <<"secret">>}, #{}),
    ?assertEqual(P, maps:get(model_internals, maps:get(inference_meta, Attempt))),
    ?assertNot(maps:is_key(auth, maps:get(inference_meta, Attempt))).

effective_receipt_identity_test() ->
    Lease = #{provider => ollama, host => "localhost", port => 11434, model => <<"test">>,
              client_opts => #{temperature => 0}},
    Id = ecai_ollama_pool:inference_request_id(json, patch, <<"prompt">>, Lease, #{}),
    Id2 = ecai_ollama_pool:inference_request_id(json, patch, <<"prompt">>, Lease#{client_opts => #{temperature => 0.5}}, #{}),
    Id3 = ecai_ollama_pool:inference_request_id(json, patch, <<"prompt">>, Lease, #{system => <<"new policy">>}),
    ?assertNotEqual(Id, Id2), ?assertNotEqual(Id, Id3).

enabled() ->
    C = ecai_model_internals:defaults(), O = maps:get(<<"ollama">>, C), P = maps:get(<<"openai">>, C),
    C#{<<"enabled">> => true, <<"patch_json_schema">> => true,
       <<"system_suffix">> => <<"Cite the indexed source revision.">>,
       <<"ollama">> => O#{<<"temperature">> => 0, <<"seed">> => 42},
       <<"openai">> => P#{<<"max_output_tokens">> => 2048}}.

with_server(Fun) ->
    Saved = persistent_term:get({ecai_model_internals, snapshot}, undefined),
    Root = filename:join("/tmp", "ecai-internals-" ++ integer_to_list(erlang:unique_integer([positive]))),
    File = filename:join(Root, "policy.term"),
    {ok, _} = ecai_model_internals:start_link(#{file => File}),
    try Fun(File)
    after
        case whereis(ecai_model_internals) of undefined -> ok; Pid -> gen_server:stop(Pid) end,
        case Saved of undefined -> persistent_term:erase({ecai_model_internals, snapshot});
                      _ -> persistent_term:put({ecai_model_internals, snapshot}, Saved) end,
        file:del_dir_r(Root)
    end.
