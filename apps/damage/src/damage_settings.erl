%%%-------------------------------------------------------------------
%%% Runtime node configuration service for damage/ecai/nosternity/erm/bop.
%%%
%%% - Watches the operator's sys.config and XDG damage.config settings.
%%% - Only explicit, non-secret fields are editable / hot-published.
%%% - Persists dashboard overrides atomically; never rewrites sys.config.
%%% - Keeps last known good settings on malformed input.
%%% - Does not restart Erlang applications or OTP children automatically.
%%%-------------------------------------------------------------------
-module(damage_settings).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-export([start_link/0, bootstrap/0, reload/0, status/0,
         get/1, save/3, reset/3, sys_config_path/0, overlay_path/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DEFAULT_POLL_MS, 2000).
-define(MAX_CONFIG_BYTES, 4 * 1024 * 1024).
-define(MAX_OVERLAY_BYTES, 512 * 1024).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Should be called from damage_app:start/2 BEFORE starting the main supervisor.
%% This loads dashboard overrides early enough for subsequently started children.
%% If the file is missing or invalid, startup is NOT blocked: the dashboard will
%% report the error, and the operator can repair the configuration.
bootstrap() ->
    case ensure_managed_config(sys_config_path(), overlay_path()) of
        ok -> bootstrap_snapshot();
        {error, Why} ->
            ?LOG_WARNING("Settings bootstrap could not initialize damage.config: ~p", [Why]),
            ok
    end.

bootstrap_snapshot() ->
    case snapshot(sys_config_path(), overlay_path()) of
        {ok, Snap} ->
            case publish(Snap, #{}, true) of
                {ok, _} -> ok;
                {error, PublishWhy} ->
                    ?LOG_WARNING("Settings bootstrap could not publish settings: ~p", [PublishWhy]),
                    ok
            end;
        {error, BootstrapWhy} ->
            ?LOG_WARNING("Settings bootstrap skipped: ~p", [BootstrapWhy]),
            ok
    end.

reload() -> gen_server:call(?MODULE, reload, 30000).
status() -> gen_server:call(?MODULE, status, 5000).
get(App) -> gen_server:call(?MODULE, {get, App}, 5000).
save(App, Changes, Version) ->
    gen_server:call(?MODULE, {save, App, Changes, Version}, 30000).
reset(App, Names, Version) ->
    gen_server:call(?MODULE, {reset, App, Names, Version}, 30000).

sys_config_path() -> damage_config:system_config_path().

%% New deployments use $XDG_CONFIG_HOME/damage/damage.config, falling back to
%% $HOME/.config/damage/damage.config.  Keep explicitly configured legacy
%% paths working.  The path names the dashboard-managed *overlay*, not the
%% operator's /etc/damage/damage.config passed to -config.
overlay_path() ->
    case config_file_env("DAMAGE_CONFIG_FILE") of
        {ok, Path} -> Path;
        missing ->
            case config_file_env("DAMAGE_SETTINGS_OVERLAY") of
                {ok, LegacyExplicit} -> LegacyExplicit;
                missing ->
                    case application:get_env(damage, settings_overlay_path) of
                        {ok, AppPath} when is_list(AppPath); is_binary(AppPath) ->
                            damage_config:normalize_path(AppPath);
                        _ -> damage_config:dashboard_config_path()
                    end
            end
    end.

config_file_env(Name) ->
    case os:getenv(Name) of
        Path when is_list(Path), Path =/= "" ->
            {ok, damage_config:normalize_path(Path)};
        _ -> missing
    end.

init([]) ->
    Poll0 = application:get_env(damage, settings_poll_interval_ms, ?DEFAULT_POLL_MS),
    Poll = case Poll0 of N when is_integer(N), N >= 500, N =< 60000 -> N;
                         _ -> ?DEFAULT_POLL_MS end,
    Base = sys_config_path(),
    Overlay = overlay_path(),
    S0 = #{base_path => Base, overlay_path => Overlay, poll_ms => Poll,
           snapshot => undefined, version => undefined, pending => [],
           last_error => none, loaded_at => undefined},
    S1 = case ensure_managed_config(Base, Overlay) of
        ok -> load_snapshot(S0, false);
        {error, Reason} -> S0#{last_error => Reason}
    end,
    schedule(Poll),
    {ok, S1}.

handle_call(status, _From, S) -> {reply, {ok, status_map(S)}, S};
handle_call({get, App0}, _From, S) ->
    Reply = case damage_settings_schema:normalize_app(App0) of
        {ok, App} -> app_view(App, S);
        Error -> Error
    end,
    {reply, Reply, S};
handle_call(reload, _From, S) ->
    S1 = load_snapshot(S, true),
    Reply = case maps:get(last_error, S1) of
        none -> {ok, status_map(S1)};
        Why -> {error, Why}
    end,
    {reply, Reply, S1};
handle_call({save, App0, Changes, Version}, _From, S) ->
    {Reply, S1} = mutate(save, App0, Changes, Version, S),
    {reply, Reply, S1};
handle_call({reset, App0, Names, Version}, _From, S) ->
    {Reply, S1} = mutate(reset, App0, Names, Version, S),
    {reply, Reply, S1};
handle_call(_, _From, S) -> {reply, {error, bad_call}, S}.

handle_cast(_, S) -> {noreply, S}.
handle_info(poll, S) ->
    S1 = load_snapshot(S, false),
    schedule(maps:get(poll_ms, S1)),
    {noreply, S1};
handle_info(_, S) -> {noreply, S}.
terminate(_Reason, _S) -> ok.
code_change(_OldVersion, S, _Extra) -> {ok, S}.

schedule(Ms) -> erlang:send_after(Ms, self(), poll).

load_snapshot(S, Force) ->
    case snapshot(maps:get(base_path, S), maps:get(overlay_path, S)) of
        {ok, NewSnap} ->
            Version = maps:get(version, NewSnap),
            case {Force, maps:get(version, S, undefined) =:= Version} of
                {false, true} -> S#{last_error => none};
                _ ->
                    OldSnap = maps:get(snapshot, S),
                    case publish(NewSnap, old_effective(OldSnap), false) of
                        {ok, Changed} ->
                            Cold = [<< (atom_to_binary(App, utf8))/binary, ".", Name/binary >>
                                    || {App, Name, restart} <- Changed],
                            Pending = ordsets:union(maps:get(pending, S), ordsets:from_list(Cold)),
                            ?LOG_INFO("System settings reloaded, ~B fields updated, ~B restart-requiring changes",
                                      [length(Changed), length(Cold)]),
                            S#{snapshot => NewSnap, version => Version, pending => Pending,
                               loaded_at => erlang:system_time(second), last_error => none};
                        {error, PublishWhy} -> S#{last_error => PublishWhy}
                    end
            end;
        {error, ReadWhy} ->
            case maps:get(last_error, S) of
                ReadWhy -> ok;
                _ -> ?LOG_WARNING("System settings file reload rejected: ~p", [ReadWhy])
            end,
            S#{last_error => ReadWhy}
    end.

old_effective(undefined) -> #{};
old_effective(Snap) -> maps:get(effective, Snap).

%% Transactionally publish application env changes and roll back on error.
publish(Snap, Old, Boot) ->
    New = maps:get(effective, Snap),
    Tasks = [
        {App, Key, maps:get(Key, maps:get(App, New), '$unset'), maps:get(apply, F)}
        || App <- damage_settings_schema:apps(),
           F <- damage_settings_schema:fields(App),
           Key <- [maps:get(key, F)],
           should_publish(App, Key, New, Old, Boot)
    ],
    publish_tasks(Tasks, [], [], Boot).

should_publish(App, Key, New, _Old, true) ->
    maps:is_key(Key, maps:get(App, New));
should_publish(App, Key, New, Old, false) when map_size(Old) =:= 0 ->
    %% Initial loading MUST NOT unset app defaults that were never mentioned in
    %% sys.config. Only override keys which explicitly exist on disk.
    case maps:find(Key, maps:get(App, New)) of
        error -> false;
        {ok, Wanted} ->
            case application:get_env(App, Key) of
                {ok, Wanted} -> false;
                _ -> true
            end
    end;
should_publish(App, Key, New, Old, false) ->
    maps:get(Key, maps:get(App, New), '$unset') =/=
        maps:get(Key, maps:get(App, Old, #{}), '$unset').

publish_tasks([], _Undo, Changes, _Boot) -> {ok, lists:reverse(Changes)};
publish_tasks([{App, Key, NewValue, Apply} | Rest], Undo, Changes, Boot) ->
    OldEnv = application:get_env(App, Key),
    Result = case NewValue of
        '$unset' -> application:unset_env(App, Key);
        _ -> application:set_env(App, Key, NewValue)
    end,
    case Result of
        ok ->
            %% An application may already have been running at first load.
            %% Bootstrap is the only mode allowed to skip restart tracking.
            Change = {App, atom_to_binary(Key, utf8),
                      case Boot of true -> hot; false -> Apply end},
            publish_tasks(Rest, [{App, Key, OldEnv} | Undo], [Change | Changes], Boot);
        Error ->
            rollback(Undo),
            {error, {publish_failed, App, Key, Error}}
    end.

rollback([{App, Key, {ok, V}} | Rest]) ->
    _ = application:set_env(App, Key, V), rollback(Rest);
rollback([{App, Key, undefined} | Rest]) ->
    _ = application:unset_env(App, Key), rollback(Rest);
rollback([]) -> ok.

mutate(_Action, _App0, _Payload, _Version, #{snapshot := undefined} = S) ->
    {{error, configuration_not_loaded}, S};
mutate(Action, App0, Payload, Version, S) when is_binary(Version) ->
    case damage_settings_schema:normalize_app(App0) of
        {ok, App} -> mutate_valid(Action, App, Payload, Version, S);
        Error -> {Error, S}
    end;
mutate(_, _, _, _, S) -> {{error, missing_or_invalid_version}, S}.

mutate_valid(Action, App, Payload, Version, S) ->
    %% Check disk NOW, not only the last polling interval. This stops stale UI
    %% saves from overwriting changes made through SSH or another browser.
    case snapshot(maps:get(base_path, S), maps:get(overlay_path, S)) of
        {ok, Current} ->
            DiskVersion = maps:get(version, Current),
            case {Version =:= maps:get(version, S), Version =:= DiskVersion} of
                {true, true} -> mutate_current(Action, App, Payload, S, Current);
                _ -> {{error, {conflict, DiskVersion}}, S}
            end;
        {error, Reason} -> {{error, Reason}, S}
    end.

mutate_current(save, App, Changes, S, Snap) ->
    case damage_settings_schema:decode_changes(App, Changes) of
        {ok, []} -> {{ok, status_map(S)}, S};
        {ok, Pairs} ->
            Overlay0 = maps:get(overlay, Snap),
            AppOverride = maps:get(App, Overlay0),
            Overlay = maps:put(App, maps:merge(AppOverride, maps:from_list(Pairs)), Overlay0),
            persist_and_reload(Overlay, S);
        Error -> {Error, S}
    end;
mutate_current(reset, App, Names, S, Snap) when is_list(Names), length(Names) =< 100 ->
    case checked_names(App, Names, []) of
        {ok, Keys} ->
            Overlay0 = maps:get(overlay, Snap),
            Override1 = maps:without(Keys, maps:get(App, Overlay0)),
            persist_and_reload(maps:put(App, Override1, Overlay0), S);
        Error -> {Error, S}
    end;
mutate_current(_, _, _, S, _) -> {{error, invalid_payload}, S}.

checked_names(_App, [], Acc) -> {ok, lists:reverse(Acc)};
checked_names(App, [N | Ns], Acc) when is_binary(N) ->
    case damage_settings_schema:field(App, N) of
        {ok, F} -> checked_names(App, Ns, [maps:get(key, F) | Acc]);
        Error -> Error
    end;
checked_names(_, _, _) -> {error, invalid_key_type}.

persist_and_reload(Overlay, S) ->
    %% Reject invalid combinations BEFORE writing a persistent override.
    %% After the write, keep the last published environment on reload error.
    Base = maps:get(base, maps:get(snapshot, S)),
    Effective = maps:from_list([{A, maps:merge(maps:get(A, Base), maps:get(A, Overlay))}
                                || A <- damage_settings_schema:apps()]),
    case damage_settings_schema:validate_effective(Effective) of
        ok ->
            case write_overlay(maps:get(overlay_path, S), Overlay) of
                ok ->
                    S1 = load_snapshot(S, true),
                    case maps:get(last_error, S1) of
                        none -> {{ok, status_map(S1)}, S1};
                        Error -> {{error, Error}, S1}
                    end;
                Error -> {Error, S}
            end;
        {error, Reason} -> {{error, Reason}, S}
    end.

app_view(_App, #{snapshot := undefined} = S) ->
    {error, {configuration_not_loaded, maps:get(last_error, S)}};
app_view(App, S) ->
    Snap = maps:get(snapshot, S),
    Override = maps:get(App, maps:get(overlay, Snap)),
    Effective = maps:get(App, maps:get(effective, Snap)),
    Fields = [view_field(App, F, Override, Effective) ||
              F <- damage_settings_schema:fields(App)],
    Editable = maps:from_list([{maps:get(name, F), true} || F <- Fields]),
    %% The static audit catalog is NAMES-ONLY. Never pass unknown environment
    %% values to the dashboard, including values of protected identity keys.
    Discovered = [#{name => Name,
                    group => damage_settings_catalog:group(App, Name),
                    restriction => damage_settings_catalog:restriction(App, Name)}
                  || Name <- damage_settings_catalog:known(App),
                     not maps:is_key(Name, Editable)],
    {ok, #{app => atom_to_binary(App, utf8), fields => Fields,
           groups => damage_settings_catalog:groups(App),
           discovered => Discovered,
           version => maps:get(version, S),
           config_file => to_binary(maps:get(overlay_path, S)),
           pending_restart => pending_for(App, maps:get(pending, S)),
           last_error => error_json(maps:get(last_error, S))}}.

pending_for(App, Pending) ->
    Prefix = atom_to_binary(App, utf8),
    [P || P <- Pending,
          case binary:split(P, <<".">>) of [Prefix, _] -> true; _ -> false end].

view_field(App, F, Override, Effective) ->
    Key = maps:get(key, F),
    {Value, Source} = case maps:find(Key, Effective) of
        {ok, DashboardVal} when is_map_key(Key, Override) ->
            {DashboardVal, <<"damage.config">>};
        {ok, FileVal} -> {FileVal, <<"startup -config">>};
        error ->
            case application:get_env(App, Key) of
                {ok, EnvVal} -> {EnvVal, <<"application">>};
                undefined -> {undefined, <<"unset">>}
            end
    end,
    Public = case Value of
        undefined -> null;
        _ ->
            case damage_settings_schema:public_value(F, Value) of
                {ok, V0} -> V0;
                _ -> null
            end
    end,
    BaseField = #{name => atom_to_binary(Key, utf8), label => maps:get(label, F),
                  group => maps:get(group, F),
                  type => atom_to_binary(maps:get(type, F), utf8),
                  apply => atom_to_binary(maps:get(apply, F), utf8),
                  value => Public, source => Source,
                  overridden => maps:is_key(Key, Override)},
    case maps:get(type, F) of
        integer -> BaseField#{min => maps:get(min, F), max => maps:get(max, F)};
        parallelism -> BaseField#{min => maps:get(min, F), max => maps:get(max, F)};
        _ -> BaseField
    end.

status_map(S) ->
    #{config_file => to_binary(maps:get(overlay_path, S)),
      version => case maps:get(version, S) of undefined -> null; Version -> Version end,
      pending_restart => maps:get(pending, S),
      loaded_at => case maps:get(loaded_at, S) of undefined -> null; LoadedAt -> LoadedAt end,
      last_error => error_json(maps:get(last_error, S))}.

error_json(none) -> null;
error_json(Other) -> to_binary(io_lib:format("~p", [Other])).

snapshot(BasePath, OverlayPath) ->
    case read_config(BasePath, ?MAX_CONFIG_BYTES, required) of
        {ok, BaseTerms, BaseRaw} ->
            case read_config(OverlayPath, ?MAX_OVERLAY_BYTES, optional) of
                {ok, OverlayTerms, OverlayRaw} ->
                    case {extract(BaseTerms, base), extract(OverlayTerms, overlay)} of
                        {{ok, Base}, {ok, Overlay}} ->
                            Effective = maps:from_list([
                                {A, maps:merge(maps:get(A, Base), maps:get(A, Overlay))}
                                || A <- damage_settings_schema:apps()]),
                            Digest = crypto:hash(sha256,
                                                 <<BaseRaw/binary, 0, OverlayRaw/binary>>),
                            case damage_settings_schema:validate_effective(Effective) of
                                ok ->
                                    {ok, #{base => Base, overlay => Overlay,
                                           effective => Effective,
                                           version => binary:encode_hex(Digest)}};
                                {error, Constraint} -> {error, Constraint}
                            end;
                        {{error, SysWhy}, _} -> {error, {invalid_sys_config, SysWhy}};
                        {_, {error, DashboardWhy}} ->
                            {error, {invalid_dashboard_overlay, DashboardWhy}}
                    end;
                {error, OverlayWhy} -> {error, {overlay_read_failed, OverlayWhy}}
            end;
        {error, SysFileWhy} -> {error, {sys_config_read_failed, SysFileWhy}}
    end.

read_config(Path, Max, Mode) ->
    case file:read_link_info(Path) of
        {error, enoent} when Mode =:= optional -> {ok, [], <<>>};
        {ok, #file_info{type = symlink}} when Mode =:= optional ->
            {error, overlay_symlink_forbidden};
        {ok, #file_info{type = symlink}} ->
            read_config_follow_symlink(Path, Max);
        {ok, #file_info{type = regular, size = Size}} when Size =< Max ->
            case file:read_file(Path) of
                {ok, Binary} when byte_size(Binary) =< Max ->
                    consult_checked(Path, Binary);
                {ok, _} -> {error, config_too_large};
                {error, FileReadWhy} -> {error, FileReadWhy}
            end;
        {ok, #file_info{type = regular}} -> {error, config_too_large};
        {ok, _} -> {error, not_regular_file};
        {error, FileInfoWhy} -> {error, FileInfoWhy}
    end.

read_config_follow_symlink(Path, Max) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} when Size =< Max ->
            case file:read_file(Path) of
                {ok, Binary} when byte_size(Binary) =< Max ->
                    consult_checked(Path, Binary);
                _ -> {error, unreadable_config_symlink}
            end;
        _ -> {error, invalid_config_symlink_target}
    end.

%% Ensure parsing and version hashing refer to identical file contents.
consult_checked(Path, FirstRead) ->
    case file:consult(Path) of
        {ok, [Terms]} when is_list(Terms) ->
            case file:read_file(Path) of
                {ok, FirstRead} -> {ok, Terms, FirstRead};
                _ -> {error, config_changed_during_read}
            end;
        {ok, _Other} -> {error, not_an_erlang_app_config_list};
        {error, _ParseWhy} -> {error, invalid_erlang_config_syntax}
    end.

extract(Terms, Kind) ->
    Apps = damage_settings_schema:apps(),
    case lists:all(fun(E) -> is_tuple(E) andalso tuple_size(E) =:= 2 end, Terms) of
        false -> {error, not_an_application_list};
        true ->
            Relevant = [{A, Props} || {A, Props} <- Terms, lists:member(A, Apps)],
            Unique = lists:usort([A || {A, _} <- Relevant]),
            case length(Unique) =:= length(Relevant) of
                false -> {error, duplicate_application_entry};
                true -> extract_apps(Apps, Relevant, Kind, #{})
            end
    end.

extract_apps([], _Relevant, _Kind, Acc) -> {ok, Acc};
extract_apps([App | Rest], Relevant, Kind, Acc) ->
    Props = proplists:get_value(App, Relevant, []),
    case is_list(Props) andalso
         lists:all(fun(E) -> is_tuple(E) andalso tuple_size(E) =:= 2 andalso
                             is_atom(element(1, E)) end, Props) of
        false -> {error, {malformed_application_environment, App}};
        true ->
            Keys = [K || {K, _} <- Props],
            case length(Keys) =:= length(lists:usort(Keys)) of
                false -> {error, {duplicate_environment_key, App}};
                true ->
                    case extract_props(App, Props, Kind, #{}) of
                        {ok, Values} -> extract_apps(Rest, Relevant, Kind, Acc#{App => Values});
                        Error -> Error
                    end
            end
    end.

extract_props(_App, [], _Kind, Acc) -> {ok, Acc};
extract_props(App, [{Key, Val} | Rest], Kind, Acc) ->
    case damage_settings_schema:field(App, Key) of
        {ok, _Field} ->
            case damage_settings_schema:decode_existing(App, Key, Val) of
                {ok, Valid} -> extract_props(App, Rest, Kind, Acc#{Key => Valid});
                {error, Why} -> {error, {invalid_field, App, Key, Why}}
            end;
        {error, _} when Kind =:= base ->
            %% Other operator-managed env entries are intentionally left alone.
            extract_props(App, Rest, Kind, Acc);
        {error, _} -> {error, {non_editable_override, App, Key}}
    end.

%% Ensure the XDG file exists before bootstrap or node start.  On upgrade,
%% import the old adjacent sys.dashboard.config once, only if the new XDG
%% file is absent.  Never modify the legacy source file or a pre-existing
%% damage.config.  Explicitly configured overlay paths do not auto-migrate.
ensure_managed_config(Base, Path) ->
    case same_config_path(Base, Path) of
        true -> {error, managed_config_must_not_be_operator_config};
        false -> ensure_distinct_managed_config(Base, Path)
    end.

same_config_path(Base, Path) when Base =:= Path -> true;
same_config_path(Base, Path) ->
    %% An explicit overlay path may accidentally reference the VM -config
    %% through a symlink.  Never allow a dashboard save to replace that file.
    try
        case {filelib:realpath(Base), filelib:realpath(Path)} of
            {Real, Real} when is_list(Real) -> true;
            {Real, Real} when is_binary(Real) -> true;
            _ -> false
        end
    catch _:_ -> false end.

ensure_distinct_managed_config(Base, Path) ->
    case ensure_overlay_dir(Path) of
        ok ->
            case file:read_link_info(Path) of
                {ok, #file_info{type = regular, mode = Mode}}
                  when Mode band 8#022 =:= 0 -> ok;
                {ok, #file_info{type = regular}} -> {error, unsafe_managed_config_permissions};
                {ok, #file_info{type = symlink}} -> {error, managed_config_symlink_forbidden};
                {ok, _} -> {error, managed_config_not_regular_file};
                {error, enoent} -> initialize_managed_config(Base, Path);
                {error, Reason} -> {error, {managed_config_stat_failed, Reason}}
            end;
        Error -> Error
    end.

initialize_managed_config(Base, Path) ->
    Legacy = filename:rootname(Base, ".config") ++ ".dashboard.config",
    DefaultPath = damage_config:dashboard_config_path(),
    case Path =:= DefaultPath andalso Legacy =/= Path of
        true ->
            case file:read_link_info(Legacy) of
                {error, enoent} -> create_managed_config(Path, empty_overrides());
                {ok, #file_info{type = regular}} -> migrate_legacy(Base, Legacy, Path);
                {ok, _} -> {error, legacy_overlay_not_regular_file};
                {error, Why} -> {error, {legacy_overlay_stat_failed, Why}}
            end;
        false -> create_managed_config(Path, empty_overrides())
    end.

migrate_legacy(Base, Legacy, Destination) ->
    %% Snapshot validates syntax, application names, editable keys, values and
    %% cross-field constraints before anything is copied to the new location.
    case snapshot(Base, Legacy) of
        {ok, Snap} ->
            case create_managed_config(Destination, maps:get(overlay, Snap)) of
                ok ->
                    ?LOG_INFO("Imported legacy dashboard settings into XDG damage.config"),
                    ok;
                Error -> Error
            end;
        {error, Reason} -> {error, {legacy_overlay_invalid, Reason}}
    end.

empty_overrides() ->
    maps:from_list([{App, #{}} || App <- damage_settings_schema:apps()]).

%% Exclusive creation protects upgrades and concurrent first-starts.  The
%% resulting Erlang term is a *list of per-application tuple proplists*.
create_managed_config(Path, Overlay) ->
    Data = overlay_body(Overlay),
    case file:open(Path, [write, exclusive, binary, raw]) of
        {ok, FD} ->
            Result = try
                case file:change_mode(Path, 8#600) of
                    ok ->
                        case file:write(FD, Data) of
                            ok -> file:sync(FD);
                            Error -> Error
                        end;
                    Error -> Error
                end
            after file:close(FD) end,
            case Result of
                ok -> ok;
                {error, Why} ->
                    _ = file:delete(Path),
                    {error, {managed_config_create_failed, Why}}
            end;
        {error, eexist} ->
            %% Another daemon or package postinst may have created it.
            case read_config(Path, ?MAX_OVERLAY_BYTES, required) of
                {ok, _, _} -> ok;
                {error, Why} -> {error, {existing_managed_config_invalid, Why}}
            end;
        {error, Why} -> {error, {managed_config_create_failed, Why}}
    end.

%% Create only the app-specific config directory.  Do not chmod a user's
%% existing XDG_CONFIG_HOME, and never follow a symlink at the target folder.
ensure_overlay_dir(Path) ->
    Dir = filename:dirname(Path),
    case file:read_link_info(Dir) of
        {ok, #file_info{type = directory, mode = Mode}} when Mode band 8#022 =:= 0 ->
            ok;
        {ok, #file_info{type = directory}} -> {error, unsafe_managed_config_directory};
        {ok, _} -> {error, managed_config_directory_not_directory};
        {error, enoent} ->
            case filelib:ensure_dir(filename:join(Dir, ".keep")) of
                ok ->
                    case file:read_link_info(Dir) of
                        {ok, #file_info{type = directory}} -> file:change_mode(Dir, 8#700);
                        _ -> {error, managed_config_directory_not_directory}
                    end;
                {error, Why} -> {error, {managed_config_directory_create_failed, Why}}
            end;
        {error, Why} -> {error, {managed_config_directory_stat_failed, Why}}
    end.

overlay_body(Overlay) ->
    Contents = [{App, lists:sort(maps:to_list(maps:get(App, Overlay)))}
                || App <- damage_settings_schema:apps(),
                   map_size(maps:get(App, Overlay)) > 0],
    iolist_to_binary(io_lib:format(
        "%% DamageBDD managed node settings (XDG damage.config). No secrets.\n~tp.\n",
        [Contents])).

write_overlay(Path, Overlay) ->
    case ensure_overlay_dir(Path) of
        ok ->
            case file:read_link_info(Path) of
                {ok, #file_info{type = regular, mode = Mode}}
                  when Mode band 8#022 =:= 0 -> write_overlay_in_dir(Path, Overlay);
                {ok, #file_info{type = regular}} -> {error, unsafe_managed_config_permissions};
                {error, enoent} -> write_overlay_in_dir(Path, Overlay);
                {ok, _} -> {error, managed_config_not_regular_file};
                {error, Why} -> {error, {managed_config_stat_failed, Why}}
            end;
        Error -> Error
    end.

write_overlay_in_dir(Path, Overlay) ->
    Body = overlay_body(Overlay),
    case byte_size(Body) > ?MAX_OVERLAY_BYTES of
        true -> {error, managed_config_too_large};
        false -> write_overlay_content(Path, Body)
    end.

write_overlay_content(Path, Body) ->
    Tmp = Path ++ ".tmp." ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    case file:open(Tmp, [write, exclusive, binary, raw]) of
        {ok, FD} ->
            Result = try
                case file:change_mode(Tmp, 8#600) of
                    ok ->
                        case file:write(FD, Body) of
                            ok -> file:sync(FD);
                            WriteError -> WriteError
                        end;
                    ModeError -> ModeError
                end
            after file:close(FD) end,
            case Result of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok -> ok;
                        {error, RenameWhy} ->
                            _ = file:delete(Tmp), {error, {rename_failed, RenameWhy}}
                    end;
                {error, WriteWhy} ->
                    _ = file:delete(Tmp), {error, {write_failed, WriteWhy}}
            end;
        {error, OpenWhy} -> {error, {temp_open_failed, OpenWhy}}
    end.

to_binary(B) when is_binary(B) -> B;
to_binary(IoList) -> iolist_to_binary(IoList).
