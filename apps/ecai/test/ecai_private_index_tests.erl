-module(ecai_private_index_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

private_index_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun roundtrip/1, fun ciphertext_only/1, fun access_denied/1,
      fun reader_writer_separation/1, fun duplicate_batch/1,
      fun append_and_ranking/1, fun tamper_rejected/1,
      fun renamed_segment_rejected/1, fun cross_corpus_rejected/1,
      fun wrong_key_rejected/1, fun missing_key_rejected/1,
      fun public_paths_blocked/1, fun missing_marker_not_downgraded/1,
      fun nonempty_public_directory_rejected/1,
      fun unknown_fields_rejected/1, fun invalid_utf8_rejected/1,
      fun binary_fields_and_unicode/1, fun query_and_batch_limits/1,
      fun public_queue_rejects_privacy_flags/1,
      fun http_rejects_identity_and_endpoint_overrides/1,
      fun local_llm_bridge/1, fun no_evidence_no_llm/1,
      fun llm_denied_before_key_access/1, fun remote_requires_opt_in/1,
      fun llm_errors_are_redacted/1, fun decoding_and_exception_redaction/1]}.

setup() ->
    {ok, _} = application:ensure_all_started(crypto),
    {module, secrets_pqc_api_tests} = code:ensure_loaded(secrets_pqc_api_tests),
    {module, jsx} = code:ensure_loaded(jsx),
    Settings = [{damage, pqc_backend_module}, {ecai, private_corpora},
                {ecai, private_key_provider_module}, {ecai, private_llm_destinations},
                {ecai, private_llm_client_module}, {ecai, private_test_pairs},
                {ecai, private_test_owner}, {ecai, private_test_llm_error}],
    Previous = [{A, K, application:get_env(A, K)} || {A, K} <- Settings],
    application:set_env(damage, pqc_backend_module, secrets_pqc_api_tests),
    application:set_env(ecai, private_key_provider_module, ecai_private_test_support),
    application:set_env(ecai, private_llm_client_module, ecai_private_test_support),
    application:set_env(ecai, private_test_llm_error, false),
    Root = filename:join(temp_root(), "ecai-private-test-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12)))),
    ok = file:make_dir(Root), ok = file:change_mode(Root, 8#700),
    A = config(filename:join(Root, "a"), <<"alice">>),
    B = config(filename:join(Root, "b"), <<"bob">>),
    application:set_env(ecai, private_corpora, #{<<"a">> => A, <<"b">> => B}),
    Pairs = #{<<"a">> => secrets_pqc:generate_keypair(),
              <<"b">> => secrets_pqc:generate_keypair()},
    application:set_env(ecai, private_test_pairs, Pairs),
    application:set_env(ecai, private_llm_destinations, #{<<"local">> =>
        #{trust => local, options => #{provider => ollama, host => "127.0.0.1",
                                       port => 11434, model => <<"fixture">>}}}),
    #{root => Root, a => A, b => B, pairs => Pairs, previous => Previous}.

cleanup(#{root := Root, previous := Previous}) ->
    lists:foreach(fun
        ({A, K, undefined}) -> application:unset_env(A, K);
        ({A, K, {ok, V}}) -> application:set_env(A, K, V)
    end, Previous),
    ok = file:del_dir_r(Root).

config(Dir, Owner) ->
    #{base_dir => Dir, owner => Owner, key_id => <<"fixture-v1">>,
      key_name => <<"unused-test-key">>, readers => [<<"reader">>],
      writers => [<<"writer">>], llm_destinations => [<<"local">>]}.
temp_root() -> case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end.
batch(N) -> iolist_to_binary(io_lib:format("~32.16.0b", [N])).
record() -> #{title => <<"Saffron Private Title">>,
              text => <<"saffron confidential payload alpha">>,
              cid => <<"PRIVATE-CID-MUST-NOT-LEAK">>}.
index() -> ecai_disk_indexer:index_private(<<"a">>, <<"alice">>, batch(1), [record()]).
search() -> ecai_private_index:search(<<"a">>, <<"alice">>, <<"saffron">>, 8).
path(F, N) -> filename:join(maps:get(base_dir, maps:get(a, F)),
                           binary_to_list(batch(N)) ++ ".ecp").

roundtrip(_) -> ?_test(begin
    ?assertMatch({ok, #{indexed := 1, private := true}}, index()),
    {ok, #{sources := [S]}} = search(),
    ?assertEqual(maps:get(text, record()), maps:get(text, S)),
    ?assertEqual(maps:get(title, record()), maps:get(title, S)),
    Ref = maps:get(id, S),
    ?assertMatch({ok, #{text := _}}, ecai_private_index:fetch(<<"a">>, <<"alice">>, Ref)),
    ?assertEqual(search(), search())
end).

ciphertext_only(F) -> ?_test(begin
    {ok, _} = index(), Dir = maps:get(base_dir, maps:get(a, F)),
    {ok, Names} = file:list_dir(Dir),
    ?assertEqual(2, length(Names)),
    #{private_key := Priv} = maps:get(<<"a">>, maps:get(pairs, F)),
    lists:foreach(fun(Name) ->
        P = filename:join(Dir, Name), {ok, B} = file:read_file(P),
        {ok, Info} = file:read_file_info(P),
        ?assertEqual(8#600, Info#file_info.mode band 8#777),
        lists:foreach(fun(Needle) -> ?assertEqual(nomatch, binary:match(B, Needle)) end,
            [maps:get(text, record()), maps:get(title, record()),
             maps:get(cid, record()), <<"text:saffron">>, Priv])
    end, Names),
    ?assertNot(filelib:is_dir(filename:join(Dir, "wal"))),
    ?assertNot(filelib:is_dir(filename:join(Dir, "docstore")))
end).

access_denied(_) -> ?_test(begin
    application:set_env(ecai, private_test_owner, self()),
    ?assertEqual({error, forbidden}, ecai_private_index:index(
        <<"a">>, <<"mallory">>, batch(1), [record()])),
    ?assertEqual({error, forbidden}, ecai_private_index:search(
        <<"a">>, <<"mallory">>, <<"saffron">>, 8)),
    ?assertEqual({error, unauthenticated}, ecai_private_index:search(
        <<"a">>, undefined, <<"saffron">>, 8)),
    receive {private_test_key_lookup, _} -> error(unauthorized_key_lookup)
    after 0 -> ok end
end).

reader_writer_separation(_) -> ?_test(begin
    ?assertMatch({ok, _}, ecai_private_index:index(
        <<"a">>, <<"writer">>, batch(1), [record()])),
    ?assertMatch({ok, #{count := 1}}, ecai_private_index:search(
        <<"a">>, <<"reader">>, <<"saffron">>, 8)),
    ?assertEqual({error, forbidden}, ecai_private_index:search(
        <<"a">>, <<"writer">>, <<"saffron">>, 8)),
    ?assertEqual({error, forbidden}, ecai_private_index:index(
        <<"a">>, <<"reader">>, batch(2), [record()]))
end).

duplicate_batch(F) -> ?_test(begin
    {ok, _} = index(), Before = file:read_file(path(F, 1)),
    ?assertEqual({error, batch_already_exists}, ecai_private_index:index(
        <<"a">>, <<"alice">>, batch(1), [#{text => <<"replacement">>}])),
    ?assertEqual(Before, file:read_file(path(F, 1))),
    ?assertMatch({ok, #{count := 1}}, search())
end).

append_and_ranking(_) -> ?_test(begin
    {ok, _} = index(),
    {ok, _} = ecai_private_index:index(<<"a">>, <<"alice">>, batch(2),
                                     [#{text => <<"saffron alpha beta">>}]),
    {ok, #{sources := [Top]}} = ecai_private_index:search(
        <<"a">>, <<"alice">>, <<"saffron beta">>, 1),
    ?assertEqual(2, maps:get(score, Top)),
    ?assertEqual(<<(batch(2))/binary, ":1">>, maps:get(id, Top))
end).

tamper_rejected(F) -> ?_test(begin
    {ok, _} = index(), P = path(F, 1),
    {ok, <<"ECP1", Encoded/binary>>} = file:read_file(P),
    E = binary_to_term(Encoded, [safe]), <<B, Rest/binary>> = maps:get(ct, E),
    Bad = term_to_binary(E#{ct := <<(B bxor 1), Rest/binary>>}),
    ok = file:write_file(P, <<"ECP1", Bad/binary>>),
    ?assertEqual({error, private_authentication_failed}, search())
end).

renamed_segment_rejected(F) -> ?_test(begin
    {ok, _} = index(), ok = file:rename(path(F, 1), path(F, 2)),
    ?assertEqual({error, private_authentication_failed}, search())
end).

cross_corpus_rejected(F) -> ?_test(begin
    {ok, _} = index(),
    %% Deliberately use the SAME keypair: rejection must come from AAD scope.
    PairA = maps:get(<<"a">>, maps:get(pairs, F)),
    application:set_env(ecai, private_test_pairs, #{<<"a">> => PairA, <<"b">> => PairA}),
    {ok, _} = ecai_private_index:index(<<"b">>, <<"bob">>, batch(2), [record()]),
    Target = filename:join(maps:get(base_dir, maps:get(b, F)),
                           binary_to_list(batch(1)) ++ ".ecp"),
    {ok, _} = file:copy(path(F, 1), Target), ok = file:change_mode(Target, 8#600),
    ?assertEqual({error, private_authentication_failed},
        ecai_private_index:search(<<"b">>, <<"bob">>, <<"saffron">>, 8))
end).

wrong_key_rejected(F) -> ?_test(begin
    {ok, _} = index(), Pairs = maps:get(pairs, F),
    PairA = maps:get(<<"a">>, Pairs), PairB = maps:get(<<"b">>, Pairs),
    Bad = PairA#{private_key := maps:get(private_key, PairB)},
    application:set_env(ecai, private_test_pairs, Pairs#{<<"a">> := Bad}),
    ?assertEqual({error, private_authentication_failed}, search())
end).

missing_key_rejected(_) -> ?_test(begin
    {ok, _} = index(), application:set_env(ecai, private_test_pairs, #{}),
    ?assertEqual({error, private_key_unavailable}, search())
end).

public_paths_blocked(F) -> ?_test(begin
    Dir = maps:get(base_dir, maps:get(a, F)),
    ?assertError(private_index_requires_authorized_api, ecai_disk_indexer:new(Dir)),
    ?assertError(private_index_requires_authorized_api, ecai_disk_docstore:open(Dir)),
    ?assertError(private_index_requires_authorized_api,
                 ecai_private_store:assert_public(filename:join(Dir, "child"))),
    ?assertNot(filelib:is_dir(Dir)), {ok, _} = index(),
    ?assertError(private_index_requires_authorized_api, ecai_wal:open(Dir)),
    ?assertError(private_index_requires_authorized_api,
                 ecai_disk_segment:write(Dir, "seg_000001.ecs", #{}))
end).

missing_marker_not_downgraded(F) -> ?_test(begin
    {ok, _} = index(), Dir = maps:get(base_dir, maps:get(a, F)),
    ok = file:delete(filename:join(Dir, ".ecai-private-v1")),
    ?assertEqual({error, private_index_not_initialized}, search()),
    application:set_env(ecai, private_corpora, #{}),
    ?assertError(private_index_requires_authorized_api, ecai_disk_indexer:new(Dir))
end).

nonempty_public_directory_rejected(F) -> ?_test(begin
    Dir = maps:get(base_dir, maps:get(a, F)),
    ok = file:make_dir(Dir), ok = file:change_mode(Dir, 8#700),
    ok = file:write_file(filename:join(Dir, "public.txt"), <<"old content">>),
    ?assertEqual({error, private_requires_empty_directory}, index())
end).

unknown_fields_rejected(F) -> ?_test(begin
    ?assertEqual({error, invalid_request}, ecai_private_index:index(
        <<"a">>, <<"alice">>, batch(1), [#{text => <<"x">>, private_key => <<"secret">>}])),
    ?assertNot(filelib:is_dir(maps:get(base_dir, maps:get(a, F))))
end).

invalid_utf8_rejected(_) -> ?_test(begin
    ?assertEqual({error, invalid_utf8}, ecai_private_index:index(
        <<"a">>, <<"alice">>, batch(1), [#{text => <<255>>}]))
end).

binary_fields_and_unicode(_) -> ?_test(begin
    Hash = crypto:hash(sha256, <<"fixture">>),
    R = #{<<"text">> => <<"saffron ", 16#03BB/utf8>>, <<"event_id">> => Hash},
    {ok, _} = ecai_private_index:index(<<"a">>, <<"alice">>, batch(1), [R]),
    {ok, #{sources := [S]}} = search(), ?assertEqual(Hash, maps:get(event_id, S)),
    ?assertEqual(<<"a">>, ecai_llm_bridge:clip_utf8(<<"a",16#03BB/utf8>>, 2))
end).

query_and_batch_limits(_) -> ?_test(begin
    ?assertEqual({error, invalid_request}, ecai_private_index:index(
        <<"a">>, <<"alice">>, <<"../../oops">>, [record()])),
    ?assertEqual({error, invalid_request}, ecai_private_index:search(
        <<"a">>, <<"alice">>, <<"saffron">>, 0)),
    ?assertEqual({error, invalid_request}, ecai_private_index:index(
        <<"a">>, <<"alice">>, batch(1), lists:duplicate(257, record())))
end).

public_queue_rejects_privacy_flags(_) -> ?_test(begin
    ?assertError(private_record_requires_private_api,
        ecai_private_policy:assert_public_record(#{private => true})),
    ?assertError(private_record_requires_private_api,
        ecai_private_policy:assert_public_record(#{privacy => public,
                                                   <<"privacy">> => <<"private">>})),
    lists:foreach(fun(Spec) ->
        ?assertEqual({error, private_jobs_require_private_api},
                      ecai_index_job_codec:normalize_spec(Spec))
    end, [#{privacy => private}, #{<<"private">> => true},
          #{target => #{<<"privacy">> => <<"private">>}},
          #{options => #{encryption => pqc}}])
end).

http_rejects_identity_and_endpoint_overrides(_) -> ?_test(begin
    ?assertEqual({error, invalid_request}, ecai_private_http:dispatch(search,
        <<"a">>, <<"reader">>, #{<<"query">> => <<"saffron">>, <<"owner">> => <<"alice">>})),
    ?assertEqual({error, invalid_request}, ecai_private_http:dispatch(ask,
        <<"a">>, <<"alice">>, #{<<"question">> => <<"saffron">>,
          <<"destination">> => <<"local">>, <<"host">> => <<"evil.example">>}))
end).

local_llm_bridge(F) -> ?_test(begin
    {ok, _} = index(), application:set_env(ecai, private_test_owner, self()),
    {ok, Answer} = ecai_llm_bridge:ask(<<"a">>, <<"alice">>, <<"saffron">>, <<"local">>),
    ?assertEqual(true, maps:get(llm_called, Answer)),
    receive {private_test_llm, Prompt, Opts} ->
        ?assertMatch(#{proxy := direct, host := "127.0.0.1", store := false}, Opts),
        ?assert(maps:is_key(system, Opts)),
        ?assertNotEqual(nomatch, binary:match(Prompt, maps:get(text, record()))),
        Pair = maps:get(<<"a">>, maps:get(pairs, F)),
        ?assertEqual(nomatch, binary:match(Prompt, maps:get(private_key, Pair))),
        ?assertEqual(nomatch, binary:match(Prompt, maps:get(cid, record())))
    after 1000 -> error(no_llm_request) end
end).

no_evidence_no_llm(_) -> ?_test(begin
    {ok, _} = index(), application:set_env(ecai, private_test_owner, self()),
    ?assertMatch({ok, #{llm_called := false, sources := []}},
        ecai_llm_bridge:ask(<<"a">>, <<"alice">>, <<"unmatchedword">>, <<"local">>)),
    receive {private_test_llm, _, _} -> error(unexpected_llm_call) after 0 -> ok end
end).

llm_denied_before_key_access(_) -> ?_test(begin
    application:set_env(ecai, private_test_owner, self()),
    ?assertEqual({error, llm_destination_forbidden},
        ecai_llm_bridge:ask(<<"a">>, <<"alice">>, <<"saffron">>, <<"unapproved">>)),
    receive {private_test_key_lookup, _} -> error(unexpected_key_lookup) after 0 -> ok end,
    Bad = #{trust => local, options => #{host => "external.example", port => 11434,
                                       model => <<"fixture">>, provider => ollama}},
    ?assertEqual({error, nonlocal_llm_destination}, ecai_private_policy:run(fun() ->
        ecai_llm_bridge:inference_options(#{}, Bad) end))
end).

remote_requires_opt_in(_) -> ?_test(begin
    Remote = #{trust => remote, options => #{host => "api.example", port => 443,
        model => <<"operator-chosen">>, provider => openai,
        proxy => auto, store => true, tls_opts => [{verify, verify_none}]}},
    ?assertEqual({error, remote_llm_forbidden}, ecai_private_policy:run(fun() ->
        ecai_llm_bridge:inference_options(#{}, Remote) end)),
    O = ecai_llm_bridge:inference_options(#{allow_remote_llm => true}, Remote),
    ?assertMatch(#{transport := tls, proxy := direct, store := false}, O),
    ?assertNot(maps:is_key(tls_opts, O))
end).

llm_errors_are_redacted(_) -> ?_test(begin
    {ok, _} = index(), application:set_env(ecai, private_test_llm_error, true),
    ?assertEqual({error, llm_request_failed},
        ecai_llm_bridge:ask(<<"a">>, <<"alice">>, <<"saffron">>, <<"local">>))
end).

decoding_and_exception_redaction(_) -> ?_test(begin
    ?assertEqual({error, private_operation_failed}, ecai_private_policy:run(fun() ->
        error({sensitive_exception, <<"MUST-NOT-ESCAPE">>}) end)),
    ?assertEqual({error, invalid_private_encoding}, ecai_private_policy:run(fun() ->
        ecai_private_crypto:decode(<<131, 80, 0, 0, 0, 1, 0>>) end)),
    Good = term_to_binary(#{text => <<"ok">>}),
    ?assertMatch({error, _}, ecai_private_policy:run(fun() ->
        ecai_private_crypto:decode(<<Good/binary, 0>>) end))
end).

%% Opt-in real liboqs smoke test, separate from the reused fake KEM tests.
%% Not run unless explicitly enabled; never reports the fake backend as PQC.
real_pqc_test_() ->
    case os:getenv("ECAI_PRIVATE_REAL_PQC_TEST") of
        "1" -> {timeout, 30, fun() ->
            {ok, _} = application:ensure_all_started(crypto),
            Previous = application:get_env(damage, pqc_backend_module),
            try
                application:set_env(damage, pqc_backend_module, secrets_pqc_oqs),
                #{public_key := Pub, private_key := Priv} = secrets_pqc:generate_keypair(),
                C = #{<<"purpose">> => <<"ecai-private-real-test">>},
                E = ecai_private_crypto:seal(#{text => <<"real ML-KEM fixture">>}, Pub, C),
                ?assertEqual(#{text => <<"real ML-KEM fixture">>},
                             ecai_private_crypto:open(E, Priv, C))
            after
                case Previous of
                    undefined -> application:unset_env(damage, pqc_backend_module);
                    {ok, M} -> application:set_env(damage, pqc_backend_module, M)
                end
            end
        end};
        _ -> []
    end.
