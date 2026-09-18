%%%-------------------------------------------------------------------
%%% Node-admin-only BDD adapter for controlled DamageBDD hot-code reloads.
%%% Operators edit files in damage_hotcode:source_dir/0; these steps only
%%% prepare, compile/load and roll back those files.
%%%-------------------------------------------------------------------
-module(steps_hotcode).
-damage_roles([node_admin]).

-export([step/6, step_dry/6]).

step_dry(Config, Context, Keyword, LineNo, Body, Args) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

step(
    _Config,
    Context,
    _Keyword,
    _LineNo,
    ["I prepare operator source for module", Module0],
    _Body
) ->
    with_module(Context, Module0, fun(Module) ->
        case damage_hotcode:prepare(Module) of
            {ok, Status, Path} ->
                Context#{
                    hotcode_module => atom_to_binary(Module, utf8),
                    hotcode_prepare_status => Status,
                    hotcode_source => unicode:characters_to_binary(Path)
                };
            {error, Why} ->
                fail(Context, {hotcode_prepare_failed, Module, Why})
        end
    end);
step(
    _Config,
    Context,
    _Keyword,
    _LineNo,
    ["I reload operator module", Module0],
    _Body
) ->
    with_module(Context, Module0, fun(Module) ->
        case damage_hotcode:reload(Module) of
            {ok, Meta} ->
                Context#{hotcode_module => atom_to_binary(Module, utf8), hotcode_reload => Meta};
            {error, Why} ->
                fail(Context, {hotcode_reload_failed, Module, Why})
        end
    end);
step(
    _Config,
    Context,
    _Keyword,
    _LineNo,
    ["I rollback operator module", Module0],
    _Body
) ->
    with_module(Context, Module0, fun(Module) ->
        case damage_hotcode:rollback(Module) of
            {ok, Meta} ->
                Context#{hotcode_module => atom_to_binary(Module, utf8), hotcode_rollback => Meta};
            {error, Why} ->
                fail(Context, {hotcode_rollback_failed, Module, Why})
        end
    end);
step(
    _Config,
    Context,
    _Keyword,
    _LineNo,
    ["operator module", Module0, "should be overridden"],
    _Body
) ->
    with_module(Context, Module0, fun(Module) ->
        case damage_release_overrides:get(Module) of
            {ok, _} -> Context;
            not_found -> fail(Context, {hotcode_module_not_overridden, Module})
        end
    end).

with_module(Context, Module0, Fun) ->
    case existing_module(Module0) of
        {ok, Module} -> Fun(Module);
        {error, Why} -> fail(Context, Why)
    end.

existing_module(Module0) ->
    Bin = to_bin(Module0),
    try binary_to_existing_atom(Bin, utf8) of
        Module when is_atom(Module) -> {ok, Module}
    catch
        _:_ -> {error, {unknown_hotcode_module, Bin}}
    end.

fail(Context, Reason) ->
    maps:put(fail, damage_utils:strf("Hot code operation failed: ~p", [Reason]), Context).

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
