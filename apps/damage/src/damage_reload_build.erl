%% Compilation produces binaries only. Publication belongs to damage_reload.
-module(damage_reload_build).
-export([snapshot/1, prepare/4, publish/2, interesting/2]).
-include_lib("kernel/include/file.hrl").

snapshot(Cfg) ->
    Paths = lists:usort(lists:append([walk(D, Cfg) || D <- maps:get(watch_dirs, Cfg)])),
    [{P, fingerprint(P)} || P <- Paths].

walk(Dir, Cfg) ->
    %% Fail closed on unreadable/replaced roots; do not silently return an empty tree.
    {ok, #file_info{type = directory}} = file:read_link_info(Dir),
    {ok, Names} = file:list_dir(Dir),
    lists:append([walk_entry(filename:join(Dir, N), N, Cfg) || N <- Names]).

walk_entry(P, Name, Cfg) ->
    case lists:member(Name, [".git", "_build", "ebin", "node_modules"]) of
        true -> [];
        false ->
            case file:read_link_info(P) of
                {ok, #file_info{type = directory}} -> walk(P, Cfg);
                {ok, #file_info{type = regular}} ->
                    case interesting(P, Cfg) of true -> [P]; false -> [] end;
                {ok, #file_info{type = symlink}} ->
                    %% Never recursively follow symlinks below a configured root.
                    case filename:extension(P) of
                        ".erl" -> error({symlink_source, P});
                        ".hrl" -> error({symlink_header, P});
                        _ -> []
                    end;
                {ok, _} -> [];
                {error, Why} -> error({scan_failed, P, Why})
            end
    end.

interesting(P0, Cfg) ->
    P = filename:absname(P0),
    Ext = filename:extension(P),
    Base = filename:basename(P, ".erl"),
    InScope = lists:any(fun(D) -> damage_reload_config:within(P, D) end,
        maps:get(watch_dirs, Cfg)),
    NotGenerated = Base =/= "damage_build_info",
    InScope andalso NotGenerated andalso (Ext =:= ".erl" orelse Ext =:= ".hrl").

fingerprint(P) ->
    {ok, B} = file:read_file(P),
    crypto:hash(sha256, B).

%% A pending batch is reused only while every tracked source/header is unchanged.
prepare(Cfg, Observed, Pending, Force) ->
    Before = snapshot(Cfg),
    case {Before =:= Observed, Pending, Force} of
        {_, {Before, Objects}, false} -> {candidate, Before, Objects};
        {true, none, false} -> {unchanged, Before};
        _ ->
            try compile_batch(Cfg, Before) of
                Objects ->
                    case snapshot(Cfg) of
                        Before -> {candidate, Before, Objects};
                        _ -> {stale, Before}
                    end
            catch
                Class:Why:Stack -> {failed, Before, {Class, Why, Stack}}
            end
    end.

compile_batch(#{mode := sources} = Cfg, Snapshot) ->
    Modules = maps:get(modules, Cfg),
    Sources = [P || {P, _} <- Snapshot, filename:extension(P) =:= ".erl",
        lists:any(fun(D) -> damage_reload_config:within(P, D) end,
            maps:get(source_dirs, Cfg))],
    [compile_source(M, source_for(M, Sources), Cfg) || M <- Modules];
compile_batch(#{mode := rebar} = Cfg, _Snapshot) ->
    run_rebar(Cfg),
    Base = filename:join([maps:get(build_dir, Cfg), maps:get(profile, Cfg), "lib"]),
    Objects = lists:append([app_objects(A, Base, Cfg) || A <- maps:get(apps, Cfg)]),
    unique(Objects),
    Objects.

source_for(M, Sources) ->
    Name = atom_to_list(M) ++ ".erl",
    case [P || P <- Sources, filename:basename(P) =:= Name] of
        [P] -> P;
        [] -> error({missing_allowed_source, M});
        Paths -> error({duplicate_source, M, Paths})
    end.

compile_source(M, Source, Cfg) ->
    Stored = case maps:get(reuse_compile_opts, Cfg) of
        true -> previous_options(M);
        false -> []
    end,
    Includes = [{i, D} || D <- maps:get(include_dirs, Cfg)],
    Extra = maps:get(erl_opts, Cfg),
    %% Remove build-host/output paths from recorded options. Explicit options
    %% take precedence, but neither environment nor config may request disk output.
    Options = [binary, return_errors, return_warnings] ++
        merge_options(Includes ++ Extra, Stored),
    case compile:noenv_file(Source, Options) of
        {ok, M, Bin} when is_binary(Bin) -> {M, filename:rootname(Source) ++ ".beam", Bin};
        {ok, M, Bin, _Warnings} when is_binary(Bin) -> {M, filename:rootname(Source) ++ ".beam", Bin};
        {error, Errors, Warnings} -> error({compile_failed, M, Errors, Warnings});
        Other -> error({unexpected_compile_result, M, Other})
    end.

previous_options(M) ->
    case code:is_loaded(M) of
        false ->
            case code:get_object_code(M) of
                {M, B, _} ->
                    case beam_lib:chunks(B, [compile_info]) of
                        {ok, {M, [{compile_info, Info}]}} ->
                            proplists:get_value(options, Info, []);
                        _ -> []
                    end;
                error -> []
            end;
        _ -> proplists:get_value(options, M:module_info(compile), [])
    end.

merge_options(Local0, Stored0) ->
    Local = clean_options(Local0),
    Keys = [option_key(O) || O <- Local],
    Combined = Local ++ [O || O <- clean_options(Stored0),
        not lists:member(option_key(O), Keys)],
    {Reverse, _} = lists:foldl(fun(O, {Acc, Seen}) ->
        case maps:is_key(O, Seen) of
            true -> {Acc, Seen};
            false -> {[O | Acc], Seen#{O => true}}
        end
    end, {[], #{}}, Combined),
    lists:reverse(Reverse).

option_key({d, Name, _}) -> {d, Name};
option_key({d, Name}) -> {d, Name};
option_key({i, Path}) -> {i, Path};
option_key({parse_transform, M}) -> {parse_transform, M};
option_key(no_debug_info) -> debug_info;
option_key(O) when is_tuple(O), tuple_size(O) > 0 -> element(1, O);
option_key(O) -> O.

clean_options(Opts) ->
    [O || O <- Opts, keep_option(O)].

keep_option({outdir, _}) -> false;
keep_option({cwd, _}) -> false;
keep_option({source, _}) -> false;
keep_option({i, P}) ->
    filename:pathtype(P) =:= absolute andalso filelib:is_dir(P);
keep_option({makedep_output, _}) -> false;
keep_option({makedep_target, _}) -> false;
keep_option(O) when is_atom(O) ->
    not lists:member(O, [binary, return, return_errors, return_warnings,
        report, report_errors, report_warnings, makedep, makedep_side_effect,
        makedep_add_missing, makedep_phony, makedep_quote_target,
        'P', 'E', 'S', to_pp, to_exp, to_core, to_kernel, to_asm,
        from_abstr, from_core, from_asm, no_code_generation]);
keep_option(_) -> true.

app_objects(App, Base, Cfg) ->
    AppRoot = filename:join(Base, atom_to_list(App)),
    Ebin = filename:join(AppRoot, "ebin"),
    %% The app resource is the build's manifest, avoiding stale orphan .beam files.
    {ok, [{application, App, Props}]} = file:consult(
        filename:join(Ebin, atom_to_list(App) ++ ".app")),
    Mods = proplists:get_value(modules, Props, []),
    true = Mods =/= [],
    [read_object(M, filename:join(Ebin, atom_to_list(M) ++ ".beam")) || M <- Mods,
        not lists:member(M, maps:get(exclude_modules, Cfg))].

read_object(M, P) ->
    {ok, B} = file:read_file(P),
    {ok, {M, _}} = beam_lib:md5(B),
    {M, P, B}.

unique(Objects) ->
    Ms = [M || {M, _, _} <- Objects],
    case length(Ms) =:= length(lists:usort(Ms)) of
        true -> ok;
        false -> error({duplicate_modules, Ms})
    end.

run_rebar(Cfg) ->
    Root = maps:get(root, Cfg),
    Build = maps:get(build_dir, Cfg),
    ok = filelib:ensure_dir(filename:join(Build, ".ensure")),
    Executable0 = maps:get(rebar3, Cfg),
    Executable = case filename:pathtype(Executable0) of
        absolute -> Executable0;
        _ ->
            case os:find_executable(Executable0) of
                false -> error({executable_not_found, Executable0});
                Found -> Found
            end
    end,
    Profile = maps:get(profile, Cfg),
    Args = case Profile of
        "default" -> ["compile"];
        _ -> ["as", Profile, "compile"]
    end,
    Env = [{"REBAR_BASE_DIR", Build}, {"REBAR_PROFILE", false}, {"REBAR_CONFIG", false},
        {"ERL_FLAGS", false}, {"ERL_AFLAGS", false}, {"ERL_ZFLAGS", false},
        {"ERL_LIBS", false}],
    %% erlexec is already a project dependency. An argv list avoids SHELL parsing.
    {ok, Pid, OsPid} = exec:run_link([Executable | Args],
        [monitor, stdout, stderr, {cd, Root}, {env, Env}, {group, 0}, kill_group]),
    Deadline = erlang:monotonic_time(millisecond) + maps:get(build_timeout_ms, Cfg),
    try wait_rebar(Pid, OsPid, Deadline, <<>>) after
        unlink(Pid),
        try exec:stop_and_wait(Pid, 10000) of _ -> ok catch _:_ -> ok end
    end.

wait_rebar(Pid, OsPid, Deadline, Tail) ->
    Left = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {stdout, OsPid, Data} -> wait_rebar(Pid, OsPid, Deadline, tail(Tail, Data));
        {stderr, OsPid, Data} -> wait_rebar(Pid, OsPid, Deadline, tail(Tail, Data));
        {'DOWN', OsPid, process, Pid, normal} -> ok;
        {'DOWN', OsPid, process, Pid, Reason} -> error({rebar_failed, Reason, Tail});
        {'EXIT', Pid, _} -> wait_rebar(Pid, OsPid, Deadline, Tail);
        {'EXIT', _, Reason} -> exit(Reason)
    after Left -> error({rebar_timeout, Tail})
    end.

tail(Old, New) ->
    B = iolist_to_binary([Old, New]),
    N = byte_size(B),
    case N > 16384 of true -> binary:part(B, N - 16384, 16384); false -> B end.

%% No disk writes, no code path additions, and no force-purge fallback.
publish(Cfg, Objects0) ->
    try
        unique(Objects0),
        Objects = [O || O <- Objects0, changed(O)],
        lists:foreach(fun(O) -> validate_object(Cfg, O) end, Objects),
        publish_objects(Objects)
    catch
        Class:Reason -> {error, {publish_failed, Class, Reason}}
    end.

changed({M, _, B}) ->
    {ok, {M, Hash}} = beam_lib:md5(B),
    case code:is_loaded(M) of
        false ->
            %% Do not eagerly load unchanged, unloaded release modules (especially
            %% NIF/on_load modules). Compare their existing code-path object instead.
            case code:get_object_code(M) of
                {M, Existing, _} -> beam_lib:md5(Existing) =/= {ok, {M, Hash}};
                error -> true
            end;
        _ -> M:module_info(md5) =/= Hash
    end.

validate_object(Cfg, {M, _, B}) ->
    case lists:member(M, maps:get(exclude_modules, Cfg)) of
        true -> error({restart_required, M, protected_module});
        false -> ok
    end,
    case code:is_sticky(M) of
        true -> error({restart_required, M, sticky_module});
        false -> ok
    end,
    case maps:get(mode, Cfg) of
        sources ->
            case lists:member(M, maps:get(modules, Cfg)) of
                true -> ok;
                false -> error({module_not_allowed, M})
            end;
        rebar -> ok
    end,
    {ok, {M, Chunks}} = beam_lib:chunks(B, [attributes, imports]),
    Imports = proplists:get_value(imports, Chunks, []),
    Attrs = proplists:get_value(attributes, Chunks, []),
    %% on_load is additionally rejected by prepare_loading. Native changes need
    %% an explicit restart/upgrade, not an automatic development fallback.
    case lists:member({erlang, load_nif, 2}, Imports) orelse lists:keymember(nifs, 1, Attrs) of
        true -> error({restart_required, M, native_module});
        false -> ok
    end.

publish_objects([]) -> {ok, []};
publish_objects(Objects) ->
    case code:prepare_loading(Objects) of
        {ok, Prepared} ->
            Busy = [M || {M, _, _} <- Objects, code:soft_purge(M) =:= false],
            case Busy of
                [] ->
                    case code:finish_loading(Prepared) of
                        ok -> {ok, [M || {M, _, _} <- Objects]};
                        {error, Reasons} ->
                            case lists:all(fun({_, R}) -> R =:= not_purged end, Reasons) of
                                true -> {deferred, [M || {M, _} <- Reasons]};
                                false -> {error, {finish_loading_failed, Reasons}}
                            end
                    end;
                _ -> {deferred, Busy}
            end;
        {error, Reasons} -> {error, {prepare_loading_failed, Reasons}}
    end.
