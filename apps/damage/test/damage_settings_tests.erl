-module(damage_settings_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

settings_reload_and_persistence_test_() ->
    {timeout, 30, fun run_settings_case/0}.

run_settings_case() ->
    %% Do not run over an existing supervised settings service.
    case whereis(damage_settings) of
        undefined -> with_isolated_config(fun check_settings/2);
        _Pid -> ok
    end.

with_isolated_config(Fun) ->
    Dir = make_temp_dir("damage-settings-test-"),
    Base = filename:join(Dir, "sys.config"),
    Overlay = filename:join(Dir, "sys.dashboard.config"),
    EnvNames = ["DAMAGE_CONFIG_FILE", "DAMAGE_SETTINGS_OVERLAY"],
    OriginalEnv = [{Name, os:getenv(Name)} || Name <- EnvNames],
    Original = [{damage, Key, application:get_env(damage, Key)} ||
                Key <- [settings_config_path, settings_overlay_path,
                        settings_poll_interval_ms, ae_fee_multiplier, l402_price_msat,
                        tax_enabled, tax_cln_owner, tax_data_dir,
                        tax_backfill_on_start, tax_standard_utc_offset_minutes,
                        tax_max_prices_per_backfill, tax_price_pause_ms]] ++
               [{erm, media_enabled, application:get_env(erm, media_enabled)},
                {bop, port, application:get_env(bop, port)}],
    try
        [_ = os:unsetenv(Name) || Name <- EnvNames],
        ok = file:write_file(Base, "[{damage,[{ae_fee_multiplier,2}]},{ecai,[]},{nosternity,[]}].\n"),
        ok = application:set_env(damage, settings_config_path, Base),
        ok = application:set_env(damage, settings_overlay_path, Overlay),
        ok = application:set_env(damage, settings_poll_interval_ms, 60000),
        {ok, Pid} = damage_settings:start_link(),
        try Fun(Base, Overlay)
        after gen_server:stop(Pid) end
    after
        [restore_os_env(Name, Val) || {Name, Val} <- OriginalEnv],
        [restore(App, Key, Value) || {App, Key, Value} <- Original],
        _ = file:del_dir_r(Dir)
    end.

check_settings(Base, Overlay) ->
    {ok, Initial} = damage_settings:get(damage),
    Version0 = maps:get(version, Initial),
    ?assertEqual(list_to_binary(Overlay), maps:get(config_file, Initial)),
    {ok, _} = damage_settings:save(damage, #{<<"ae_fee_multiplier">> => 4}, Version0),
    ?assert(filelib:is_file(Overlay)),
    {ok, #file_info{mode = ConfigMode}} = file:read_file_info(Overlay),
    ?assertEqual(8#600, ConfigMode band 8#777),
    {ok, [[{damage, Saved}]]} = file:consult(Overlay),
    ?assertEqual(4, proplists:get_value(ae_fee_multiplier, Saved)),
    ?assertEqual({ok, 4}, application:get_env(damage, ae_fee_multiplier)),

    {ok, AfterSave} = damage_settings:get(damage),
    Version1 = maps:get(version, AfterSave),
    ?assertMatch({error, {conflict, _}},
                 damage_settings:save(damage, #{<<"ae_fee_multiplier">> => 5}, Version0)),
    ?assertMatch({error, {not_editable, _}},
                 damage_settings:save(damage, #{<<"node_admins">> => [<<"ak_x">>]}, Version1)),

    %% Manual sys.config edits take effect for unoverridden fields.
    ok = file:write_file(Base,
         "[{damage,[{ae_fee_multiplier,3},{l402_price_msat,1000}]},{ecai,[]},{nosternity,[]}].\n"),
    {ok, _} = damage_settings:reload(),
    ?assertEqual({ok, 4}, application:get_env(damage, ae_fee_multiplier)),
    ?assertEqual({ok, 1000}, application:get_env(damage, l402_price_msat)),
    {ok, Status} = damage_settings:status(),
    ?assert(lists:member(<<"damage.l402_price_msat">>, maps:get(pending_restart, Status))),

    %% Invalid external configuration must not replace last known good.
    ok = file:write_file(Base, <<"this is not a valid Erlang config file\n">>),
    ?assertMatch({error, _}, damage_settings:reload()),
    ?assertEqual({ok, 4}, application:get_env(damage, ae_fee_multiplier)),

    ok = file:write_file(Base,
         "[{damage,[{ae_fee_multiplier,3},{l402_price_msat,1000}]},{ecai,[]},{nosternity,[]}].\n"),
    {ok, _} = damage_settings:reload(),
    {ok, Fresh} = damage_settings:get(damage),
    {ok, _} = damage_settings:reset(damage, [<<"ae_fee_multiplier">>], maps:get(version, Fresh)),
    ?assertEqual({ok, 3}, application:get_env(damage, ae_fee_multiplier)),

    %% Newly discovered applications use the same transactional overlay.
    {ok, B0} = damage_settings:get(bop),
    {ok, _} = damage_settings:save(bop, #{<<"port">> => 8099}, maps:get(version, B0)),
    ?assertEqual({ok, 8099}, application:get_env(bop, port)),
    {ok, E0} = damage_settings:get(erm),
    {ok, _} = damage_settings:save(erm, #{<<"media_enabled">> => false},
                                   maps:get(version, E0)),
    ?assertEqual({ok, false}, application:get_env(erm, media_enabled)),
    {ok, _} = damage_settings:get(erm),

    %% Reject impossible Nosternity default/max combinations before persisting.
    {ok, N0} = damage_settings:get(nosternity),
    ?assertMatch({error, {invalid_setting_combination, nosternity, _, _}},
        damage_settings:save(nosternity, #{<<"search_default_limit">> => 300},
                             maps:get(version, N0))),
    {ok, N1} = damage_settings:get(nosternity),
    ?assertEqual(maps:get(version, N0), maps:get(version, N1)),

    %% The UI must be able to enable and configure tax in ONE versioned save.
    %% Enabling without an explicit owner is refused before writing the file.
    {ok, Tax0} = damage_settings:get(damage),
    TaxVersion = maps:get(version, Tax0),
    ?assertMatch({error, {invalid_setting_combination, damage,
                           tax_enabled, tax_cln_owner}},
        damage_settings:save(damage, #{<<"tax_enabled">> => true}, TaxVersion)),
    {ok, TaxUnchanged} = damage_settings:get(damage),
    ?assertEqual(TaxVersion, maps:get(version, TaxUnchanged)),
    TaxOwner = <<"ak_22222222222222222222222222222222222222222222222222222">>,
    BeforeEnable = application:get_env(damage, tax_enabled),
    BeforeOwner = application:get_env(damage, tax_cln_owner),
    BeforeDir = application:get_env(damage, tax_data_dir),
    {ok, _} = damage_settings:save(damage, #{
        <<"tax_enabled">> => true,
        <<"tax_cln_owner">> => TaxOwner,
        <<"tax_data_dir">> => <<"/tmp/damage-tax-private">>,
        <<"tax_backfill_on_start">> => false,
        <<"tax_standard_utc_offset_minutes">> => 600,
        <<"tax_max_prices_per_backfill">> => 125,
        <<"tax_price_pause_ms">> => 100
    }, TaxVersion),
    %% Lifecycle fields are persisted but not hot-published over a running
    %% journal; this also keeps the tax link hidden until the restart.
    ?assertEqual(BeforeEnable, application:get_env(damage, tax_enabled)),
    ?assertEqual(BeforeOwner, application:get_env(damage, tax_cln_owner)),
    ?assertEqual(BeforeDir, application:get_env(damage, tax_data_dir)),
    %% Price budgets are safe to publish while the node is running.
    ?assertEqual({ok, 125}, application:get_env(damage, tax_max_prices_per_backfill)),
    {ok, TaxSaved} = damage_settings:get(damage),
    ?assert(lists:member(<<"damage.tax_enabled">>, maps:get(pending_restart, TaxSaved))),
    ?assert(lists:member(<<"damage.tax_cln_owner">>, maps:get(pending_restart, TaxSaved))),
    [TaxField] = [F || F <- maps:get(fields, TaxSaved),
                      maps:get(name, F) =:= <<"tax_cln_owner">>],
    ?assertEqual(TaxOwner, maps:get(value, TaxField)),
    ?assertEqual(<<"damage.config">>, maps:get(source, TaxField)),
    {ok, [AppTerms]} = file:consult(Overlay),
    TaxProps = proplists:get_value(damage, AppTerms),
    ?assertEqual(TaxOwner, proplists:get_value(tax_cln_owner, TaxProps)),
    ?assert(is_binary(proplists:get_value(tax_cln_owner, TaxProps))),
    %% Simulate the next node start: bootstrap applies the saved restart
    %% fields before damage_sup creates the tax journal and jobs children.
    ok = damage_settings:bootstrap(),
    ?assertEqual({ok, true}, application:get_env(damage, tax_enabled)),
    ?assertEqual({ok, TaxOwner}, application:get_env(damage, tax_cln_owner)),
    ?assertEqual({ok, "/tmp/damage-tax-private"}, application:get_env(damage, tax_data_dir)),
    %% An enabled tax service may not lose its CLN ownership binding.
    ?assertMatch({error, {invalid_setting_combination, damage,
                           tax_enabled, tax_cln_owner}},
        damage_settings:reset(damage, [<<"tax_cln_owner">>], maps:get(version, TaxSaved))),
    ?assertEqual({ok, TaxOwner}, application:get_env(damage, tax_cln_owner)).

restore(App, Key, {ok, Value}) -> application:set_env(App, Key, Value);
restore(App, Key, undefined) -> application:unset_env(App, Key).

%% Verify standard XDG path resolution and the HOME fallback; relative
%% XDG_CONFIG_HOME is not allowed to redirect node settings into the cwd.
xdg_path_resolution_test() ->
    Original = [{Name, os:getenv(Name)} || Name <- ["XDG_CONFIG_HOME", "HOME"]],
    try
        _ = os:putenv("HOME", "/tmp/damage-xdg-test-home"),
        _ = os:putenv("XDG_CONFIG_HOME", "/tmp/damage-xdg-test-config"),
        ?assertEqual("/tmp/damage-xdg-test-config/damage/damage.config",
                     damage_config:dashboard_config_path()),
        _ = os:putenv("XDG_CONFIG_HOME", "relative-dir"),
        ?assertEqual("/tmp/damage-xdg-test-home/.config/damage/damage.config",
                     damage_config:dashboard_config_path()),
        _ = os:unsetenv("XDG_CONFIG_HOME"),
        ?assertEqual("/tmp/damage-xdg-test-home/.config/damage/damage.config",
                     damage_config:dashboard_config_path())
    after
        [restore_os_env(Name, Val) || {Name, Val} <- Original]
    end.

xdg_initialization_and_legacy_migration_test_() ->
    {timeout, 30, fun() ->
        case whereis(damage_settings) of
            undefined -> run_xdg_initialization_and_legacy_migration();
            _ -> ok
        end
    end}.

run_xdg_initialization_and_legacy_migration() ->
    Dir = make_temp_dir("damage-xdg-migration-"),
    Base = filename:join(Dir, "sys.config"),
    Legacy = filename:join(Dir, "sys.dashboard.config"),
    Xdg = filename:join(Dir, "xdg"),
    Managed = filename:join([Xdg, "damage", "damage.config"]),
    Vars = ["XDG_CONFIG_HOME", "HOME", "DAMAGE_CONFIG_FILE", "DAMAGE_SETTINGS_OVERLAY"],
    OriginalEnv = [{Name, os:getenv(Name)} || Name <- Vars],
    Keys = [settings_config_path, settings_overlay_path, settings_poll_interval_ms,
            ae_fee_multiplier],
    OriginalApps = [{damage, Key, application:get_env(damage, Key)} || Key <- Keys],
    try
        _ = os:putenv("XDG_CONFIG_HOME", Xdg),
        _ = os:putenv("HOME", Dir),
        _ = os:unsetenv("DAMAGE_CONFIG_FILE"),
        _ = os:unsetenv("DAMAGE_SETTINGS_OVERLAY"),
        ok = application:unset_env(damage, settings_overlay_path),
        ok = application:set_env(damage, settings_config_path, Base),
        ok = application:set_env(damage, settings_poll_interval_ms, 60000),
        ok = file:write_file(Base, "[{damage,[{ae_fee_multiplier,2}]}].\n"),
        ok = file:write_file(Legacy, "[{damage,[{ae_fee_multiplier,7}]}].\n"),
        ?assertEqual(Managed, damage_settings:overlay_path()),
        {ok, Pid} = damage_settings:start_link(),
        try
            ?assertEqual({ok, 7}, application:get_env(damage, ae_fee_multiplier)),
            {ok, [[{damage, OldSettings}]]} = file:consult(Managed),
            ?assertEqual(7, proplists:get_value(ae_fee_multiplier, OldSettings)),
            ?assert(filelib:is_file(Legacy)),
            {ok, #file_info{mode = ConfigMode}} = file:read_file_info(Managed),
            ?assertEqual(8#600, ConfigMode band 8#777),
            {ok, #file_info{mode = DirMode}} = file:read_file_info(filename:dirname(Managed)),
            ?assertEqual(8#700, DirMode band 8#777),
            {ok, State0} = damage_settings:get(damage),
            ?assertEqual(list_to_binary(Managed), maps:get(config_file, State0)),
            [Fee] = [F || F <- maps:get(fields, State0),
                          maps:get(name, F) =:= <<"ae_fee_multiplier">>],
            ?assertEqual(<<"damage.config">>, maps:get(source, Fee)),
            {ok, _} = damage_settings:save(damage, #{<<"ae_fee_multiplier">> => 5},
                                            maps:get(version, State0)),
            {ok, [[{damage, Updated}]]} = file:consult(Managed),
            ?assertEqual(5, proplists:get_value(ae_fee_multiplier, Updated)),
            {ok, [[{damage, OldSettingsAgain}]]} = file:consult(Legacy),
            ?assertEqual(7, proplists:get_value(ae_fee_multiplier, OldSettingsAgain))
        after gen_server:stop(Pid) end
    after
        [restore_os_env(Name, Val) || {Name, Val} <- OriginalEnv],
        [restore(App, Key, Value) || {App, Key, Value} <- OriginalApps],
        _ = file:del_dir_r(Dir)
    end.


make_temp_dir(Prefix) ->
    Root = os:getenv("TMPDIR", "/tmp"),
    Suffix =
        integer_to_list(erlang:system_time(microsecond)) ++ "-" ++
            integer_to_list(erlang:unique_integer([positive, monotonic])),
    Dir = filename:join(Root, Prefix ++ Suffix),
    case file:make_dir(Dir) of
        ok -> Dir;
        {error, eexist} -> make_temp_dir(Prefix)
    end.

restore_os_env(Name, false) -> os:unsetenv(Name);
restore_os_env(Name, Value) -> os:putenv(Name, Value).
