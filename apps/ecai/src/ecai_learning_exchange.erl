%% Export commit-pinned, source-free ECAI learning evidence for collaboration.
%% Bundles are evidence only: this module deliberately does not auto-import them
%% into the live learning store.
-module(ecai_learning_exchange).

-export([export_bundle/0, list_bundles/0]).

-define(SCHEMA, 1).

export_bundle() ->
    Config = ecai_code_runtime_config:get(),
    Sharing = maps:get(sharing, Config),
    case maps:get(enabled, Sharing, false) of
        false -> {error, learning_sharing_disabled};
        true ->
            case ensure_learning_quiescent() of
                ok ->
                    case ecai_code_runtime_config:learning_admission() of
                        {ok, Admission} -> write_bundle(Config, Sharing, Admission);
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end
    end.

list_bundles() ->
    Sharing = maps:get(sharing, ecai_code_runtime_config:get()),
    Dir = to_list(maps:get(directory, Sharing, <<>>)),
    case Dir of
        [] -> {ok, []};
        _ ->
            case file:list_dir(Dir) of
                {ok, Names} ->
                    Files = lists:sort([to_binary(N) || N <- Names, filename:extension(N) =:= ".json"]),
                    {ok, Files};
                {error, enoent} -> {ok, []};
                {error, _} = Error -> Error
            end
    end.

ensure_learning_quiescent() ->
    case ecai_codebase_learner:status() of
        #{
            phase := idle,
            ready := true,
            inflight_count := 0,
            queued := 0,
            refresh_requested := false
        } ->
            ok;
        Status ->
            {error, {learning_not_quiescent, Status}}
    end.

write_bundle(Config, Sharing, Admission) ->
    Repo = maps:get(repository, Config),
    Root = maps:get(working_root, Repo),
    Snapshot0 = ecai_learning_snapshot:build(#{repo_root => Root}),
    Snapshot = portable_snapshot(Snapshot0),
    Core = #{
        schema_version => ?SCHEMA,
        kind => <<"ecai-code-learning-bundle">>,
        created_at => now_iso8601(),
        repository => #{
            commit => maps:get(head, Admission),
            branch => maps:get(branch, Admission),
            remote => maps:get(remote, Repo)
        },
        snapshot => Snapshot,
        source_bodies_included => false,
        local_paths_included => false,
        runtime_state_included => false,
        import_policy => <<"verify-before-adopt">>
    },
    Digest = sha256(term_to_binary(Core, [deterministic])),
    Bundle = Core#{bundle_sha256 => Digest},
    Dir = to_list(maps:get(directory, Sharing)),
    Commit = maps:get(head, Admission),
    Short = binary:part(Digest, 0, 12),
    Name = <<"learning-", Commit/binary, "-", Short/binary, ".json">>,
    File = filename:join(Dir, binary_to_list(Name)),
    case filelib:ensure_dir(File) of
        ok ->
            Tmp = File ++ ".tmp",
            case file:write_file(Tmp, jsx:encode(json_safe(Bundle)), [binary]) of
                ok ->
                    _ = file:change_mode(Tmp, 8#640),
                    case file:rename(Tmp, File) of
                        ok ->
                            {ok, #{
                                file => to_binary(File),
                                name => Name,
                                bundle_sha256 => Digest,
                                commit => Commit,
                                source_bodies_included => false,
                                local_paths_included => false
                            }};
                        {error, _} = Error -> _ = file:delete(Tmp), Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

portable_snapshot(Snapshot0) when is_map(Snapshot0) ->
    Git0 = maps:get(git, Snapshot0, #{}),
    Learning0 = maps:get(learning, Snapshot0, #{}),
    Analyses0 = maps:get(analyses, Learning0, []),
    Repairs0 = maps:get(repairs, Learning0, []),
    Analyses = [maps:without([source, source_name, full_path], A) || A <- Analyses0, is_map(A)],
    Repairs = [maps:without([patch_file, worktree, context, verifier_output, proposal], R) || R <- Repairs0, is_map(R)],
    Learning = (maps:without([runtime_checkpoints], Learning0))#{
        analyses => Analyses,
        repairs => Repairs
    },
    (maps:without([inference_pool], Snapshot0))#{
        git => maps:with([available, commit, dirty], Git0),
        learning => Learning
    }.

sha256(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte:8>> <= crypto:hash(sha256, Bin)]).

json_safe(Map) when is_map(Map) -> maps:from_list([{json_key(K), json_safe(V)} || {K, V} <- maps:to_list(Map)]);
json_safe(List) when is_list(List) -> [json_safe(V) || V <- List];
json_safe(undefined) -> null;
json_safe(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
json_safe(Tuple) when is_tuple(Tuple) -> to_binary(Tuple);
json_safe(V) -> V.
json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) when is_binary(K) -> K;
json_key(K) -> to_binary(K).

to_list(Bin) when is_binary(Bin) -> unicode:characters_to_list(Bin);
to_list(List) when is_list(List) -> List.
to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) -> unicode:characters_to_binary(List);
to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(Value) -> iolist_to_binary(io_lib:format("~0tp", [Value])).
now_iso8601() -> unicode:characters_to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}, {offset, "Z"}])).
