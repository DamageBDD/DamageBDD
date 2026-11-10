%%%-------------------------------------------------------------------
%%% @doc MPRIS2 integration for ERM's managed MPV instance.
%%%
%%% This is intentionally not a second media player or D-Bus state machine.
%%% The mpv-mpris C plugin publishes the actual MPV state to the session bus;
%%% ERM still owns playback through erm_mpv_proc and MPV's JSON IPC.
%%%
%%% On Arch/Debian the plugin is auto-loaded from /etc/mpv/scripts/mpris.so.
%%% When a distribution only installs its library, we pass --script=...
%%% exactly once.  This runs inside the MPV OS process and therefore survives
%%% an ERM/BEAM restart in erm_mpv_proc's survive_beam mode.
%%%-------------------------------------------------------------------
-module(erm_mpris).

-export([mpv_args/0, status/0, select_plugin/4, args_for/1]).

-define(MPRIS_BUS_PREFIX, "org.mpris.MediaPlayer2.mpv").

-spec mpv_args() -> [string()].
mpv_args() ->
    args_for(plugin()).

-spec status() -> map().
status() ->
    Selection = plugin(),
    PluginInfo =
        case Selection of
            {autoload, Path} -> #{state => installed, loader => autoload, path => Path};
            {manual, Path} -> #{state => installed, loader => explicit, path => Path};
            {unavailable, Reason} -> #{state => missing, reason => Reason}
        end,
    #{
        provider => mpv_mpris,
        plugin => PluginInfo,
        session_bus => session_bus_hint(),
        expected_name_prefix => ?MPRIS_BUS_PREFIX,
        player_identity => "ERM",
        %% This cannot establish live registration; use busctl/playerctl.
        registration => not_checked,
        applies_to => newly_started_mpv_processes
    }.

%% Public, deterministic selection logic used by the EUnit module.  Detect
%% automatic locations first; do NOT load the .so again via --script or mpv
%% can initialize multiple competing MPRIS interfaces.
-spec select_plugin(false | string(), [string()], [string()], fun((string()) -> boolean())) ->
    {autoload | manual, string()} | {unavailable, term()}.
select_plugin(Override, AutoPaths, LibraryPaths, Exists) when is_function(Exists, 1) ->
    case first_existing(AutoPaths, Exists) of
        {ok, Path} ->
            {autoload, Path};
        none ->
            case Override of
                false -> select_library(LibraryPaths, Exists);
                "" -> select_library(LibraryPaths, Exists);
                Path when is_list(Path) ->
                    case filename:pathtype(Path) of
                        absolute ->
                            case Exists(Path) of
                                true -> {manual, Path};
                                false -> {unavailable, {override_not_found, Path}}
                            end;
                        _ ->
                            {unavailable, {override_not_absolute, Path}}
                    end
            end
    end.

-spec args_for({autoload | manual, string()} | {unavailable, term()}) -> [string()].
args_for({autoload, _Path}) ->
    ["--load-scripts=yes", "--audio-client-name=ERM"];
args_for({manual, Path}) ->
    ["--load-scripts=yes", "--audio-client-name=ERM", "--script=" ++ Path];
args_for({unavailable, _Reason}) ->
    [].

plugin() ->
    select_plugin(
        os:getenv("MPV_MPRIS_SCRIPT"),
        autoload_paths(),
        library_paths(),
        fun filelib:is_file/1
    ).

select_library(LibraryPaths, Exists) ->
    case first_existing(LibraryPaths, Exists) of
        {ok, Path} -> {manual, Path};
        none -> {unavailable, mpv_mpris_not_installed}
    end.

first_existing([], _Exists) -> none;
first_existing([Path | Rest], Exists) ->
    case Exists(Path) of
        true -> {ok, Path};
        false -> first_existing(Rest, Exists)
    end.

autoload_paths() ->
    %% Respect mpv's configuration home precedence, rather than mixing files
    %% from another login/user's home into the managed service.
    UserPath =
        case nonempty_env("MPV_HOME") of
            {ok, MPVHome} -> filename:join([MPVHome, "scripts", "mpris.so"]);
            false ->
                case nonempty_env("XDG_CONFIG_HOME") of
                    {ok, ConfigHome} -> filename:join([ConfigHome, "mpv", "scripts", "mpris.so"]);
                    false ->
                        case nonempty_env("HOME") of
                            {ok, LoginHome} ->
                                filename:join([LoginHome, ".config", "mpv", "scripts", "mpris.so"]);
                            false -> undefined
                        end
                end
        end,
    [P || P <- [UserPath, "/etc/mpv/scripts/mpris.so"], P =/= undefined].

library_paths() ->
    [
        "/usr/lib/mpv-mpris/mpris.so",
        "/usr/lib64/mpv-mpris/mpris.so",
        "/usr/local/lib/mpv-mpris/mpris.so"
    ].

session_bus_hint() ->
    case nonempty_env("DBUS_SESSION_BUS_ADDRESS") of
        {ok, _Address} ->
            explicit_address;
        false ->
            case nonempty_env("XDG_RUNTIME_DIR") of
                {ok, RuntimeDir} ->
                    #{state => runtime_dir_present,
                      expected_socket => filename:join(RuntimeDir, "bus")};
                false ->
                    not_configured
            end
    end.

nonempty_env(Name) ->
    case os:getenv(Name) of
        false -> false;
        "" -> false;
        Value -> {ok, Value}
    end.
