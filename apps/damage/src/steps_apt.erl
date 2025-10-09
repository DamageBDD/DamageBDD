%%--------------------------------------------------------------------
%% @doc BDD Steps for APT-based package management
%%--------------------------------------------------------------------
-module(steps_apt).

-export([
    install/1,
    install_many/1,
    update/0,
    upgrade/0,
    remove/1,
    autoremove/0,
    is_installed/1
]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
-spec run_cmd(string()) -> {ok, string()} | {error, string()}.
run_cmd(Cmd) ->
    case os:cmd(Cmd) of
        Output ->
            Exit = os:cmd("echo $?"),
            ExitCode = list_to_integer(string:trim(Exit)),
            case ExitCode of
                0 -> {ok, string:trim(Output)};
                _ -> {error, string:trim(Output)}
            end
    end.

-spec apt_get(string()) -> {ok, string()} | {error, string()}.
apt_get(Args) ->
    %% Using DEBIAN_FRONTEND=noninteractive avoids dpkg prompts
    Cmd = io_lib:format("sudo DEBIAN_FRONTEND=noninteractive apt-get -y ~s", [Args]),
    run_cmd(lists:flatten(Cmd)).

%%--------------------------------------------------------------------
%% Steps
%%--------------------------------------------------------------------

%% @doc Run `apt-get update`
update() ->
    apt_get("update").

%% @doc Run `apt-get upgrade -y`
upgrade() ->
    apt_get("upgrade").

%% @doc Install a single package
-spec install(string()) -> {ok, string()} | {error, string()}.
install(Package) ->
    apt_get(io_lib:format("install ~s", [Package])).

%% @doc Install multiple packages (space-separated)
-spec install_many([string()]) -> {ok, string()} | {error, string()}.
install_many(Pkgs) ->
    Str = string:join(Pkgs, " "),
    apt_get(io_lib:format("install ~s", [Str])).

%% @doc Remove a package
-spec remove(string()) -> {ok, string()} | {error, string()}.
remove(Package) ->
    apt_get(io_lib:format("remove ~s", [Package])).

%% @doc Autoremove unused packages
autoremove() ->
    apt_get("autoremove").

%% @doc Check if a package is installed (dpkg-query)
-spec is_installed(string()) -> boolean().
is_installed(Package) ->
    Cmd = io_lib:format("dpkg-query -W -f='${Status}' ~s 2>/dev/null", [Package]),
    case run_cmd(lists:flatten(Cmd)) of
        {ok, Out} ->
            string:find(Out, "install ok installed") =/= nomatch;
        {error, _} ->
            false
    end.
