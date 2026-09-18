%%% Explicitly enabled, allowlisted operator hot-code support.
%%% This is NOT an Erlang sandbox: allowed source/parse transforms execute with
%%% node privileges. Use OTP release upgrades for core/stateful/NIF modules.
-module(damage_hotcode).
-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

-export([prepare/1, reload/1, rollback/1, status/0, allowed/1,
         source_dir/0, source_path/1, release_source/1]).

-define(DEFAULT_SOURCE_DIR, "/var/lib/damage/overrides/src").
-define(MAX_SOURCE_BYTES, 4194304).

-spec allowed(module()) -> ok | {error, term()}.
allowed(Module) when is_atom(Module) ->
    guarded(fun() ->
        require(in_application(Module), {module_not_in_damage_application, Module}),
        %% Never allow the policy/loader/registry/auth/custody/runner itself.
        %% No wildcard configuration: only exact, explicitly listed atoms.
        require(reload_class(Module), {protected_hotcode_module, Module}),
        Config = application:get_env(damage, operator_hotcode, []),
        require(is_list(Config), invalid_operator_hotcode_config),
        require(proplists:get_value(enabled, Config, false) =:= true, hotcode_disabled),
        Allowed = proplists:get_value(allowed_modules, Config, []),
        require(is_list(Allowed) andalso lists:all(fun erlang:is_atom/1, Allowed),
                invalid_hotcode_allowlist),
        require(lists:member(Module, Allowed), {hotcode_module_not_allowed, Module}),
        ok
    end);
allowed(_) -> {error, invalid_hotcode_module}.

reload_class(steps_hotcode) -> false;
reload_class(steps_utils) -> false;
reload_class(text_formatter) -> true;
reload_class(html_formatter) -> true;
reload_class(Module) -> lists:prefix("steps_", atom_to_list(Module)).

in_application(Module) ->
    case application:get_key(damage, modules) of
        {ok, Modules} when is_list(Modules) -> lists:member(Module, Modules);
        _ -> false
    end.

-spec prepare(module()) -> {ok, copied | exists, file:filename_all()} | {error, term()}.
prepare(Module) ->
    guarded(fun() ->
        must_ok(allowed(Module)),
        damage_release_overrides:with_lock(fun() ->
            {ok, Source} = must(release_source(Module)),
            {ok, Bytes} = must(read_source(Source)),
            Dest = source_path(Module),
            must_ok(filelib:ensure_dir(Dest)),
            %% Exclusive create: concurrent prepare must never clobber an edit.
            case write_exclusive(Dest, Bytes) of
                ok -> {ok, copied, Dest};
                {error, eexist} ->
                    must_ok(regular_file(Dest)),
                    {ok, exists, Dest};
                {error, Why} -> {error, {copy_override_source_failed, Why}}
            end
        end)
    end).

-spec reload(module()) -> {ok, map()} | {error, term()}.
reload(Module) ->
    guarded(fun() ->
        must_ok(allowed(Module)),
        Source = source_path(Module),
        {ok, Bytes} = must(read_source(Source)),
        %% Compile an immutable copy, never hash an independently reread edit.
        %% Includes are still trusted build inputs, not part of source_sha256;
        %% beam_sha256 identifies the complete compiled object.
        {ok, Beam, Warnings} = must(compile_snapshot(Module, Source, Bytes)),
        must_ok(check_plain_beam(Module, Beam)),
        {ok, BeamPath} = must(cache_beam(Module, Beam)),
        damage_release_overrides:with_lock(fun() ->
            must_ok(allowed(Module)),
            load_override(Module, BeamPath, Beam, sha256(Bytes), Warnings)
        end)
    end).

-spec rollback(module()) -> {ok, map()} | {error, term()}.
rollback(Module) when is_atom(Module) ->
    guarded(fun() ->
        %% Disabling hotcode/revoking allowlist membership must not prevent undo.
        require(in_application(Module), {module_not_in_damage_application, Module}),
        damage_release_overrides:with_lock(fun() -> rollback_locked(Module) end)
    end);
rollback(_) -> {error, invalid_hotcode_module}.

load_override(Module, Filename, Beam, SourceSha, Warnings) ->
    Previous = damage_release_overrides:get(Module),
    Entry = case Previous of
        not_found -> capture_base(Module);
        {ok, Existing} ->
            require(maps:get(state, Existing, legacy) =:= active,
                    {override_requires_rollback, Module}),
            %% Module MD5 alone cannot distinguish different BEAM metadata.
            {ok, Current} = must(damage_release_overrides:current_generation(Module, Existing)),
            require(maps:get(filename, Current) =:= maps:get(loaded_filename, Existing, undefined)
                andalso maps:get(beam_sha256, Current) =:= maps:get(loaded_beam_sha256, Existing),
                {untracked_current_code, Module}),
            Existing
    end,
    {ok, NewMd5} = must(beam_md5(Module, Beam)),
    require(code:soft_purge(Module), old_code_still_in_use),
    OldSha = maps:get(loaded_beam_sha256, Entry),
    Pending = Entry#{module => Module, state => loading,
        source_sha256 => SourceSha, beam_sha256 => sha256(Beam),
        candidate_module_md5 => NewMd5, candidate_filename => Filename,
        loaded_at => erlang:system_time(second)},
    %% Write-ahead marker survives caller death even after the code changes.
    %% Snapshot readers share this lock; an interrupted transition is uncertain.
    ok = damage_release_overrides:record(Pending),
    %% Single-module atomic_load refuses on_load and never implicitly purges
    %% lingering processes. The cached filename also supports abstract-code
    %% inspection via code:which/1 in the runner's strict step checker.
    case code:atomic_load([{Module, Filename, Beam}]) of
        ok ->
            {ok, Loaded} = must(damage_release_overrides:current_generation(Module, Pending)),
            require(maps:get(filename, Loaded) =:= Filename
                andalso maps:get(beam_sha256, Loaded) =:= sha256(Beam),
                {untracked_current_code, Module}),
            Old = case code:soft_purge(Module) of true -> <<>>; false -> OldSha end,
            Active = maps:without([candidate_filename, candidate_module_md5],
                Pending#{state => active, loaded_module_md5 => NewMd5,
                    loaded_filename => Filename, loaded_beam_sha256 => sha256(Beam),
                    old_beam_sha256 => Old}),
            ok = damage_release_overrides:record(Active),
            ?LOG_NOTICE("Loaded operator override module=~p beam_sha256=~s", [Module, sha256(Beam)]),
            {ok, (public_entry(Module))#{warnings => Warnings}};
        {error, Why} ->
            restore_journal(Module, Previous),
            {error, {hot_code_load_failed, Why}}
    end.

capture_base(Module) ->
    {module, Module} = must_loaded(code:ensure_loaded(Module)),
    %% Read the exact packaged file, not code:get_object_code's code-path search.
    %% Refuse to label an already-untracked hot load as the immutable base.
    Dir = code:lib_dir(damage, ebin),
    require(is_list(Dir), release_ebin_unavailable),
    Path = filename:join(Dir, atom_to_list(Module) ++ ".beam"),
    must_ok(regular_file(Path)),
    {ok, Beam} = must(file:read_file(Path)),
    {ok, Md5} = must(beam_md5(Module, Beam)),
    require(current_md5(Module) =:= Md5 andalso code:is_loaded(Module) =:= {file, Path},
            {base_beam_not_current, Module}),
    must_ok(check_plain_beam(Module, Beam)),
    #{module => Module, base_beam => Beam, base_filename => Path,
      base_beam_sha256 => sha256(Beam), base_module_md5 => Md5,
      loaded_module_md5 => Md5, loaded_filename => Path,
      loaded_beam_sha256 => sha256(Beam)}.

rollback_locked(Module) ->
    Entry = case damage_release_overrides:get(Module) of
        {ok, E} -> E;
        not_found -> throw({hotcode_error, module_not_overridden})
    end,
    BaseBeam = maps:get(base_beam, Entry, undefined),
    require(is_binary(BaseBeam), {base_beam_unavailable, Module}),
    require(sha256(BaseBeam) =:= maps:get(base_beam_sha256, Entry), base_beam_hash_mismatch),
    BaseMd5 = maps:get(base_module_md5, Entry),
    %% A loading marker does not prove atomic_load ran. Resolve the actual
    %% managed filename AND module MD5 before selecting a full-BEAM digest.
    %% Missing or conflicting identities must not be guessed from MD5 alone.
    {ok, Current} = must(damage_release_overrides:current_generation(Module, Entry)),
    CurrentSha = maps:get(beam_sha256, Current),
    IsBase = maps:get(filename, Current) =:= maps:get(base_filename, Entry) andalso
        CurrentSha =:= maps:get(base_beam_sha256, Entry),
    case IsBase of
        true -> finish_rollback(Module, Entry);
        false ->
            require(code:soft_purge(Module), old_code_still_in_use),
            Pending = Entry#{state => rolling_back,
                loaded_module_md5 => maps:get(module_md5, Current),
                loaded_filename => maps:get(filename, Current),
                loaded_beam_sha256 => CurrentSha},
            ok = damage_release_overrides:record(Pending),
            case code:atomic_load([{Module, maps:get(base_filename, Entry), BaseBeam}]) of
                ok ->
                    %% Keep the former override hash while it is old code.
                    Restored = Pending#{state => rollback_pending,
                        loaded_module_md5 => BaseMd5,
                        loaded_filename => maps:get(base_filename, Entry),
                        loaded_beam_sha256 => maps:get(base_beam_sha256, Entry),
                        old_beam_sha256 => CurrentSha},
                    ok = damage_release_overrides:record(Restored),
                    finish_rollback(Module, Restored);
                {error, Why} ->
                    ok = damage_release_overrides:record(Entry),
                    {error, {release_beam_reload_failed, Why}}
            end
    end.

finish_rollback(Module, Entry) ->
    %% On a retry, base is already current: only retry the soft purge. Never
    %% load another base generation on top of an active old override.
    case code:soft_purge(Module) of
        true ->
            must_ok(damage_release_overrides:remove(Module)),
            {ok, #{module => Module, status => rolled_back}};
        false ->
            ok = damage_release_overrides:record(Entry#{state => rollback_pending,
                loaded_module_md5 => maps:get(base_module_md5, Entry),
                loaded_filename => maps:get(base_filename, Entry),
                loaded_beam_sha256 => maps:get(base_beam_sha256, Entry),
                old_beam_sha256 => rollback_old_sha(Entry)}),
            {error, rollback_loaded_but_override_still_in_use}
    end.

rollback_old_sha(#{state := rolling_back} = Entry) ->
    %% The caller may have died after loading the base but before committing.
    maps:get(loaded_beam_sha256, Entry, <<"unknown">>);
rollback_old_sha(Entry) -> maps:get(old_beam_sha256, Entry, <<"unknown">>).

restore_journal(Module, not_found) -> must_ok(damage_release_overrides:remove(Module));
restore_journal(_Module, {ok, Meta}) -> damage_release_overrides:record(Meta).

public_entry(Module) ->
    [Entry] = [E || E <- status(), maps:get(module, E) =:= atom_to_binary(Module, utf8)],
    Entry.

-spec status() -> [map()].
status() -> damage_release_overrides:list().

-spec source_dir() -> file:filename_all().
source_dir() ->
    case application:get_env(damage, operator_source_dir) of
        {ok, Dir} when is_binary(Dir) -> binary_to_list(Dir);
        {ok, Dir} when is_list(Dir) -> Dir;
        _ -> ?DEFAULT_SOURCE_DIR
    end.

-spec source_path(module()) -> file:filename_all().
source_path(Module) when is_atom(Module) ->
    filename:join(source_dir(), atom_to_list(Module) ++ ".erl").

-spec release_source(module()) -> {ok, file:filename_all()} | {error, term()}.
release_source(Module) when is_atom(Module) ->
    case code:lib_dir(damage, src) of
        Dir when is_list(Dir) ->
            Path = filename:join(Dir, atom_to_list(Module) ++ ".erl"),
            case regular_file(Path) of ok -> {ok, Path}; Error -> Error end;
        _ -> {error, release_source_dir_unavailable}
    end.

regular_file(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular}} -> ok;
        {ok, _} -> {error, {not_regular_file, Path}};
        {error, Why} -> {error, {file_stat_failed, Path, Why}}
    end.

read_source(Path) ->
    guarded(fun() ->
        must_ok(regular_file(Path)),
        {ok, Fd} = must(file:open(Path, [read, binary, raw])),
        try
            case file:read(Fd, ?MAX_SOURCE_BYTES + 1) of
                {ok, Bytes} when byte_size(Bytes) =< ?MAX_SOURCE_BYTES -> {ok, Bytes};
                {ok, _} -> {error, override_source_too_large};
                eof -> {ok, <<>>};
                {error, _} = Error -> Error
            end
        after file:close(Fd) end
    end).

compile_snapshot(Module, Source, Bytes) ->
    StagingRoot = filename:join(filename:dirname(source_dir()), ".compile"),
    must_ok(filelib:ensure_dir(filename:join(StagingRoot, "unused"))),
    Dir = filename:join(StagingRoot, binary_to_list(sha256(crypto:strong_rand_bytes(32)))),
    must_ok(file:make_dir(Dir)),
    Path = filename:join(Dir, atom_to_list(Module) ++ ".erl"),
    try
        must_ok(file:change_mode(Dir, 8#700)),
        must_ok(write_exclusive(Path, Bytes)),
        Include = case code:lib_dir(damage, include) of
            D when is_list(D) -> [{i, D}];
            _ -> []
        end,
        Opts = [binary, debug_info, return_errors, return_warnings,
                {source, Source}, {i, filename:dirname(Source)} | Include],
        case compile:noenv_file(Path, Opts) of
            {ok, Module, Beam} when is_binary(Beam) -> {ok, Beam, []};
            {ok, Module, Beam, Warnings} when is_binary(Beam) -> {ok, Beam, Warnings};
            {ok, Other, _} -> {error, {override_module_name_mismatch, Module, Other}};
            {ok, Other, _, _} -> {error, {override_module_name_mismatch, Module, Other}};
            {error, Errors, Warnings} -> {error, {compile_failed, Errors, Warnings}};
            Other -> {error, {unexpected_compile_result, Other}}
        end
    after
        file:delete(Path),
        file:del_dir(Dir)
    end.

cache_beam(Module, Beam) ->
    %% Never add this directory to the VM's code path or auto-load it on boot.
    Dir = filename:join([filename:dirname(source_dir()), "beams", binary_to_list(sha256(Beam))]),
    Path = filename:join(Dir, atom_to_list(Module) ++ ".beam"),
    must_ok(filelib:ensure_dir(Path)),
    case write_exclusive(Path, Beam) of
        ok -> {ok, Path};
        {error, eexist} ->
            must_ok(regular_file(Path)),
            case file:read_file(Path) of
                {ok, Beam} -> {ok, Path};
                _ -> {error, cached_beam_hash_mismatch}
            end;
        {error, _} = Error -> Error
    end.

write_exclusive(Path, Bytes) ->
    case file:open(Path, [write, binary, exclusive]) of
        {ok, Fd} ->
            Result = try
                case file:write(Fd, Bytes) of ok -> file:sync(Fd); Error -> Error end
            after file:close(Fd) end,
            case Result of ok -> ok; _ -> file:delete(Path), Result end;
        {error, _} = Error -> Error
    end.

%% This helper is intentionally not an OTP state migration/NIF upgrader. Require
%% inspectable ordinary BEAMs on both sides so rollback cannot introduce on_load
%% effects. atomic_load/1 is a second, VM-enforced on_load check.
check_plain_beam(Module, Beam) ->
    case beam_lib:chunks(Beam, [abstract_code]) of
        {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} ->
            Forbidden = [Name || {attribute, _, Name, _} <- Forms,
                                Name =:= on_load orelse Name =:= nifs],
            case Forbidden of
                [] -> ok;
                _ -> {error, {unsupported_hotcode_attributes, Module, Forbidden}}
            end;
        _ -> {error, {hotcode_debug_info_required, Module}}
    end.

beam_md5(Module, Beam) ->
    case beam_lib:md5(Beam) of
        {ok, {Module, Md5}} -> {ok, hex(Md5)};
        _ -> {error, {invalid_beam, Module}}
    end.

current_md5(Module) ->
    case code:is_loaded(Module) of
        false -> undefined;
        _ -> try hex(Module:module_info(md5)) catch _:_ -> undefined end
    end.

must_loaded({module, _} = Result) -> Result;
must_loaded(Error) -> throw({hotcode_error, {module_load_failed, Error}}).
must({ok, _, _} = Result) -> Result;
must({ok, _} = Result) -> Result;
must({error, Why}) -> throw({hotcode_error, Why}).
must_ok(ok) -> ok;
must_ok({error, Why}) -> throw({hotcode_error, Why}).
require(true, _) -> ok;
require(false, Why) -> throw({hotcode_error, Why}).
guarded(Fun) ->
    try Fun()
    catch
        throw:{hotcode_error, Why} -> {error, Why};
        error:undef -> {error, required_hotcode_component_unavailable};
        Class:Why -> {error, {hotcode_exception, Class, Why}}
    end.
sha256(Bytes) -> hex(crypto:hash(sha256, Bytes)).
hex(Bytes) -> string:lowercase(binary:encode_hex(Bytes)).
