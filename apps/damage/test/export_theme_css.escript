#!/usr/bin/env escript
%% Compile only the pure theme generator; no applications or services start.
main([Out]) ->
    {ok, damage_theme_manifest, Beam} = compile:file(
        "apps/damage/src/damage_theme_manifest.erl", [binary, report_errors, report_warnings]),
    {module, damage_theme_manifest} = code:load_binary(damage_theme_manifest, "theme", Beam),
    lists:foreach(fun(App) ->
        lists:foreach(fun(Theme) ->
            File = filename:join([Out, binary_to_list(App),
                binary_to_list(maps:get(<<"id">>, Theme)) ++ ".css"]),
            ok = filelib:ensure_dir(File),
            ok = file:write_file(File, damage_theme_manifest:css(App, Theme))
        end, damage_theme_manifest:builtin())
    end, [<<"damage">>, <<"ecai">>, <<"nosternity">>, <<"bop">>]);
main(_) -> io:format(standard_error, "usage: escript apps/damage/test/export_theme_css.escript OUT_DIR~n", []), halt(2).
