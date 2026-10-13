-module(ecai_conversation_store_tests).

-include_lib("eunit/include/eunit.hrl").

conversation_history_projects_test_() ->
    {setup,
        fun setup/0,
        fun cleanup/1,
        fun run_history_case/1}.

setup() ->
    case whereis(ecai_conversation_store) of
        undefined ->
            TmpDir = case os:getenv("TMPDIR") of false -> "/tmp"; Value -> Value end,
            Root = filename:join(
                TmpDir,
                "ecai-conversations-" ++ integer_to_list(erlang:unique_integer([positive]))
            ),
            ok = filelib:ensure_dir(filename:join(Root, "placeholder")),
            Previous = application:get_env(ecai, conversation_history_dir),
            ok = application:set_env(ecai, conversation_history_dir, Root),
            {ok, Pid} = ecai_conversation_store:start_link(),
            unlink(Pid),
            #{started => true, pid => Pid, root => Root, previous => Previous};
        Pid ->
            #{started => false, pid => Pid}
    end.

cleanup(#{started := true, pid := Pid, root := Root, previous := Previous}) ->
    _ = gen_server:stop(Pid),
    restore_env(Previous),
    _ = remove_tree(Root),
    ok;
cleanup(_Context) ->
    ok.

run_history_case(_Context) ->
    Owner = owner(<<"owner-a">>),
    OtherOwner = owner(<<"owner-b">>),
    {ok, Project} = ecai_conversation_store:create_project(
        Owner,
        <<"Release planning">>,
        <<"Prefer terse implementation notes.">>
    ),
    ProjectId = maps:get(id, Project),
    {ok, Conversation0} = ecai_conversation_store:create_conversation(
        Owner, ProjectId, <<>>
    ),
    ConversationId = maps:get(id, Conversation0),
    {ok, Stored} = ecai_conversation_store:append_exchange(
        Owner,
        ConversationId,
        <<"How should the rocket telemetry index survive restarts?">>,
        <<"Persist checkpoints and resume from the last committed cursor.">>,
        #{backend => <<"test">>}
    ),
    Conversation1 = maps:get(conversation, Stored),
    ?assertNotEqual(<<"New chat">>, maps:get(title, Conversation1)),

    {ok, Hits} = ecai_conversation_store:search(Owner, <<"rocket telemetry">>, ProjectId, 10),
    ?assertMatch([_ | _], Hits),
    [Hit | _] = Hits,
    ?assertEqual(ConversationId, maps:get(conversation_id, Hit)),

    {ok, []} = ecai_conversation_store:search(OtherOwner, <<"rocket telemetry">>, undefined, 10),

    {ok, Context} = ecai_conversation_store:context(
        Owner, ConversationId, <<"restart cursor">>, 12
    ),
    ?assertEqual(ProjectId, maps:get(project_id, Context)),
    ?assertEqual(<<"Prefer terse implementation notes.">>, maps:get(project_instructions, Context)),
    ?assert(length(maps:get(recent, Context)) >= 2),

    {ok, #{conversations_unassigned := 1}} =
        ecai_conversation_store:delete_project(Owner, ProjectId),
    {ok, #{conversation := Conversation2}} =
        ecai_conversation_store:get_conversation(Owner, ConversationId),
    ?assertEqual(null, maps:get(project_id, Conversation2, undefined)),

    {ok, _} = ecai_conversation_store:delete_conversation(Owner, ConversationId),
    ok.

owner(Suffix) ->
    Unique = integer_to_binary(erlang:unique_integer([positive])),
    <<Suffix/binary, "-", Unique/binary>>.

restore_env(undefined) ->
    application:unset_env(ecai, conversation_history_dir);
restore_env({ok, Value}) ->
    application:set_env(ecai, conversation_history_dir, Value).

remove_tree(Path) ->
    case file:list_dir(Path) of
        {ok, Entries} ->
            lists:foreach(fun(Name) ->
                Child = filename:join(Path, Name),
                case filelib:is_dir(Child) of
                    true -> remove_tree(Child);
                    false -> file:delete(Child)
                end
            end, Entries),
            file:del_dir(Path);
        {error, enoent} -> ok;
        Error -> Error
    end.
