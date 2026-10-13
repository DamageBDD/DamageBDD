%%% @doc
%%% ZX: A suite of tools for Erlang development and deployment.
%%%
%%% ZX can:
%%%   - Create project templates for applications, libraries and escripts.
%%%   - Initialize existing projects for packaging and management.
%%%   - Create and manage zomp realms, users, keys, etc.
%%%   - Manage dependencies hosted in any zomp realm.
%%%   - Package, submit, pull-for-review, and resign-to-accept packages.
%%%   - Update, upgrade, and run any application from source that zomp tracks.
%%%   - Locally install packages from files and locally stored public keys.
%%%   - Build and run a local project from source using zomp dependencies.
%%%   - Start an anonymous zomp distribution node.
%%%   - Act as a unified code launcher for any projects (Erlang + ZX = deployed).
%%%
%%% ZX is currently limited in one specific way:
%%%   - Can only launch pure Erlang code.
%%%
%%% In the works:
%%%   - Support for LFE
%%%   - Support for Rust (cross-platform)
%%%   - Support for Elixir (as a peer language)
%%%   - Unified Windows installer to deploy Erlang, Rust, LFE, Elixir and ZX
%%% @end

-module(zx).
-vsn("0.14.0").
-behavior(application).
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").


-export([do/0]).
-export([run/2, not_done/1, done/1,
         get_home/0,
         subscribe/1, unsubscribe/0,
         list/0, list/1, list/2, list/3, latest/1,
         list_type/2, list_type_ar/1, describe/1, describe_plural/1, integrate/1,
         stop/0, silent_stop/0]).
-export([start/2, stop/1]).

-export_type([serial/0, package_id/0, package/0, realm/0, name/0, version/0,
              identifier/0,
              host/0,
              key/0, key_data/0, key_bin/0, key_id/0, key_name/0,
              user_id/0, user_name/0, contact_info/0, user_data/0,
              lower0_9/0, label/0,
              ss_tag/0, search_tag/0, description/0, package_type/0,
              outcome/0, core_dir/0]).

-include("zx_logger.hrl").



%%% Type Definitions

-type serial()          :: integer().
-type package_id()      :: {realm(), name(), version()}.
-type package()         :: {realm(), name()}.
-type realm()           :: lower0_9().
-type name()            :: lower0_9().
-type version()         :: {Major :: non_neg_integer() | z,
                            Minor :: non_neg_integer() | z,
                            Patch :: non_neg_integer() | z}.
-type host()            :: {string() | inet:ip_address(), inet:port_number()}.
-type key()             :: term(). % wtf? This is what public_key:der_decode/2 returns
-type key_data()        :: {Name    :: key_name(),
                            Public  :: none | key_bin(),
                            Private :: none | key_bin()}.
-type key_bin()         :: {Sig :: none | {key_name(), binary()},
                            DER :: binary()}.
-type key_id()          :: {realm(), key_name()}.
-type key_name()        :: key_hash().
-type key_hash()        :: binary().
-type user_data()       :: {ID       :: user_id(),
                            RealName :: string(),
                            Contact  :: [contact_info()],
                            Keys     :: [key_data()]}.
-type user_id()         :: {realm(), user_name()}.
-type user_name()       :: label().
-type contact_info()    :: {Type :: string(), Data :: string()}.
-type lower0_9()        :: [$a..$z | $0..$9 | $_].
-type label()           :: [$a..$z | $0..$9 | $_ | $- | $.].
-type ss_tag()          :: {serial(), erlang:timestamp()}.
-type search_tag()      :: string().

-type description()     :: {description,
                            PackageID   :: package_id(),
                            DisplayName :: string(),
                            Type        :: package_type(),
                            Desc        :: string(),
                            Author      :: string(),
                            AEmail      :: string(),
                            WebURL      :: string(),
                            RepoURL     :: string(),
                            Tags        :: [zx:search_tag()]}.
-type package_type()    :: app | lib | gui | cli.

-type outcome()         :: ok
                         | {error, Reason :: term()}
                         | {error, Code :: non_neg_integer()}
                         | {error, Info :: string(), Code :: non_neg_integer()}.

-type core_dir() :: etc | var | tmp | log | key | zsp | lib.




%%% Command Dispatch

-spec do() -> no_return().

do() ->
    ok = io:setopts([{encoding, unicode}]),
    ok = start(),
    Args = init:get_plain_arguments(),
    do(Args).


-spec do(Args) -> no_return()
    when Args :: [string()].
%% Dispatch work functions based on the nature of the input arguments.

do(["help"]) ->
    done(help(top));
do(["help", "user"]) ->
    done(help(user));
do(["help", "dev"]) ->
    done(help(dev));
do(["help", "sysop"]) ->
    done(help(sysop));
do(["--version"]) ->
    done(version());
do(["run", PackageString | ArgV]) ->
    ok = connect(),
    not_done(run(PackageString, ArgV));
do(["integrate", "desktop", PackageString]) ->
    ok = connect(),
    done(integrate0(PackageString));
do(["list", "realms"]) ->
    done(zx_local:list_realms());
do(["list", "packages", Realm]) ->
    ok = connect(),
    done(zx_local:list_packages(Realm));
do(["list", "versions", PackageName]) ->
    ok = connect(),
    done(zx_local:list_versions(PackageName));
do(["list", "gui"]) ->
    ok = connect(),
    done(zx_local:list_type(gui));
do(["list", "cli"]) ->
    ok = connect(),
    done(zx_local:list_type(cli));
do(["list", "app"]) ->
    ok = connect(),
    done(zx_local:list_type(app));
do(["list", "lib"]) ->
    ok = connect(),
    done(zx_local:list_type(lib));
do(["latest", PackageString]) ->
    ok = connect(),
    done(zx_local:latest(PackageString));
do(["describe", PackageString]) ->
    ok = connect(),
    done(zx_local:describe(PackageString));
do(["upgrade"]) ->
    ok = connect(),
    done(upgrade());
do(["import", "realm", RealmFile]) ->
    done(zx_local:import_realm(RealmFile));
do(["drop", "realm", Realm]) ->
    done(zx_local:drop_realm(Realm));
do(["logpath", PackageString, AgoString]) ->
    case try list_to_integer(AgoString) catch Error:Reason -> {Error, Reason} end of
        {error, badarg} -> done(help(user));
        Ago             -> done(zx_local:logpath(PackageString, Ago))
    end;
do(["set", "timeout", String]) ->
    done(zx_local:set_timeout(String));
do(["add", "mirror"]) ->
    done(zx_local:add_mirror());
do(["add", "mirror", Address]) ->
    done(zx_local:add_mirror(Address));
do(["add", "mirror", Address, Port]) ->
    done(zx_local:add_mirror(Address, Port));
do(["drop", "mirror"]) ->
    done(zx_local:drop_mirror());
do(["drop", "mirror", Address]) ->
    done(zx_local:drop_mirror(Address));
do(["drop", "mirror", Address, Port]) ->
    done(zx_local:drop_mirror(Address, Port));
do(["create", "project"]) ->
    ok = connect(),
    done(zx_local:create_project());
do(["template", "swp"]) ->
    ok = connect(),
    done(zx_local:template_swp());
do(["runlocal" | ArgV]) ->
    ok = connect(),
    not_done(run_local(ArgV));
do(["rundir", Path | ArgV]) ->
    ok = connect(),
    not_done(run_dir(Path, ArgV));
do(["init"]) ->
    ok = connect(),
    ok = compatibility_check([unix]),
    done(zx_local:initialize());
do(["list", "deps"]) ->
    done(zx_local:list_deps());
do(["list", "deps", PackageString]) ->
    ok = connect(),
    done(zx_local:list_deps(PackageString));
do(["set", "dep", PackageString]) ->
    done(zx_local:set_dep(PackageString));
do(["drop", "dep", PackageString]) ->
    done(zx_local:drop_dep(PackageString));
do(["verup", Level]) ->
    ok = compatibility_check([unix]),
    done(zx_local:verup(Level));
do(["set", "version", VersionString]) ->
    ok = compatibility_check([unix]),
    done(zx_local:set_version(VersionString));
do(["provides", Module]) ->
    ok = connect(),
    done(zx_local:provides(Module));
do(["search"]) ->
    done(help(user));
do(["search" | Terms]) ->
    ok = connect(),
    Strings = string:join(Terms, " "),
    done(zx_local:search(Strings));
do(["update", "meta"]) ->
    done(zx_local:update_meta());
do(["update", ".app"]) ->
    done(zx_local:update_app_file());
do(["package"]) ->
    {ok, TargetDir} = file:get_cwd(),
    done(zx_local:package(TargetDir));
do(["package", TargetDir]) ->
    case filelib:is_dir(TargetDir) of
        true  -> done(zx_local:package(TargetDir));
        false -> done({error, "Target directory does not exist", 22})
    end;
do(["submit", PackageFile]) ->
    done(zx_auth:submit(PackageFile));
do(["list", "pending", PackageName]) ->
    done(zx_auth:list_pending(PackageName));
do(["review", PackageString]) ->
    done(zx_auth:review(PackageString));
do(["approve", PackageString]) ->
    done(zx_auth:approve(PackageString));
do(["reject", PackageString]) ->
    done(zx_auth:reject(PackageString));
do(["sync", "keys"]) ->
    ok = connect(),
    done(zx_auth:sync_keys());
do(["create", "user"]) ->
    done(zx_local:create_user());
do(["create", "keypair"]) ->
    done(zx_local:grow_a_pair());
do(["export", "user"]) ->
    done(zx_local:export_user(zpuf));
do(["export", "user", "dangerous"]) ->
    done(zx_local:export_user(zduf));
do(["import", "user", ZdufFile]) ->
    done(zx_local:import_user(ZdufFile));
do(["list", "users", Realm]) ->
    done(zx_auth:list_users(Realm));
do(["list", "packagers", PackageName]) ->
    done(zx_auth:list_packagers(PackageName));
do(["list", "maintainers", PackageName]) ->
    done(zx_auth:list_maintainers(PackageName));
do(["list", "sysops", Realm]) ->
    ok = connect(),
    done(zx_local:list_sysops(Realm));
do(["export", "realm"]) ->
    done(zx_local:export_realm());
do(["export", "realm", Realm]) ->
    done(zx_local:export_realm(Realm));
do(["install", PackageFile]) ->
    case filelib:is_regular(PackageFile) of
        true  -> done(zx_daemon:install(PackageFile));
        false -> done({error, ".zsp file does not exist", 22})
    end;
do(["list", "approved", Realm]) ->
    done(zx_auth:list_approved(Realm));
do(["accept", PackageString]) ->
    done(zx_auth:accept(PackageString));
do(["add", "package", PackageName]) ->
    done(zx_auth:add_package(PackageName));
do(["add", "user", ZpuFile]) ->
    done(zx_auth:add_user(ZpuFile));
do(["rem", "user", Realm, UserName]) ->
    done(zx_auth:rem_user(Realm, UserName));
do(["add", "packager", Package, UserName]) ->
    done(zx_auth:add_packager(Package, UserName));
do(["rem", "packager", Package, UserName]) ->
    done(zx_auth:rem_packager(Package, UserName));
do(["add", "maintainer", Package, UserName]) ->
    done(zx_auth:add_maintainer(Package, UserName));
do(["rem", "maintainer", Package, UserName]) ->
    done(zx_auth:rem_maintainer(Package, UserName));
do(["add", "sysop", Realm, UserName]) ->
    done(zx_auth:add_sysop(Realm, UserName));
do(["create", "realm"]) ->
    done(zx_local:create_realm());
do(["takeover", Realm]) ->
    done(zx_daemon:takeover(Realm));
do(["abdicate", Realm]) ->
    done(zx_daemon:abdicate(Realm));
do(_) ->
    done(help(top)).


-spec done(outcome()) -> no_return().

done(ok) ->
    ok = zx_daemon:idle(),
    init:stop(0);
done({error, shutdown}) ->
    ok = tell(info, "Shutdown message received."),
    ok = zx_daemon:idle(),
    init:stop(0);
done({error, Code}) when is_integer(Code) ->
    ok = zx_daemon:idle(),
    Message = "Operation failed with code: ~w",
    ok = tell(error, Message, [Code]),
    init:stop(Code);
done({error, Reason}) when is_atom(Reason) ->
    ok = tell(error, "Operation failed with: ~160tp", [Reason]),
    init:stop(1);
done({error, Reason}) ->
    ok = zx_daemon:idle(),
    {Message, Subs} =
        case unicode:characters_to_list(Reason) of
            {_, _, _} -> {"Operation failed with: ~160tp", Reason};
            String    -> {"Operation failed with: ~ts", String}
        end,
    ok = tell(error, Message, [Subs]),
    init:stop(1);
done({error, Reason, Code}) when is_atom(Reason) ->
    ok = tell(error, "Operation failed with: ~160tp", [Reason]),
    init:stop(Code);
done({error, Reason, Code}) ->
    ok = zx_daemon:idle(),
    {Message, Subs} =
        case unicode:characters_to_list(Reason) of
            {_, _, _} -> {"Operation failed with: ~160tp", Reason};
            String    -> {"Operation failed with: ~ts", String}
        end,
    ok = tell(error, Message, [Subs]),
    init:stop(Code);
done({error, Class, Error, Stacktrace}) ->
    ok = zx_daemon:idle(),
    Message = "Execution failed with: ~tp: ~tp~nStacktrace:~n~tp",
    ok = tell(error, Message, [Class, Error, Stacktrace]),
    init:stop(1).


-spec not_done(outcome()) -> ok | no_return().

not_done(ok)    -> ok;
not_done(Error) -> done(Error).


-spec connect() -> ok.

connect() ->
    ok = zx_daemon:connect(),
    ZxDir = os:getenv("ZX_DIR"),
    {ok, Meta} = zx_lib:read_project_meta(ZxDir),
    Current = element(3, maps:get(package_id, Meta)),
    case latest({"otpr", "zx"}) of
        {ok, Latest}       -> connect(Current, Latest);
        {error, bad_realm} -> ok;
        {error, Reason}    -> tell(error, "ZX check error: ~p. Proceeding.", [Reason])
    end.

connect(Current, Latest) when Current >= Latest ->
    ok;
connect(Current, Latest) when Current < Latest ->
    ok = tell("New ZX version found. Upgrading..."),
    ok = upgrade(),
    {ok, VS} = zx_lib:version_to_string(Latest),
    OldZxDir = os:getenv("ZX_DIR"),
    NewZxDir = filename:join(filename:dirname(OldZxDir), VS),
    true = os:putenv("ZX_VERSION", VS),
    true = os:putenv("ZX_DIR", NewZxDir),
    ok = tell("Restarting previous operation..."),
    init:restart().


-spec compatibility_check(Platforms) -> ok | no_return()
    when Platforms :: unix | win32.
%% @private
%% Some commands only work on specific platforms because they leverage some specific
%% aspect on that platform, but not common to all. ATM this is mostly developer
%% commands that leverage things universal to *nix/posix shells but not Windows.
%% If equivalent procedures are written in Erlang then these restrictions can be
%% avoided -- but it is unclear whether there are any Erlang developers even using
%% Windows, so for now this is the bad version of the solution.

compatibility_check(Platforms) ->
    {Family, Name} = os:type(),
    case lists:member(Family, Platforms) of
        true ->
            ok;
        false ->
            Message = "Unfortunately this command is not available on ~tw ~tw",
            ok = tell(error, Message, [Family, Name]),
            init:stop()
    end.



%%% Application Start/Stop

-spec start() -> ok | {error, Reason :: term()}.
%% @doc
%% An alias for `application:ensure_started(zx)', meaning it is safe to call this
%% function more than once, or within a system where you are unsure whether zx is
%% already running (perhaps due to complex dependencies that require zx already).
%% In the typical case this function does not ever need to be called, because the
%% zx_daemon is always started in the background whenever an application is started
%% using the command `zx run [app_id]'.
%% @equiv application:ensure_started(zx).

start() ->
    case init:get_plain_arguments() of
        ["run", PackageString | _] ->
            case zx_lib:package_id(PackageString) of
                {ok, PackID} -> start(zx_lib:new_logpath(PackID));
                Error        -> done(Error)
            end;
        ["rundir", Path | _] ->
            case zx_lib:read_project_meta(Path) of
                {ok, #{package_id := PackID}} -> start(zx_lib:new_logpath(PackID));
                Error                         -> done(Error)
            end;
        ["runlocal" | _] ->
            case zx_lib:read_project_meta() of
                {ok, #{package_id := PackID}} -> start(zx_lib:new_logpath(PackID));
                Error                         -> done(Error)
            end;
        _ ->
            {ok, Version} = zx_lib:string_to_version(os:getenv("ZX_VERSION")),
            start(zx_lib:new_logpath({"otpr", "zx", Version}))
    end.

start(LogPath) ->
    ok = logger:remove_handler(default),
    LogDir = filename:dirname(LogPath),
    ok = trim_logs(LogDir),
    LoggerConf =
        #{config =>
          #{burst_limit_enable          => true,
            burst_limit_max_count       => 500,
            burst_limit_window_time     => 1000,
            drop_mode_qlen              => 200,
            filesync_repeat_interval    => no_repeat,
            flush_qlen                  => 1000,
            overload_kill_enable        => false,
            overload_kill_mem_size      => 3000000,
            overload_kill_qlen          => 20000,
            overload_kill_restart_after => 5000,
            sync_mode_qlen              => 10,
            type                        => file,
            file                        => LogPath,
            max_no_bytes                => 10000000,
            max_no_files                => 10},
         filter_default =>
            stop,
         filters =>
            [{remote_gl, {fun logger_filters:remote_gl/2, stop}},
             {domain,    {fun logger_filters:domain/2,    {log, super, [otp, sasl]}}},
             {no_domain, {fun logger_filters:domain/2,    {log, undefined,[]}}}],
         formatter =>
            {logger_formatter, #{legacy_header => false, single_line => true}},
         id     => default,
         level  => all,
         module => logger_std_h},
    ok = logger:add_handler(default, logger_std_h, LoggerConf),
    ok = logger:set_primary_config(level, debug),
    % Hacky:
    % Load all necessary atoms for binary_to_term(B, [safe]) to work with zx_zsp:meta()
    MetaKeys = maps:keys(zx_zsp:new_meta()),
    Types = [lib, app, gui, cli],
    ok = log(info, "ZSP meta keys: ~w", [MetaKeys]),
    ok = log(info, "Available package types: ~w", [Types]),
    application:ensure_started(zx, permanent).

trim_logs(LogDir) ->
    {ok, Origin} = file:get_cwd(),
    ok = file:set_cwd(LogDir),
    {ok, Files} = file:list_dir("."),
    Descending = fun(A, B) -> A > B end,
    Sorted = lists:sort(Descending, Files),
    ok =
        case length(Sorted) =< 10 of
            true  -> ok;
            false -> lists:foreach(fun file:delete/1, lists:nthtail(10, Sorted))
        end,
    file:set_cwd(Origin).


-spec stop() -> ok | {error, Reason :: term()}.
%% @doc
%% A safe wrapper for `application:stop(zx)'. Similar to `ensure_started/1,2', returns
%% `ok' in the case that zx is already stopped.

stop() ->
    ok = tell("Shutting down runtime."),
    ok = zx_daemon:idle(),
    case application:stop(zx) of
        ok ->
            init:stop();
        {error, {not_started, zx}} ->
            init:stop();
        Error ->
            ok = tell(error, "zx:stop/0 failed with ~tp", [Error]),
            init:stop(1)
    end.


-spec silent_stop() -> ok | {error, Reason :: term()}.
%% @doc
%% A safe wrapper for `application:stop(zx)'. Similar to `ensure_started/1,2', returns
%% `ok' in the case that zx is already stopped.

silent_stop() ->
    ok = zx_daemon:idle(),
    case application:stop(zx) of
        ok ->
            init:stop();
        {error, {not_started, zx}} ->
            init:stop();
        Error ->
            ok = tell(error, "zx:stop_quiet/0 failed with ~tp", [Error]),
            init:stop(1)
    end.


%%% Application Callbacks

-spec start(StartType, StartArgs) -> Result
    when StartType :: normal,
         StartArgs :: none,
         Result    :: {ok, pid()}.
%% @private
%% Application callback. Not to be called directly.

start(normal, none) ->
    ok = application:ensure_started(inets),
    zx_sup:start_link().


-spec stop(term()) -> ok.
%% @private
%% Application callback. Not to be called directly.

stop(_) ->
    ok.



%%% Daemon Controls

-spec get_home() -> file:filename().
%% @doc
%% A program launched by ZX can call this function to query the zx_daemon for its
%% current code home. This is necessary for programs that have extra static data
%% included in their project (translation files, icons, images, texture maps, etc.)
%% and need to be able to locate it relative to the project root directory.

get_home() ->
    zx_daemon:get_home().


-spec subscribe(package()) -> ok | {error, Reason :: term()}.
%% @doc
%% Initiates the zx_daemon and instructs it to subscribe to a package.
%%
%% Any events in the Zomp network that apply to the subscribed package will be
%% forwarded to the process that originally called subscribe/1. How the original
%% caller reacts to these notifications is up to the author -- not reply or "ack"
%% is expected.
%%
%% Package subscriptions can be used as the basis for user notification of updates,
%% automatic upgrade restarts, package catalog tracking, etc.

subscribe(Package) ->
    case application:start(?MODULE, normal) of
        ok    -> zx_daemon:subscribe(Package);
        Error -> Error
    end.


-spec unsubscribe() -> ok | {error, Reason :: term()}.
%% @doc
%% Unsubscribes from package updates.

unsubscribe() ->
    zx_daemon:unsubscribe().



%%% Query Functions

-spec list() -> Result
    when Result :: {ok, [realm()]}
                 | {error, no_realms}.

list() ->
    case zx_lib:list_realms() of
        []     -> {error, no_realms};
        Realms -> {ok, Realms}
    end.


-spec list(realm()) -> Result
    when Result :: {ok, [realm()]}
                 | {error, Reason},
         Reason :: bad_realm
                 | timeout
                 | network.

list(Realm) ->
    {ok, ID} = zx_daemon:list(Realm),
    zx_daemon:wait_result(ID).


-spec list(realm(), name()) -> Result
    when Result :: {ok, [version()]}
                 | {error, Reason},
         Reason :: bad_realm
                 | bad_package
                 | timeout
                 | network.

list(Realm, Name) ->
    list(Realm, Name, {z, z, z}).


-spec list(realm(), name(), version()) -> Result
    when Result :: {ok, [version()]}
                 | {error, Reason},
         Reason :: bad_realm
                 | bad_package
                 | bad_version
                 | timeout
                 | network.

list(Realm, Name, Version) ->
    {ok, ID} = zx_daemon:list(Realm, Name, Version),
    zx_daemon:wait_result(ID).


-spec latest(package_id()) -> Result
    when Result :: {ok, version()}
                 | {error, Reason},
         Reason :: bad_realm
                 | bad_package
                 | bad_version
                 | timeout
                 | network.

latest(PackageID) ->
    {ok, ID} = zx_daemon:latest(PackageID),
    zx_daemon:wait_result(ID).


-spec list_type(Realm, Type) -> Result
    when Realm  :: realm(),
         Type   :: package_type(),
         Result :: {ok, [package_id()]}.

list_type(Realm, Type) ->
    {ok, ID} = zx_daemon:list_type({Realm, Type}),
    zx_daemon:wait_result(ID).


-spec list_type_ar(Type) -> Result
    when Type       :: package_type(),
         Result    :: {ok, [package_id()]}
                     | {error, Unexpected, [Result]}
                     | {error, Reason},
         Unexpected :: {unexpected, {result, zx_daemon:id(), term()}},
         Reason     :: bad_realm
                     | bad_package
                     | bad_version
                     | timeout
                     | network
                     | {unexpected, Message :: string()}.
%% @doc
%% List all packages from all realms that are of `Type'.
%% The "_ar" suffix to this function is short for "all realms".

list_type_ar(Type) ->
    Realms = zx_lib:list_realms(),
    MakeRequest =
        fun(Realm) ->
            {ok, ID} = zx_daemon:list_type({Realm, Type}),
            ID
        end,
    Index = [{MakeRequest(R), R} || R <- Realms],
    IDs = [element(1, I) || I <- Index],
    case zx_daemon:wait_results(IDs) of
        {ok, Results} -> {ok, scrub_errors(lists:sort(Index), lists:sort(Results), [])};
        Error         -> Error
    end.

scrub_errors([{ID, _} | Index], [{ID, {ok, PackageIDs}} | Results], Acc) ->
    scrub_errors(Index, Results, [PackageIDs | Acc]);
scrub_errors([{ID, Realm} | Index], [{ID, Error} | Results], Acc) ->
    ok = tell(warning, "Received weird result from realm ~tp: ~tp", [Realm, Error]),
    scrub_errors(Index, Results, Acc);
scrub_errors([], [], Acc) ->
    lists:append(Acc).


-spec describe(package_id()) -> Result
    when Result :: {ok, description()}
                 | {error, Reason},
         Reason :: bad_realm
                 | bad_package
                 | bad_version
                 | timeout
                 | network.

describe(PackageID) ->
    {ok, ID} = zx_daemon:describe(PackageID),
    zx_daemon:wait_result(ID).


-spec describe_plural([package_id()]) -> Result
    when Result     :: {ok, [description()]}
                     | {error, Unexpected, [Result]}
                     | {error, Reason},
         Unexpected :: {unexpected, {result, zx_daemon:id(), term()}},
         Reason     :: bad_realm
                     | bad_package
                     | bad_version
                     | timeout
                     | network
                     | {unexpected, Message :: string()}.

describe_plural(PackageIDs) ->
    Describe =
        fun(PackageID) ->
            {ok, ID} = zx_daemon:describe(PackageID),
            ID
        end,
    IDs = lists:map(Describe, PackageIDs),
    {ok, Descriptions} = zx_daemon:wait_results(IDs),
    {ok, [Description || {_, {ok, Description}} <- Descriptions]}.


-spec integrate(PackageString) -> zx:outcome()
    when PackageString :: string().

integrate0(PackageString) ->
    case zx_lib:package_id(PackageString) of
        {ok, PackageID} -> integrate(PackageID);
        Error           -> Error
    end.


integrate(PackageID) ->
    case resolve_version(PackageID) of
        {fetch, FetchID}         -> integrate2(PackageID, FetchID);
        {installed, InstalledID} -> integrate3(PackageID, InstalledID);
        Error                    -> Error
    end.


integrate2(PackageID, FetchID) ->
    case fetch(FetchID) of
        ok    -> integrate3(PackageID, FetchID);
        Error -> Error
    end.


integrate3(PackageID, InstalledID) ->
    Dir = zx_lib:ppath(lib, InstalledID),
    {ok, Meta} = zx_lib:read_project_meta(Dir),
    case maps:get(type, Meta) of
        gui  -> integrate4(PackageID, InstalledID, Meta);
        Type -> {error, {bad_app_type, Type}}
    end.
    
integrate4(PackageID, InstalledID, Meta) ->
    case os:type() of
        {unix, linux} ->
            integrate_linux(PackageID, InstalledID, Meta);
%       {win32, nt} ->
        Other ->
            Message = "Sorry! This command is not yet supported on ~p.",
            ok = tell(error, Message, [Other]),
            {error, "Feature unsupported on this platform."}
    end.


integrate_linux(PackageID, InstalledID, Meta) ->
    XDG_DESKTOP_DIR = discover_xdg_desktop(),
    case filelib:is_dir(XDG_DESKTOP_DIR) of
        true  -> integrate_linux(PackageID, InstalledID, Meta, XDG_DESKTOP_DIR);
        false -> {error, "No desktop directory defined by XDG."}
    end.

integrate_linux(PackageID, InstalledID, Meta, XDG_DESKTOP_DIR) ->
    IconPath = place_icon(InstalledID),
    Name = element(2, InstalledID),
    Title =
        case maps:get(name, Meta) of
            "" -> Name;
            N  -> N
        end,
    {ok, PackageString} = zx_lib:package_string(PackageID),
    Version = element(3, PackageID),
    {ok, VersionString} = zx_lib:version_to_string(Version),
    Exec = "zx run " ++ PackageString,
    Launcher = filename:join(XDG_DESKTOP_DIR, Name ++ ".desktop"),
    Entry =
        ["[Desktop Entry]\n",
         "Encoding=UTF-8\n",
         "Version=", VersionString, "\n",
         "Exec=", Exec, "\n",
         "Name=", Title, "\n",
         "Comment=", Title, "\n",
         "Type=Application\n",
         "Terminal=false\n",
         "Icon=", IconPath, "\n"],
    ok = file:write_file(Launcher, unicode:characters_to_list(Entry)),
    _ = os:cmd("chmod +x " ++ Launcher),
    ok.


place_icon({Realm, Name, Version}) ->
    InstallDir = zx_lib:path(lib, Realm, Name, Version),
    VarDir = zx_lib:path(var, Realm, Name),
    Icon = "launcher.png",
    IconSource = filename:join(InstallDir, Icon),
    IconPath = filename:join(VarDir, Icon),
    {ok, _} =
        case filelib:is_regular(IconSource) of
            true ->
                file:copy(IconSource, IconPath);
            false ->
                ZxVersionS = os:getenv("ZX_VERSION"),
                {ok, ZxVersion} = zx_lib:string_to_version(ZxVersionS),
                ZxDir = zx_lib:path(lib, "otpr", "zx", ZxVersion),
                ZxIconPath = filename:join(ZxDir, Icon),
                ok = filelib:ensure_dir(IconPath),
                file:copy(ZxIconPath, IconPath)
        end,
    IconPath.

discover_xdg_desktop() ->
    XDG_UserDirsConf =
        case os:getenv("XDG_CONFIG_HOME") of
            false -> filename:join(os:getenv("HOME"), ".config/user-dirs.dirs");
            ""    -> filename:join(os:getenv("HOME"), ".config/user-dirs.dirs");
            D     -> filename:join(D, "user-dirs.dirs")
        end,
    {ok, Bits} = file:read_file(XDG_UserDirsConf),
    Segments = string:split(unicode:characters_to_list(Bits), "\n", all),
    search_xdg(Segments).

search_xdg(["XDG_DESKTOP_DIR=" ++ Value | _]) ->
    filename:join(os:getenv("HOME"), filename:basename(string:trim(Value, both, "\"")));
search_xdg([_ | Rest]) ->
    search_xdg(Rest);
search_xdg([]) ->
    filename:join(os:getenv("HOME"), "Desktop").
    


%%% Execution of application

-spec run(PackageString, RunArgs) -> zx:outcome()
    when PackageString :: string(),
         RunArgs       :: [string()].
%% @private
%% Given a program Identifier and a list of Args, attempt to locate the program and its
%% dependencies and run the program. This implies determining whether the program and
%% its dependencies are installed, available, need to be downloaded, or are inaccessible
%% given the current system condition (they could also be bogus, of course). The
%% Identifier must be a valid package string of the form `realm-appname[-version]'
%% where the `realm()' and `name()' must follow Zomp package naming conventions and the
%% version should be represented as a semver in string form (where ommitted elements of
%% the version always default to whatever is most current).
%%
%% Once the target program is running, this process, (which will run with the registered
%% name `zx') will sit in an `exec_wait' state, waiting for either a direct message from
%% a child program or for calls made via zx_lib to assist in environment discovery.
%%
%% If there is a problem anywhere in the locating, discovery, building, and loading
%% procedure the runtime will halt with an error message.

run(PackageString, RunArgs) ->
    try   run1(PackageString, RunArgs)
    catch C:E:S -> {error, C, E, S}
    end.

run1(PackageString, RunArgs) ->
    case zx_lib:package_id(PackageString) of
        {ok, {"otpr", "zomp", Version}} -> run2_maybe(Version, RunArgs);
        {ok, FuzzyID}                   -> run2(FuzzyID, RunArgs);
        Error                           -> Error
    end.


run2_maybe(Version, RunArgs) ->
    {ok, Managed} = zx_daemon:conf(managed),
    case lists:member("otpr", Managed) of
        true  -> run_zomp(RunArgs);
        false -> run2({"otpr", "zomp", Version}, RunArgs)
    end.

run_zomp(RunArgs) ->
    {ok, Dirs} = file:list_dir(zx_lib:path(lib, "otpr", "zomp")),
    Versions = lists:foldl(fun tuplize/2, [], Dirs),
    case zx_lib:find_latest_compatible({z, z, z}, Versions) of
        not_found    -> {error, not_found};
        {ok, Latest} -> run3({"otpr", "zomp", Latest}, RunArgs)
    end.

tuplize(String, Acc) ->
    case zx_lib:string_to_version(String) of
        {ok, Version} -> [Version | Acc];
        _             -> Acc
    end.


run2(FuzzyID, RunArgs) ->
    case resolve_version(FuzzyID) of
        {fetch, PackageID}     -> run3(PackageID, RunArgs);
        {installed, PackageID} -> run4(PackageID, RunArgs);
        Error                  -> Error
    end.

run3(PackageID, RunArgs) ->
    case fetch(PackageID) of
        ok    -> run4(PackageID, RunArgs);
        Error -> Error
    end.

run4(PackageID, RunArgs) ->
    Dir = zx_lib:ppath(lib, PackageID),
    {ok, Meta} = zx_lib:read_project_meta(Dir),
    case pre_prep(Meta, RunArgs) of
        {Type, Deps, NewArgs} -> run5(Type, PackageID, Meta, Dir, Deps, NewArgs);
        Error                 -> Error
    end.

run5(Type, PackageID, Meta, Dir, Deps, NewArgs) ->
    true = os:putenv("zx_include", filename:join(os:getenv("ZX_DIR"), "include")),
    Required = [{fetch, PackageID} | Deps],
    {ok, CWD} = file:get_cwd(),
    case prepare(Required) of
        ok ->
            ok = file:set_cwd(CWD),
            execute(Type, PackageID, Meta, Dir, NewArgs);
        Error ->
            Error
    end.


-spec resolve_version(PackageID) -> Result
    when PackageID :: package_id(),
         Result    :: not_found
                    | exact
                    | {ok, Installed :: version()}.
%% @private
%% Resolve the provided PackageID to the latest matching installed package directory
%% version if one exists, returning a value that indicates whether an exact match was
%% found (in the case of a full version input), a version matching a partial version
%% input was found, or no match was found at all.

resolve_version(PackageID = {_, _, {X, Y, Z}})
        when is_integer(X), is_integer(Y), is_integer(Z) ->
    case zx_lib:installed(PackageID) of
        true  -> {installed, PackageID};
        false -> {fetch, PackageID}
    end;
resolve_version(PackageID = {Realm, Name, _}) ->
    {ok, ID} = zx_daemon:latest(PackageID),
    case zx_daemon:wait_result(ID) of
        {ok, Latest} -> resolve_version({Realm, Name, Latest});
        Error        -> Error
    end.


-spec run_local(RunArgs) -> zx:outcome() | no_return()
    when RunArgs :: [string()].
%% @private
%% Execute a local project from source from the current directory, satisfying dependency
%% requirements via the locally installed zomp lib cache. The project must be
%% initialized as a zomp project (it must have a valid `zomp.meta' file).
%%
%% The most common use case for this function is during development. Using zomp support
%% via the local lib cache allows project authors to worry only about their own code
%% and use zx commands to add or drop dependencies made available via zomp.

run_local(RunArgs) ->
    try   run_local1(RunArgs)
    catch C:E:S -> {error, C, E, S}
    end.

run_local1(RunArgs) ->
    {ok, ProjectDir} = file:get_cwd(),
    run_project(ProjectDir, ProjectDir, RunArgs).


-spec run_dir(TargetDir, RunArgs) -> zx:outcome() | no_return()
    when TargetDir :: file:filename(),
         RunArgs   :: [string()].

run_dir(TargetDir, RunArgs) ->
    try   run_dir1(TargetDir, RunArgs)
    catch C:E:S -> {error, C, E, S}
    end.

run_dir1(TargetDir, RunArgs) ->
    {ok, ExecDir} = file:get_cwd(),
    case file:set_cwd(TargetDir) of
        ok ->
            {ok, ProjectDir} = file:get_cwd(), 
            run_project(ProjectDir, ExecDir, RunArgs);
        Error ->
            Error
    end.


-spec run_project(ProjectDir, ExecDir, RunArgs) -> zx:outcome() | no_return()
    when ProjectDir :: file:filename(),
         ExecDir    :: file:filename(),
         RunArgs    :: [string()].

run_project(ProjectDir, ExecDir, RunArgs) ->
    case zx_lib:read_project_meta() of
        {ok, Meta} -> run_project(ProjectDir, ExecDir, RunArgs, Meta);
        Error      -> Error
    end.

run_project(ProjectDir, ExecDir, RunArgs, Meta) ->
    true = os:putenv("zx_include", filename:join(os:getenv("ZX_DIR"), "include")),
    case pre_prep(Meta, RunArgs) of
        {Type, Deps, NewArgs} ->
            {ok, Dir} = file:get_cwd(),
            PackageID = {_, Name, _} = maps:get(package_id, Meta),
            true = os:putenv(Name ++ "_include", filename:join(Dir, "include")),
            case prepare(Deps) of
                ok ->
                    ok = file:set_cwd(ProjectDir),
                    case zx_lib:build() of
                        ok ->
                            ok = file:set_cwd(ExecDir),
                            execute(Type, PackageID, Meta, ProjectDir, NewArgs);
                        error ->
                            {error, build_failed}
                        end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.


-spec pre_prep(Meta, RunArgs) -> {Type, Deps, NewArgs} | {error, term()}
    when Meta    :: zx_zsp:meta(),
         RunArgs :: [string()],
         Type    :: package_type(),
         Deps    :: [package_id()],
         NewArgs :: [string()].

pre_prep(Meta, ["--libs=" ++ LibString | RunArgs]) ->
    pre_prep2(Meta, lib_split(LibString), RunArgs);
pre_prep(Meta, RunArgs) ->
    pre_prep2(Meta, [], RunArgs).

lib_split(String) ->
    lib_split(String, [], []).

lib_split([$: | Rest], Dep, Deps) ->
    {Next, NewDeps} = dep_split(Rest, lists:reverse(Dep), [], Deps),
    lib_split(Next, [], NewDeps);
lib_split([C | Rest], Dep, Deps) ->
    lib_split(Rest, [C | Dep], Deps);
lib_split([], [], Deps) ->
    Deps.

dep_split([$, | Rest], Dep, Dir, Deps) ->
    {Rest, [{Dep, lists:reverse(Dir)} | Deps]};
dep_split([C | Rest], Dep, Dir, Deps) ->
    dep_split(Rest, Dep, [C | Dir], Deps);
dep_split([], Dep, Dir, Deps) ->
    {[], [{Dep, lists:reverse(Dir)} | Deps]}.

pre_prep2(Meta, Local, RunArgs) ->
    Type = maps:get(type, Meta),
    Deps = maps:get(deps, Meta),
    MarkedDeps = lists:map(mark(Local), Deps),
    {Type, MarkedDeps, RunArgs}.

mark(LocalDeps) ->
    fun(Dep) ->
        case is_local(Dep, LocalDeps) of
            {true, Dir}  -> {local, Dep, Dir};
            false        -> {fetch, Dep}
        end
    end.

is_local({_, N, _}, [{N, Dir} | _]) -> {true, Dir};
is_local(D,         [_ | T])        -> is_local(D, T);
is_local(_,         [])             -> false.


-spec prepare(Deps) -> ok
    when Deps :: [Dep],
         Dep  :: {local, zx:package_id(), file:filename()}
               | {fetch, zx:package_id()}.
%% @private
%% Execution prep common to all packages.

prepare(Deps) ->
    case ensure(Deps) of
        ok    -> make(Deps);
        Error -> Error
    end.

ensure([{fetch, Dep} | Rest]) ->
    case filelib:is_dir(zx_lib:ppath(lib, Dep)) of
        true ->
            true = include_env(Dep),
            ensure(Rest);
        false ->
            acquire(Dep, Rest)
    end;
ensure([{local, {_, Name, _}, Dir} | Rest]) ->
    IncludeName = Name ++ "_include",
    IncludePath = filename:join(Dir, "include"),
    true = os:putenv(IncludeName, IncludePath),
    ensure(Rest);
ensure([]) ->
    ok.

acquire(Dep, Rest) ->
    case fetch(Dep) of
        ok ->
            true = include_env(Dep),
            ensure(Rest);
        Error ->
            Error
    end.


make([{fetch, Dep} | Rest]) ->
    case zx_daemon:build(Dep) of
        ok    -> make(Rest);
        Error -> Error
    end;
make([{local, _, Dir} | Rest]) ->
    {ok, WorkingDir} = file:get_cwd(),
    case file:set_cwd(Dir) of
        ok ->
            case zx_lib:build() of
                ok ->
                    ok = file:set_cwd(WorkingDir),
                    make(Rest);
                error ->
                    {error, build_failed}
            end;
        Error = {error, enoent} ->
            ok = tell(error, "Dir ~p does not exist!", [Dir]),
            Error
    end;
make([]) ->
    ok.


include_env(PackageID = {_, Name, _}) ->
    IncludeName = Name ++ "_include",
    IncludePath = filename:join(zx_lib:ppath(lib, PackageID), "include"),
    os:putenv(IncludeName, IncludePath).


-spec upgrade() -> zx:outcome().
%% @private
%% Upgrade ZX itself to the latest version.

upgrade() ->
    ZxDir = os:getenv("ZX_DIR"),
    {ok, Meta} = zx_lib:read_project_meta(ZxDir),
    PackageID = {Realm, Name, Current} = maps:get(package_id, Meta),
    {ok, PackageString} = zx_lib:package_string(PackageID),
    ok = tell("Current version: ~s", [PackageString]),
    {ok, ID} = zx_daemon:latest({Realm, Name}),
    case zx_daemon:wait_result(ID) of
        {ok, Current} ->
            tell("Running latest version.");
        {ok, Latest} when Latest > Current ->
            NewID = {Realm, Name, Latest},
            ok = ensure([{fetch, NewID}]),
            {ok, LatestString} = zx_lib:version_to_string(Latest),
            ok = tell(info, "Acquiring upgrade: ~s", [LatestString]),
            VersionTxt = filename:join(zx_lib:path(etc), "version.txt"),
            ok = file:write_file(VersionTxt, LatestString),
            {ok, NewString} = zx_lib:package_string(NewID),
            tell("Upgraded to ~s.", [NewString]);
        {ok, Available} when Available < Current ->
            {ok, AvailableString} = zx_lib:version_to_string(Available),
            Message = "Local version is newer than ~s. Nothing to do.",
            tell(Message, [AvailableString]);
        Error ->
            Error
    end.


-spec fetch(zx:package_id()) -> zx:outcome().

fetch(PackageID) ->
    {ok, PackageName} = zx_lib:package_string(PackageID),
    ok = tell("Fetching ~ts", [PackageName]),
    {ok, ID} = zx_daemon:fetch(PackageID, [self()]),
    fetch2(ID).

fetch2(ID) ->
    receive
        {result, ID, done} ->
            ok;
        {rx, Size, Received} ->
            ok = zx_tty:dl(Size, Received),
            fetch2(ID);
        {rx, done} ->
            ok = zx_tty:dl(1, 1),
            fetch2(ID);
        {rx, overflow} ->
            {error, overflow};
        {result, ID, {hops, Count}} ->
            ok = tell("Inbound; ~w hops away.", [Count]),
            fetch2(ID);
        {result, ID, Error} ->
            Error
        after 30000 ->
            {error, timeout}
    end.


-spec execute(Type, PackageID, Meta, Dir, RunArgs) -> no_return()
    when Type      :: app | cli | gui | lib,
         PackageID :: package_id(),
         Meta      :: zx_zsp:meta(),
         Dir       :: file:filename(),
         RunArgs   :: [string()].
%% @private
%% Gets all the target application's ducks in a row and launches them, then enters
%% the exec_wait/1 loop to wait for any queries from the application.

execute(gui, PackageID, Meta, Dir, RunArgs) ->
    case wx_available() of
        true  -> execute(PackageID, Meta, Dir, RunArgs);
        false -> {error, "WX (GUI system) is not found. Aborting."}
    end;
execute(cli, PackageID, Meta, Dir, RunArgs) ->
    Name = element(2, PackageID),
    ok = zx_daemon:pass_meta(Meta, Dir, RunArgs),
    AppTag = list_to_atom(Name),
    {ok, _} = application:ensure_all_started(AppTag, permanent),
    case maps:get(mod, Meta, none) of
        none ->
            {error, "No executable module"};
        ModName ->
            Mod = list_to_atom(ModName),
            Mod:start(RunArgs)
    end;
execute(app, PackageID, Meta, Dir, RunArgs) ->
    execute(PackageID, Meta, Dir, RunArgs);
execute(lib, PackageID, _, _, _) ->
    Message = "Lib ~ts is available on the system, but is not a standalone app.",
    {ok, PackageString} = zx_lib:package_string(PackageID),
    ok = tell(Message, [PackageString]),
    init:stop().

execute(PackageID, Meta, Dir, RunArgs) ->
    {ok, PackageString} = zx_lib:package_string(PackageID),
    ok = tell("Starting ~ts.", [PackageString]),
    Name = element(2, PackageID),
    ok = zx_daemon:pass_meta(Meta, Dir, RunArgs),
    AppTag = list_to_atom(Name),
    ok = ensure_all_started(AppTag, permanent),
    log(info, "Launcher complete.").

wx_available() ->
    try
        _ = wx:null(),
        true
    catch
        error:undef ->
        false
    end.


-spec ensure_all_started(AppMod, Type) -> ok
    when AppMod :: module(),
         Type   :: application:restart_type().
%% @private
%% Wrap a call to application:ensure_all_started/1 to selectively provide output
%% in the case any dependencies are actually started by the call. Might remove this
%% depending on whether SASL winds up becoming a standard part of the system and
%% whether it becomes common for dependencies to all signal their own start states
%% somehow.

ensure_all_started(AppMod, Type) ->
    case application:ensure_all_started(AppMod, Type) of
        {ok, []}   -> ok;
        {ok, Apps} -> tell("Started ~160tp", [Apps])
    end.



%%% Usage

help(top)   -> show_help();
help(user)  -> show_help([usage_header(), usage_user(), usage_spec()]);
help(dev)   -> show_help([usage_header(), usage_dev(), usage_spec()]);
help(sysop) -> show_help([usage_header(), usage_sysop(), usage_spec()]).


show_help() ->
    T =
        "ZX help has three forms, one for each category of commands:~n"
        "    zx help [user | dev | sysop]~n"
        "The user manual is also available online at: http://zxq9.com/projects/zomp/~n",
    io:format(T).


show_help(Info) -> lists:foreach(fun io:format/1, Info).


usage_header() ->
    "ZX usage: zx [command] [object] [args]~n~n".

usage_user() ->
    "User Actions:~n"
    "  zx run PackageID [Args]~n"
    "  zx integrate desktop PackageID~n"
    "  zx list realms~n"
    "  zx list packages Realm~n"
    "  zx list versions PackageID~n"
    "  zx list [gui | cli | app | lib]~n"
    "  zx latest PackageID~n"
    "  zx search Tag~n"
    "  zx describe Package~n"
    "  zx upgrade~n"
    "  zx import realm RealmFile~n"
    "  zx drop realm Realm~n"
    "  zx add mirror [Address [Port]]~n"
    "  zx drop mirror [Address [Port]]~n"
    "  zx --version~n~n".

usage_dev() ->
    "Developer/Packager/Maintainer Actions:~n"
    "  zx create project~n"
    "  zx template swp~n"
    "  zx runlocal [Args]~n"
    "  zx rundir Path [Args]~n"
    "  zx init~n"
    "  zx list deps [PackageID]~n"
    "  zx set dep PackageID~n"
    "  zx drop dep PackageID~n"
    "  zx verup Level~n"
    "  zx set version Version~n"
    "  zx provides Module~n"
    "  zx update meta~n"
    "  zx update .app~n"
    "  zx package [Path]~n"
    "  zx submit ZSP~n"
    "  zx list pending PackageName~n"
    "  zx review PackageID~n"
    "  zx approve PackageID~n"
    "  zx reject PackageID~n"
    "  zx create user~n"
    "  zx create keypair~n"
    "  zx export user [dangerous]~n"
    "  zx import user ZDUF~n"
    "  zx list users Realm~n"
    "  zx list packagers PackageName~n"
    "  zx list maintainers PackageName~n"
    "  zx list sysops Realm~n"
    "  zx export realm [Realm]~n"
    "  zx install ZSP~n~n".

usage_sysop() ->
    "Sysop Actions:~n"
    "  zx list approved Realm~n"
    "  zx accept ZSP~n"
    "  zx add package PackageName~n"
    "  zx add user ZPUF~n"
    "  zx rem user Realm UserName~n"
    "  zx add packager PackageName UserName~n"
    "  zx rem packager PackageName UserName~n"
    "  zx add maintainer PackageName UserName~n"
    "  zx rem maintainer PackageName UserName~n"
    "  zx create realm~n"
    "  zx takeover Realm~n"
    "  zx abdicate Realm~n~n".

usage_spec() ->
    "Where~n"
    "  PackageID   :: A string of the form [Realm-]Name[-Version]~n"
    "  PackageName :: A string that matches [^[a-z]a-z0-9_]~n"
    "  UserName    :: A string that matches [^[a-z]a-z0-9_]~n"
    "  Args        :: Arguments to pass to the application~n"
    "  Type        :: The project type: a standalone \"app\" or a \"lib\"~n"
    "  Version     :: Version string X, X.Y, or X.Y.Z: \"1\", \"1.2\", \"1.2.3\"~n"
    "  RealmFile   :: Path to a valid .zrf realm file~n"
    "  Realm       :: The name of a realm as a string [:a-z:]~n"
    "  Module      :: Name of a code module.~n"
    "  KeyName     :: The prefix of a keypair~n"
    "  Level       :: The version level, one of \"major\", \"minor\", or \"patch\"~n"
    "  Path        :: Path or filename.~n"
    "  ZSP         :: Path to a .zsp file (Zomp Source Package).~n"
    "  ZPUF        :: Path to a .zpuf file (Zomp Public User File).~n"
    "  ZDUF        :: Path to a .zduf file (Zomp DANGEROUS User File).~n".


version() ->
    io:format("zx ~ts~n", [os:getenv("ZX_VERSION")]).
