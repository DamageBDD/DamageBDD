%%%-------------------------------------------------------------------
%%% Controlled operator hot-code support for the DamageBDD application.
%%%
%%% Only modules already declared by the damage OTP application may be loaded.
%%% Source is compiled to an in-memory BEAM and never overwrites the packaged
%%% release. Runtime provenance is recorded by damage_release_overrides.
%%%-------------------------------------------------------------------
-module(damage_hotcode).

-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

-export([
    prepare/1,
    reload/1,
    rollback/1,
    status/0,
    source_dir/0,
    source_path/1,
    release_source/1
]).

-define(DEFAULT_SOURCE_DIR, "/var/lib/damage/overrides/src").

-spec prepare(module()) -> {ok, copied | exists, file:filename_all()} | {error, term()}.
prepare(Module) when is_atom(Module) ->
    with_damage_module(Module, fun() ->
        case release_source(Module) of
            {ok, Source} ->
                Dest = source_path(Module),
                case filelib:ensure_dir(Dest) of
                    ok ->
                        case file:read_link_info(Dest) of
                            {ok, #file_info{type = regular}} ->
                                {ok, exists, Dest};
                            {ok, _} ->
                                {error, override_source_not_regular};
                            {error, enoent} ->
                                case file:copy(Source, Dest) of
                                    {ok, _Bytes} -> {ok, copied, Dest};
                                    {error, Why} -> {error, {copy_override_source_failed, Why}}
                                end;
                            {error, Why} ->
                                {error, {override_source_stat_failed, Why}}
                        end;
                    {error, Why} ->
                        {error, {override_source_dir_failed, Why}}
                end;
            Error ->
                Error
        end
    end).

-spec reload(module()) -> {ok, map()} | {error, term()}.
reload(Module) when is_atom(Module) ->
    with_damage_module(Module, fun() -> reload_damage_module(Module) end).

reload_damage_module(Module) ->
    Source = source_path(Module),
    case regular_source(Source) of
        ok ->
            case compile_override(Module, Source) of
                {ok, Beam, Warnings} ->
                    load_override(Module, Source, Beam, Warnings);
                {error, _} = Error ->
                    Error
            end;
        Error ->
            Error
    end.

-spec rollback(module()) -> {ok, map()} | {error, term()}.
rollback(Module) when is_atom(Module) ->
    with_damage_module(Module, fun() -> rollback_damage_module(Module) end).

rollback_damage_module(Module) ->
    case damage_release_overrides:get(Module) of
        not_found ->
            {error, module_not_overridden};
        {ok, _Meta} ->
            case code:soft_purge(Module) of
                false ->
                    {error, old_code_still_in_use};
                true ->
                    case code:load_file(Module) of
                        {module, Module} ->
                            %% The override is now the old generation. Do not claim
                            %% a pristine runtime until that generation is gone.
                            case code:soft_purge(Module) of
                                true ->
                                    ok = damage_release_overrides:remove(Module),
                                    {ok, #{module => Module, status => rolled_back}};
                                false ->
                                    {error, rollback_loaded_but_override_still_in_use}
                            end;
                        {error, Why} ->
                            {error, {release_beam_reload_failed, Why}}
                    end
            end
    end.

-spec status() -> [map()].
status() ->
    damage_release_overrides:list().

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
            case file:read_link_info(Path) of
                {ok, #file_info{type = regular}} -> {ok, Path};
                {ok, _} -> {error, release_source_not_regular};
                {error, Why} -> {error, {release_source_unavailable, Why}}
            end;
        {error, Why} ->
            {error, {release_source_dir_unavailable, Why}}
    end.

with_damage_module(Module, Fun) ->
    case application:get_key(damage, modules) of
        {ok, Modules} when is_list(Modules) ->
            case lists:member(Module, Modules) of
                true -> Fun();
                false -> {error, {module_not_in_damage_application, Module}}
            end;
        _ ->
            {error, damage_application_modules_unavailable}
    end.

regular_source(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular}} -> ok;
        {ok, _} -> {error, override_source_not_regular};
        {error, enoent} -> {error, {override_source_missing, Path}};
        {error, Why} -> {error, {override_source_stat_failed, Why}}
    end.

compile_override(Module, Source) ->
    Opts = [binary, debug_info, return_errors, return_warnings | include_opts()],
    case compile:noenv_file(Source, Opts) of
        {ok, Module, Beam} ->
            {ok, Beam, []};
        {ok, Module, Beam, Warnings} ->
            {ok, Beam, Warnings};
        {ok, OtherModule, _Beam} ->
            {error, {override_module_name_mismatch, Module, OtherModule}};
        {ok, OtherModule, _Beam, _Warnings} ->
            {error, {override_module_name_mismatch, Module, OtherModule}};
        {error, Errors, Warnings} ->
            {error, {compile_failed, Errors, Warnings}};
        Other ->
            {error, {unexpected_compile_result, Other}}
    end.

include_opts() ->
    case code:lib_dir(damage, include) of
        Dir when is_list(Dir) -> [{i, Dir}];
        _ -> []
    end.

load_override(Module, Source, Beam, Warnings) ->
    BaseMd5 =
        case damage_release_overrides:get(Module) of
            {ok, Existing} -> maps:get(base_module_md5, Existing, module_md5(Module));
            not_found -> module_md5(Module)
        end,
    SourceSha = file_sha256(Source),
    case code:soft_purge(Module) of
        false ->
            {error, old_code_still_in_use};
        true ->
            case code:load_binary(Module, Source, Beam) of
                {module, Module} ->
                    Meta = #{
                        module => Module,
                        source => unicode:characters_to_binary(Source),
                        source_sha256 => SourceSha,
                        beam_sha256 => lower_hex(crypto:hash(sha256, Beam)),
                        base_module_md5 => BaseMd5,
                        loaded_module_md5 => module_md5(Module),
                        loaded_at => erlang:system_time(second)
                    },
                    ok = damage_release_overrides:record(Meta),
                    ?LOG_NOTICE(
                        "Loaded operator override module=~p source_sha256=~s beam_sha256=~s",
                        [Module, maps:get(source_sha256, Meta), maps:get(beam_sha256, Meta)]
                    ),
                    {ok, maps:merge(maps:with(
                        [module, source_sha256, beam_sha256, base_module_md5,
                         loaded_module_md5, loaded_at], Meta),
                        #{warnings => Warnings})};
                {error, Why} ->
                    {error, {hot_code_load_failed, Why}}
            end
    end.

module_md5(Module) ->
    try Module:module_info(md5) of
        Md5 when is_binary(Md5) -> lower_hex(Md5);
        Other -> to_bin(Other)
    catch
        _:_ -> <<>>
    end.

file_sha256(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> lower_hex(crypto:hash(sha256, Bin));
        {error, Why} -> error({override_source_read_failed, Why})
    end.

lower_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
