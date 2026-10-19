-module(ecai_conversation_personalities_tests).
-include_lib("eunit/include/eunit.hrl").

conversation_personalities_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun(C) -> ?_test(default_and_legacy_history(C)) end,
      fun(C) -> ?_test(owned_choice_survives_restart(C)) end,
      fun(C) -> ?_test(rejected_selection_does_not_mutate(C)) end,
      fun(C) -> ?_test(http_choices_are_private_and_principal_scoped(C)) end,
      fun(C) -> ?_test(http_create_and_patch_selection(C)) end,
      fun(C) -> ?_test(http_send_forwards_validated_reference(C)) end,
      fun(C) -> ?_test(revoked_or_unavailable_send_does_not_append(C)) end,
      fun(C) -> ?_test(default_send_is_explicit(C)) end,
      fun(C) -> ?_test(unknown_personality_never_falls_back(C)) end]}.

route_order_and_methods_test() ->
    Trails = ecai_conversation_http:trails(),
    Paths = [maps:get(path, T) || T <- Trails],
    ?assert(position("/ecai/conversations/personalities", Paths) <
            position("/ecai/conversations/:id", Paths)),
    {Methods, _, _} = ecai_conversation_http:allowed_methods(#{},
                        #{action => conversation_personalities}),
    ?assertEqual([<<"GET">>, <<"OPTIONS">>], Methods).

setup() ->
    ?assertEqual(undefined, whereis(ecai_conversation_store)),
    Root = filename:join("/tmp", "ecai-conversation-personas-" ++
                        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    Previous = application:get_env(ecai, conversation_history_dir),
    application:set_env(ecai, conversation_history_dir, Root),
    ecai_personalities:fixture(fixture()),
    ecai_chat:reset(),
    {ok, Pid} = ecai_conversation_store:start_link(), unlink(Pid),
    #{root => Root, previous => Previous}.
cleanup(#{root := Root, previous := Previous}) ->
    case whereis(ecai_conversation_store) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid)
    end,
    case Previous of
        undefined -> application:unset_env(ecai, conversation_history_dir);
        {ok, Value} -> application:set_env(ecai, conversation_history_dir, Value)
    end,
    ecai_personalities:reset(), ecai_chat:reset(),
    file:del_dir_r(Root), ok.

fixture() -> #{owned => #{<<"alice">> => [ref_a()], <<"bob">> => [ref_b()]}}.
ref_a() -> <<"purchase:", (binary:copy(<<"a">>, 64))/binary>>.
ref_b() -> <<"purchase:", (binary:copy(<<"b">>, 64))/binary>>.
create(Ref) ->
    {ok, C} = ecai_conversation_store:create_conversation(<<"alice">>, undefined,
                                                       <<"Persona test">>, Ref), C.
state(Action) -> #{action => Action, canonical_owner => <<"alice">>}.

conversation(Id) ->
    {ok, #{conversation := C}} = ecai_conversation_store:get_conversation(<<"alice">>, Id), C.
count(Id) -> maps:get(message_count, conversation(Id)).
raw(Id) ->
    [{{<<"alice">>, Id}, C}] = dets:lookup(ecai_conversation_history_dets, {<<"alice">>, Id}), C.
context(Id) ->
    {ok, Ctx} = ecai_conversation_store:context(<<"alice">>, Id, <<"query">>, 12), Ctx.

http_post(Action, Data, Id) ->
    Req = #{body => jsx:encode(Data), bindings => #{id => Id}},
    response(ecai_conversation_http:from_json(Req, state(Action))).
response({stop, #{response := #{status := Code, body := Body}}, _}) ->
    {Code, jsx:decode(Body, [return_maps])}.

assert_no_prompt(Term) ->
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), <<"PRIVATE FIXTURE PROMPT">>)),
    ?assertEqual(nomatch, binary:match(term_to_binary(Term), <<"system_prompt">>)).

default_and_legacy_history(_) ->
    {ok, C} = ecai_conversation_store:create_conversation(<<"alice">>, undefined, <<>>),
    Id = maps:get(id, C),
    ?assertEqual(<<"default">>, maps:get(personality_ref, C)),
    ?assertEqual(<<"default">>, maps:get(personality_ref, raw(Id))),
    Legacy = maps:remove(personality_ref, raw(Id)),
    ok = dets:insert(ecai_conversation_history_dets, {{<<"alice">>, Id}, Legacy}),
    ?assertEqual(<<"default">>, maps:get(personality_ref, conversation(Id))),
    ?assertEqual(<<"default">>, maps:get(personality_ref, context(Id))),
    {ok, [Listed]} = ecai_conversation_store:list_conversations(<<"alice">>, undefined, 50),
    ?assertEqual(<<"default">>, maps:get(personality_ref, Listed)),
    {ok, Updated} = ecai_conversation_store:update_conversation(<<"alice">>, Id, #{pinned => true}),
    ?assertEqual(<<"default">>, maps:get(personality_ref, Updated)),
    ?assertEqual(<<"default">>, maps:get(personality_ref, raw(Id))).

owned_choice_survives_restart(_) ->
    C = create(ref_a()), Id = maps:get(id, C),
    ?assertEqual(ref_a(), maps:get(personality_ref, context(Id))),
    assert_no_prompt(raw(Id)),
    gen_server:stop(whereis(ecai_conversation_store)),
    {ok, Pid} = ecai_conversation_store:start_link(), unlink(Pid),
    ?assertEqual(ref_a(), maps:get(personality_ref, conversation(Id))),
    ?assertEqual(ref_a(), maps:get(personality_ref, context(Id))),
    {ok, Default} = ecai_conversation_store:update_conversation(
        <<"alice">>, Id, #{personality_ref => <<"default">>}),
    ?assertEqual(<<"default">>, maps:get(personality_ref, Default)),
    assert_no_prompt(raw(Id)).

rejected_selection_does_not_mutate(_) ->
    ?assertEqual({error, personality_not_owned},
        ecai_conversation_store:create_conversation(<<"alice">>, undefined, <<>>, ref_b())),
    ?assertEqual({ok, []}, ecai_conversation_store:list_conversations(<<"alice">>, undefined, 50)),
    C = create(ref_a()), Id = maps:get(id, C), Before = raw(Id),
    ?assertEqual({error, personality_not_owned},
        ecai_conversation_store:update_conversation(<<"alice">>, Id,
            #{title => <<"Must not change">>, personality_ref => ref_b()})),
    ?assertEqual(Before, raw(Id)),
    ?assertEqual({error, not_found},
        ecai_conversation_store:update_conversation(<<"bob">>, Id, #{personality_ref => ref_b()})),
    lists:foreach(fun(Bad) ->
        ?assertEqual({error, invalid_personality},
            ecai_conversation_store:update_conversation(<<"alice">>, Id, #{personality_ref => Bad})),
        ?assertEqual(Before, raw(Id))
    end, [null, undefined, <<>>, <<"unknown">>, binary:copy(<<"x">>, 257)]).

http_choices_are_private_and_principal_scoped(_) ->
    %% The canonical identity wins over the backward-compatible ae_account field.
    State = (state(conversation_personalities))#{ae_account => <<"bob">>},
    {200, Body} = response(ecai_conversation_http:to_json(#{}, State)),
    Items = maps:get(<<"items">>, Body),
    ?assertEqual([<<"default">>, ref_a()], [maps:get(<<"ref">>, I) || I <- Items]),
    assert_no_prompt(Body),
    ?assertMatch({401, #{<<"error">> := <<"unauthenticated">>}},
                 response(ecai_conversation_http:to_json(#{}, #{action => conversation_personalities}))).

http_create_and_patch_selection(_) ->
    {201, #{<<"conversation">> := C}} = http_post(conversations,
        #{<<"title">> => <<"Selected">>, <<"personality_ref">> => ref_a()}, undefined),
    Id = maps:get(<<"id">>, C),
    ?assertEqual(ref_a(), maps:get(<<"personality_ref">>, C)),
    {403, _} = http_post(conversation, #{<<"personality_ref">> => ref_b()}, Id),
    ?assertEqual(ref_a(), maps:get(personality_ref, conversation(Id))),
    {200, #{<<"conversation">> := C2}} = http_post(conversation,
        #{<<"personality_ref">> => <<"default">>}, Id),
    ?assertEqual(<<"default">>, maps:get(<<"personality_ref">>, C2)),
    {400, _} = http_post(conversations, #{<<"owner">> => <<"bob">>,
                                         <<"personality_ref">> => ref_b()}, undefined),
    {400, _} = http_post(conversations, #{<<"personality_ref">> => null}, undefined),
    {400, _} = http_post(conversation, #{<<"system_prompt">> => <<"inject">>}, Id),
    assert_no_prompt(raw(Id)).

http_send_forwards_validated_reference(_) ->
    Id = maps:get(id, create(ref_a())),
    {200, Body} = http_post(conversation_message, #{<<"message">> => <<"Hello">>}, Id),
    {Id, <<"alice">>, <<"Hello">>, Options} = ecai_chat:last(),
    ?assertEqual(ref_a(), maps:get(personality_ref, Options)),
    ?assertEqual(false, maps:get(self_store, Options)),
    assert_no_prompt(Options),
    ?assertEqual(2, count(Id)),
    Assistant = maps:get(<<"assistant_message">>, Body),
    ?assertEqual(ref_a(), maps:get(<<"personality_ref">>, maps:get(<<"meta">>, Assistant))),
    assert_no_prompt(Body).

revoked_or_unavailable_send_does_not_append(_) ->
    Id = maps:get(id, create(ref_a())),
    ecai_personalities:fixture(#{owned => #{}}),
    {403, #{<<"error">> := <<"personality_not_owned">>}} =
        http_post(conversation_message, #{<<"message">> => <<"Revoked">>}, Id),
    ?assertEqual(0, count(Id)), ?assertEqual(undefined, ecai_chat:last()),
    ecai_personalities:fixture((fixture())#{unavailable => [ref_a()]}),
    {ok, Renamed} = ecai_conversation_store:update_conversation(
        <<"alice">>, Id, #{title => <<"Still administrable">>, pinned => true}),
    ?assertEqual(ref_a(), maps:get(personality_ref, Renamed)),
    ?assertEqual(<<"Still administrable">>, maps:get(title, Renamed)),
    ?assertEqual({error, personality_unavailable},
        ecai_conversation_store:update_conversation(<<"alice">>, Id, #{personality_ref => ref_a()})),
    ?assertEqual({error, personality_unavailable},
        ecai_conversation_store:create_conversation(<<"alice">>, undefined, <<>>, ref_a())),
    {503, #{<<"error">> := <<"personality_unavailable">>}} =
        http_post(conversation_message, #{<<"message">> => <<"Unavailable">>}, Id),
    ?assertEqual(0, count(Id)), ?assertEqual(undefined, ecai_chat:last()).

default_send_is_explicit(_) ->
    Id = maps:get(id, create(<<"default">>)),
    {200, _} = http_post(conversation_message, #{<<"message">> => <<"Hello default">>}, Id),
    {Id, <<"alice">>, _, Options} = ecai_chat:last(),
    ?assertEqual(<<"default">>, maps:get(personality_ref, Options)),
    ?assertEqual(2, count(Id)).

unknown_personality_never_falls_back(_) ->
    Id = maps:get(id, create(<<"default">>)),
    Broken = (raw(Id))#{personality_ref => <<"not-a-personality">>},
    dets:insert(ecai_conversation_history_dets, {{<<"alice">>, Id}, Broken}),
    {400, #{<<"error">> := <<"invalid_personality">>}} =
        http_post(conversation_message, #{<<"message">> => <<"No fallback">>}, Id),
    ?assertEqual(0, count(Id)), ?assertEqual(undefined, ecai_chat:last()).

position(Needle, List) -> position(Needle, List, 1).
position(Needle, [Needle | _], N) -> N;
position(Needle, [_ | Tail], N) -> position(Needle, Tail, N + 1).
