%%--------------------------------------------------------------------
%% Managed Wikimedia fixture HTTP server for ECAI integration and BDD tests.
%%
%% The server is an OTP worker supervised by ecai_sup when enabled. It starts
%% a loopback-only Cowboy listener, discovers immutable fixture files from the
%% ECAI priv directory, writes a pinned local Wikimedia catalog, and exposes
%% health/status metadata for operator tooling.
%%
%% The listener is intentionally separate from the authenticated ECAI API:
%% fixture files are public test inputs, while the listener binds to loopback
%% by default and refuses non-loopback binding unless explicitly allowed.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_fixture_server).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    child_spec/0,
    child_spec/1,
    start_supervised/1,
    start_supervised/2,
    stop/0,
    stop/1,
    status/0,
    status/1,
    reload/0,
    reload/1,
    catalog_path/0,
    catalog_path/1,
    catalog_url/0,
    catalog_url/1,
    base_url/0,
    base_url/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_LISTENER_REF, ecai_wikimedia_fixture_http).
-define(DEFAULT_IP, {127, 0, 0, 1}).
-define(DEFAULT_PORT, 9876).
-define(DEFAULT_PROJECT, <<"enwiki">>).
-define(DEFAULT_PAGEVIEW_PROJECT, <<"en.wikipedia">>).
-define(CATALOG_SCHEMA, <<"ecai-wikimedia-catalog/v1">>).
-define(CATALOG_NAME, <<"wikimedia-catalog.json">>).
-define(CALL_TIMEOUT, 5000).

-type server() :: pid() | atom().

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

-spec child_spec() -> map().
child_spec() ->
    child_spec(#{}).

-spec child_spec(map()) -> map().
child_spec(Opts) when is_map(Opts) ->
    Start = case map_size(Opts) of
        0 -> {?MODULE, start_link, []};
        _ -> {?MODULE, start_link, [Opts]}
    end,
    #{
        id => ?MODULE,
        start => Start,
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

-spec start_supervised(pid() | atom()) -> ok | {error, term()}.
start_supervised(Supervisor) ->
    start_supervised(Supervisor, #{}).

-spec start_supervised(pid() | atom(), map()) -> ok | {error, term()}.
start_supervised(Supervisor, Opts) when is_map(Opts) ->
    case supervisor:start_child(Supervisor, child_spec(Opts)) of
        {ok, _Pid} ->
            ok;
        {ok, _Pid, _Info} ->
            ok;
        {error, {already_started, Pid}} ->
            case supervisor_owns_child(Supervisor, Pid) of
                true -> ok;
                false -> {error, {fixture_process_not_supervised, Pid}}
            end;
        {error, already_present} ->
            case supervisor:restart_child(Supervisor, ?MODULE) of
                {ok, _Pid} -> ok;
                {ok, _Pid, _Info} -> ok;
                {error, running} -> ok;
                {error, Reason} ->
                    {error, {fixture_child_restart_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {fixture_child_start_failed, Reason}}
    end;
start_supervised(_Supervisor, _Opts) ->
    {error, badarg}.

supervisor_owns_child(Supervisor, _Pid) ->
    try supervisor:which_children(Supervisor) of
        Children ->
            lists:any(
                fun
                    ({?MODULE, _Pid0, worker, _Modules}) -> true;
                    (_) -> false
                end,
                Children
            )
    catch
        exit:_Reason -> false
    end.

%% start_link/1 is useful for isolated EUnit fixtures. It deliberately does not
%% register the process, allowing multiple independent servers in one VM.
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, Opts, []);
start_link(_Opts) ->
    {error, badarg}.

-spec stop() -> ok | {error, not_running}.
stop() ->
    case whereis(?MODULE) of
        undefined -> {error, not_running};
        Pid -> stop(Pid)
    end.

-spec stop(server()) -> ok.
stop(Server) ->
    gen_server:stop(Server).

-spec status() -> map() | {error, not_running}.
status() ->
    case whereis(?MODULE) of
        undefined -> {error, not_running};
        Pid -> status(Pid)
    end.

-spec status(server()) -> map().
status(Server) ->
    gen_server:call(Server, status, ?CALL_TIMEOUT).

-spec reload() -> {ok, map()} | {error, term()}.
reload() ->
    case whereis(?MODULE) of
        undefined -> {error, not_running};
        Pid -> reload(Pid)
    end.

-spec reload(server()) -> {ok, map()} | {error, term()}.
reload(Server) ->
    gen_server:call(Server, reload, infinity).

-spec catalog_path() -> {ok, binary()} | {error, not_running}.
catalog_path() ->
    case whereis(?MODULE) of
        undefined -> {error, not_running};
        Pid -> catalog_path(Pid)
    end.

-spec catalog_path(server()) -> {ok, binary()}.
catalog_path(Server) ->
    gen_server:call(Server, catalog_path, ?CALL_TIMEOUT).

-spec catalog_url() -> {ok, binary()} | {error, not_running}.
catalog_url() ->
    case whereis(?MODULE) of
        undefined -> {error, not_running};
        Pid -> catalog_url(Pid)
    end.

-spec catalog_url(server()) -> {ok, binary()}.
catalog_url(Server) ->
    gen_server:call(Server, catalog_url, ?CALL_TIMEOUT).

-spec base_url() -> {ok, binary()} | {error, not_running}.
base_url() ->
    case whereis(?MODULE) of
        undefined -> {error, not_running};
        Pid -> base_url(Pid)
    end.

-spec base_url(server()) -> {ok, binary()}.
base_url(Server) ->
    gen_server:call(Server, base_url, ?CALL_TIMEOUT).

init(Opts0) ->
    process_flag(trap_exit, true),
    case ensure_runtime_dependencies([crypto, cowboy]) of
        ok ->
            init_server(Opts0);
        {error, Reason} ->
            {stop, Reason}
    end.

init_server(Opts0) ->
    case normalize_options(Opts0) of
        {ok, Opts0a} ->
            case choose_port(Opts0a) of
                {ok, Port} ->
                    Opts = Opts0a#{port => Port},
                    case prepare_fixture_state(Opts) of
                        {ok, Prepared} ->
                            start_listener(Prepared);
                        {error, Reason} ->
                            {stop, Reason}
                    end;
                {error, Reason} ->
                    {stop, Reason}
            end;
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(status, _From, State) ->
    {reply, public_status(State), State};
handle_call(catalog_path, _From, State) ->
    {reply, {ok, maps:get(catalog_path_bin, State)}, State};
handle_call(catalog_url, _From, State) ->
    {reply, {ok, maps:get(catalog_url, State)}, State};
handle_call(base_url, _From, State) ->
    {reply, {ok, maps:get(base_url, State)}, State};
handle_call(reload, _From, State0) ->
    case prepare_fixture_state(maps:get(options, State0)) of
        {ok, Prepared} ->
            Dispatch = build_dispatch(self(), Prepared),
            ListenerRef = maps:get(listener_ref, State0),
            case cowboy:set_env(ListenerRef, dispatch, Dispatch) of
                ok ->
                    State1 = merge_prepared(State0, Prepared),
                    {reply, {ok, public_status(State1)}, State1};
                {error, Reason} ->
                    {reply, {error, {fixture_dispatch_reload_failed, Reason}}, State0}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State0}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(
    {'DOWN', Monitor, process, ListenerPid, Reason},
    #{listener_monitor := Monitor, listener_pid := ListenerPid} = State
) ->
    {stop, {fixture_listener_exit, Reason}, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case maps:get(listener_monitor, State, undefined) of
        undefined -> ok;
        Monitor -> _ = erlang:demonitor(Monitor, [flush]), ok
    end,
    case maps:get(listener_ref, State, undefined) of
        undefined -> ok;
        ListenerRef ->
            _ = try cowboy:stop_listener(ListenerRef) of
                ok -> ok;
                {error, not_found} -> ok;
                _Other -> ok
            catch
                _:_ -> ok
            end,
            ok
    end.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

start_listener(Prepared) ->
    Opts = maps:get(options, Prepared),
    ListenerRef = maps:get(listener_ref, Opts),
    Ip = maps:get(ip, Opts),
    Port = maps:get(port, Opts),
    Dispatch = build_dispatch(self(), Prepared),
    TransportOpts = [{ip, Ip}, {port, Port}],
    ProtocolOpts = #{
        env => #{dispatch => Dispatch},
        idle_timeout => maps:get(idle_timeout_ms, Opts)
    },
    case cowboy:start_clear(ListenerRef, TransportOpts, ProtocolOpts) of
        {ok, ListenerPid} ->
            ListenerMonitor = erlang:monitor(process, ListenerPid),
            StartedAt = erlang:system_time(millisecond),
            State = Prepared#{
                listener_ref => ListenerRef,
                listener_pid => ListenerPid,
                listener_monitor => ListenerMonitor,
                started_at_ms => StartedAt
            },
            ?LOG_INFO(
                "Started managed Wikimedia fixture server at ~ts (catalog=~ts)",
                [maps:get(base_url, State), maps:get(catalog_path_bin, State)]
            ),
            {ok, State};
        {error, Reason} ->
            {stop, {fixture_listener_start_failed, ListenerRef, Ip, Port, Reason}}
    end.

prepare_fixture_state(Opts) ->
    FixtureDir = maps:get(fixture_dir, Opts),
    RuntimeDir = maps:get(runtime_dir, Opts),
    case discover_sources(FixtureDir, Opts) of
        {ok, Discovery} ->
            BaseUrl = make_base_url(
                maps:get(public_host, Opts),
                maps:get(port, Opts)
            ),
            CatalogPath = filename:join(RuntimeDir, binary_to_list(?CATALOG_NAME)),
            Catalog = build_catalog(Discovery, BaseUrl, Opts),
            case write_catalog(CatalogPath, Catalog) of
                ok ->
                    case file_entry(
                        ?CATALOG_NAME,
                        CatalogPath,
                        <<"application/json; charset=utf-8">>
                    ) of
                        {ok, CatalogEntry} ->
                            SourceEntries = maps:get(entries, Discovery),
                            {ok, #{
                                options => Opts,
                                fixture_dir => FixtureDir,
                                runtime_dir => RuntimeDir,
                                base_url => BaseUrl,
                                health_url => <<BaseUrl/binary, "/_ecai/fixture/health">>,
                                status_url => <<BaseUrl/binary, "/_ecai/fixture/status">>,
                                catalog_url => <<BaseUrl/binary, "/", ?CATALOG_NAME/binary>>,
                                catalog_path => CatalogPath,
                                catalog_path_bin => unicode:characters_to_binary(CatalogPath),
                                catalog => Catalog,
                                catalog_entry => CatalogEntry,
                                source_entries => SourceEntries,
                                discovery => Discovery
                            }};
                        {error, Reason} ->
                            {error, {fixture_catalog_metadata_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {fixture_catalog_write_failed, CatalogPath, Reason}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

merge_prepared(State, Prepared) ->
    maps:merge(
        State,
        maps:without(
            [listener_ref, listener_pid, listener_monitor, started_at_ms],
            Prepared
        )
    ).

build_dispatch(Server, Prepared) ->
    CatalogEntry = maps:get(catalog_entry, Prepared),
    SourceEntries = maps:get(source_entries, Prepared),
    FileRoutes = [
        {
            "/" ++ binary_to_list(maps:get(name, Entry)),
            ecai_wikimedia_fixture_handler,
            #{action => file, entry => Entry}
        }
     || Entry <- [CatalogEntry | SourceEntries]
    ],
    Routes = [
        {
            "/healthz",
            ecai_wikimedia_fixture_handler,
            #{action => health, server => Server}
        },
        {
            "/_ecai/fixture/health",
            ecai_wikimedia_fixture_handler,
            #{action => health, server => Server}
        },
        {
            "/_ecai/fixture/status",
            ecai_wikimedia_fixture_handler,
            #{action => status, server => Server}
        }
        | FileRoutes
    ],
    cowboy_router:compile([{'_', Routes}]).

ensure_runtime_dependencies([]) ->
    ok;
ensure_runtime_dependencies([Application | Rest]) ->
    case application:ensure_all_started(Application) of
        {ok, _Started} ->
            ensure_runtime_dependencies(Rest);
        {error, Reason} ->
            {error, {fixture_dependency_start_failed, Application, Reason}}
    end.

normalize_options(Opts0) ->
    try
        Ip = option(ip, Opts0, wikimedia_fixture_ip, ?DEFAULT_IP),
        Port = option(port, Opts0, wikimedia_fixture_port, ?DEFAULT_PORT),
        AllowNonLoopback = option(
            allow_non_loopback,
            Opts0,
            wikimedia_fixture_allow_non_loopback,
            false
        ),
        ok = validate_ip(Ip, AllowNonLoopback),
        ok = validate_port(Port),
        FixtureDir = absolute_path(option(
            fixture_dir,
            Opts0,
            wikimedia_fixture_dir,
            default_fixture_dir()
        )),
        RuntimeDir = absolute_path(option(
            runtime_dir,
            Opts0,
            wikimedia_fixture_runtime_dir,
            default_runtime_dir()
        )),
        Project = required_token(option(
            project,
            Opts0,
            wikimedia_fixture_project,
            ?DEFAULT_PROJECT
        )),
        PageviewProject = required_token(option(
            pageview_project,
            Opts0,
            wikimedia_fixture_pageview_project,
            ?DEFAULT_PAGEVIEW_PROJECT
        )),
        PublicHost = normalize_public_host(option(
            public_host,
            Opts0,
            wikimedia_fixture_public_host,
            ip_to_binary(Ip)
        )),
        ListenerRef = listener_ref(maps:get(
            listener_ref,
            Opts0,
            ?DEFAULT_LISTENER_REF
        )),
        IdleTimeout = bounded_integer(option(
            idle_timeout_ms,
            Opts0,
            wikimedia_fixture_idle_timeout_ms,
            60000
        ), 1000, 3600000),
        {ok, #{
            ip => Ip,
            port => Port,
            public_host => PublicHost,
            fixture_dir => FixtureDir,
            runtime_dir => RuntimeDir,
            project => Project,
            pageview_project => PageviewProject,
            listener_ref => ListenerRef,
            idle_timeout_ms => IdleTimeout,
            allow_non_loopback => AllowNonLoopback
        }}
    catch
        throw:{fixture_config_error, Reason} -> {error, Reason};
        error:badarg -> {error, invalid_fixture_configuration}
    end.

option(Key, Opts, EnvKey, Default) ->
    case maps:find(Key, Opts) of
        {ok, Value} -> Value;
        error -> application:get_env(ecai, EnvKey, Default)
    end.

validate_ip(Ip, AllowNonLoopback) when is_tuple(Ip), tuple_size(Ip) =:= 4 ->
    case AllowNonLoopback orelse is_loopback(Ip) of
        true -> ok;
        false -> config_error({fixture_non_loopback_binding_rejected, Ip})
    end;
validate_ip(Ip, AllowNonLoopback) when is_tuple(Ip), tuple_size(Ip) =:= 8 ->
    case AllowNonLoopback orelse is_loopback(Ip) of
        true -> ok;
        false -> config_error({fixture_non_loopback_binding_rejected, Ip})
    end;
validate_ip(Ip, _AllowNonLoopback) ->
    config_error({invalid_fixture_ip, Ip}).

is_loopback({127, _, _, _}) -> true;
is_loopback({0, 0, 0, 0, 0, 0, 0, 1}) -> true;
is_loopback(_) -> false.

validate_port(Port) when is_integer(Port), Port >= 0, Port =< 65535 -> ok;
validate_port(Port) -> config_error({invalid_fixture_port, Port}).

listener_ref(Ref) when is_atom(Ref) -> Ref;
listener_ref(Ref) -> config_error({invalid_fixture_listener_ref, Ref}).

choose_port(#{port := 0, ip := Ip}) ->
    reserve_ephemeral_port(Ip);
choose_port(#{port := Port}) ->
    {ok, Port}.

reserve_ephemeral_port(Ip) ->
    Family = case tuple_size(Ip) of
        8 -> [inet6];
        _ -> []
    end,
    case gen_tcp:listen(
        0,
        Family ++ [binary, {active, false}, {reuseaddr, true}, {ip, Ip}]
    ) of
        {ok, Socket} ->
            Result = case inet:sockname(Socket) of
                {ok, {_Address, Port}} -> {ok, Port};
                {error, Reason} -> {error, {fixture_ephemeral_port_failed, Reason}}
            end,
            ok = gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, {fixture_ephemeral_port_failed, Reason}}
    end.

discover_sources(FixtureDir, Opts) ->
    case file:list_dir(FixtureDir) of
        {ok, Names0} ->
            Names = lists:sort(Names0),
            Project = maps:get(project, Opts),
            ContentMatches = [
                Match
             || Name <- Names,
                Match <- [parse_content_fixture(Name, Project)],
                Match =/= no_match
            ],
            PageviewMatches = [
                Match
             || Name <- Names,
                Match <- [parse_pageview_fixture(Name)],
                Match =/= no_match
            ],
            finalize_discovery(FixtureDir, ContentMatches, PageviewMatches);
        {error, Reason} ->
            {error, {fixture_directory_unavailable, FixtureDir, Reason}}
    end.

parse_content_fixture(Name, Project) ->
    NameBin = unicode:characters_to_binary(Name),
    case re:run(
        NameBin,
        <<"^([A-Za-z0-9._-]+)_content-([0-9]{8})-([0-9]{5})\\.json\\.bz2$">>,
        [{capture, [1, 2, 3], binary}]
    ) of
        {match, [Project, Release, Shard]} ->
            #{kind => content, name => NameBin, release => Release, shard => Shard};
        {match, [_OtherProject, _Release, _Shard]} ->
            no_match;
        nomatch ->
            no_match
    end.

parse_pageview_fixture(Name) ->
    NameBin = unicode:characters_to_binary(Name),
    case re:run(
        NameBin,
        <<"^pageviews-([0-9]{4})([0-9]{2})-user\\.bz2$">>,
        [{capture, [1, 2], binary}]
    ) of
        {match, [Year, Month]} ->
            MonthNo = binary_to_integer(Month),
            case MonthNo >= 1 andalso MonthNo =< 12 of
                true ->
                    #{
                        kind => pageview,
                        name => NameBin,
                        month => <<Year/binary, "-", Month/binary>>
                    };
                false ->
                    no_match
            end;
        nomatch ->
            no_match
    end.

finalize_discovery(_FixtureDir, [], _Pageviews) ->
    {error, no_wikimedia_content_fixtures};
finalize_discovery(_FixtureDir, _Content, []) ->
    {error, no_wikimedia_pageview_fixtures};
finalize_discovery(FixtureDir, Content0, Pageviews0) ->
    Releases = lists:usort([maps:get(release, Item) || Item <- Content0]),
    case Releases of
        [Release] ->
            Content = lists:sort(fun compare_name/2, Content0),
            Pageviews = lists:sort(fun compare_month/2, Pageviews0),
            case build_file_entries(FixtureDir, Content ++ Pageviews, []) of
                {ok, Entries} ->
                    {ok, #{
                        release => Release,
                        content => Content,
                        pageviews => Pageviews,
                        entries => Entries
                    }};
                {error, _Reason} = Error -> Error
            end;
        _ ->
            {error, {mixed_wikimedia_content_releases, Releases}}
    end.

compare_name(A, B) -> maps:get(name, A) < maps:get(name, B).
compare_month(A, B) -> maps:get(month, A) < maps:get(month, B).

build_file_entries(_FixtureDir, [], Acc) ->
    {ok, lists:reverse(Acc)};
build_file_entries(FixtureDir, [Item | Rest], Acc) ->
    Name = maps:get(name, Item),
    Path = filename:join(FixtureDir, binary_to_list(Name)),
    case file_entry(Name, Path, <<"application/x-bzip2">>) of
        {ok, Entry} ->
            build_file_entries(FixtureDir, Rest, [maps:merge(Item, Entry) | Acc]);
        {error, Reason} ->
            {error, {fixture_file_invalid, Name, Reason}}
    end.

file_entry(Name, Path, ContentType) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} ->
            case hash_file(Path) of
                {ok, Digest} ->
                    Hex = hex(Digest),
                    {ok, #{
                        name => Name,
                        path => Path,
                        path_bin => unicode:characters_to_binary(Path),
                        content_type => ContentType,
                        size => Size,
                        sha256 => Hex,
                        etag => <<"\"sha256-", Hex/binary, "\"">>
                    }};
                {error, _Reason} = Error -> Error
            end;
        {ok, #file_info{type = Type}} ->
            {error, {not_regular_file, Type}};
        {error, Reason} ->
            {error, Reason}
    end.

build_catalog(Discovery, BaseUrl, Opts) ->
    Content = maps:get(content, Discovery),
    Pageviews = maps:get(pageviews, Discovery),
    ContentSources = [
        #{
            <<"ordinal">> => Ordinal,
            <<"name">> => maps:get(name, Item),
            <<"url">> => <<BaseUrl/binary, "/", (maps:get(name, Item))/binary>>
        }
     || {Item, Ordinal} <- lists:zip(Content, lists:seq(1, length(Content)))
    ],
    PageviewSources = [
        #{
            <<"ordinal">> => Ordinal,
            <<"month">> => maps:get(month, Item),
            <<"name">> => maps:get(name, Item),
            <<"url">> => <<BaseUrl/binary, "/", (maps:get(name, Item))/binary>>,
            <<"project">> => maps:get(pageview_project, Opts)
        }
     || {Item, Ordinal} <- lists:zip(Pageviews, lists:seq(1, length(Pageviews)))
    ],
    #{
        <<"schema">> => ?CATALOG_SCHEMA,
        <<"project">> => maps:get(project, Opts),
        <<"pageview_project">> => maps:get(pageview_project, Opts),
        <<"cirrus_release">> => maps:get(release, Discovery),
        <<"content_shards">> => ContentSources,
        <<"pageview_months">> => [maps:get(month, Item) || Item <- Pageviews],
        <<"pageview_sources">> => PageviewSources
    }.

write_catalog(Path, Catalog) ->
    ok = filelib:ensure_dir(Path),
    Bytes = <<(jsx:encode(Catalog))/binary, "\n">>,
    atomic_write(Path, Bytes).

atomic_write(Path, Bytes) ->
    Tmp = Path ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            Result = try
                ok = file:write(Fd, Bytes),
                file:sync(Fd)
            after
                ok = file:close(Fd)
            end,
            case Result of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok -> ok;
                        {error, Reason} ->
                            _ = file:delete(Tmp),
                            {error, {rename_failed, Reason}}
                    end;
                {error, _Reason} = Error ->
                    _ = file:delete(Tmp),
                    Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

hash_file(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} ->
            try hash_file_loop(Fd, crypto:hash_init(sha256))
            after
                ok = file:close(Fd)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

hash_file_loop(Fd, Context) ->
    case file:read(Fd, 1048576) of
        eof -> {ok, crypto:hash_final(Context)};
        {ok, Bytes} -> hash_file_loop(Fd, crypto:hash_update(Context, Bytes));
        {error, Reason} -> {error, Reason}
    end.

public_status(State) ->
    StartedAt = maps:get(started_at_ms, State, erlang:system_time(millisecond)),
    Now = erlang:system_time(millisecond),
    SourceEntries = maps:get(source_entries, State, []),
    #{
        ready => true,
        service => ecai_wikimedia_fixture_server,
        ip => ip_to_binary(maps:get(ip, maps:get(options, State))),
        port => maps:get(port, maps:get(options, State)),
        base_url => maps:get(base_url, State),
        health_url => maps:get(health_url, State),
        status_url => maps:get(status_url, State),
        catalog_url => maps:get(catalog_url, State),
        catalog_path => maps:get(catalog_path_bin, State),
        fixture_dir => unicode:characters_to_binary(maps:get(fixture_dir, State)),
        runtime_dir => unicode:characters_to_binary(maps:get(runtime_dir, State)),
        project => maps:get(project, maps:get(options, State)),
        pageview_project => maps:get(pageview_project, maps:get(options, State)),
        cirrus_release => maps:get(release, maps:get(discovery, State)),
        content_shards => length(maps:get(content, maps:get(discovery, State))),
        pageview_files => length(maps:get(pageviews, maps:get(discovery, State))),
        files => [
            maps:with([name, size, sha256, etag], Entry)
         || Entry <- SourceEntries
        ],
        started_at_ms => StartedAt,
        uptime_ms => erlang:max(0, Now - StartedAt)
    }.

make_base_url(Host0, Port) ->
    Host = case binary:match(Host0, <<":">>) of
        nomatch -> Host0;
        _ -> <<"[", Host0/binary, "]">>
    end,
    <<"http://", Host/binary, ":", (integer_to_binary(Port))/binary>>.

normalize_public_host(Value) ->
    Host = to_binary(Value),
    case byte_size(Host) > 0 andalso
        binary:match(Host, <<"/">>) =:= nomatch andalso
        binary:match(Host, <<"\0">>) =:= nomatch
    of
        true -> Host;
        false -> config_error({invalid_fixture_public_host, Value})
    end.

required_token(Value) ->
    Token = to_binary(Value),
    case byte_size(Token) > 0 andalso byte_size(Token) =< 128 andalso
        re:run(Token, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}]) =:= match
    of
        true -> Token;
        false -> config_error({invalid_fixture_token, Value})
    end.

absolute_path(Value) ->
    filename:absname(path_list(Value)).

default_fixture_dir() ->
    case code:priv_dir(ecai) of
        {error, Reason} -> config_error({fixture_priv_dir_unavailable, Reason});
        PrivDir -> filename:join(PrivDir, "wikimedia-fixtures")
    end.

default_runtime_dir() ->
    filename:join(temp_dir(), "ecai-wikimedia-fixture").

temp_dir() ->
    case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end.

bounded_integer(Value, Min, Max) when is_integer(Value), Value >= Min, Value =< Max ->
    Value;
bounded_integer(Value, Min, Max) ->
    config_error({invalid_fixture_integer, Value, Min, Max}).

ip_to_binary(Ip) ->
    case inet:ntoa(Ip) of
        {error, einval} -> config_error({invalid_fixture_ip, Ip});
        Chars -> unicode:characters_to_binary(Chars)
    end.

path_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    unicode:characters_to_list(Bin);
path_list(List) when is_list(List), List =/= [] ->
    List;
path_list(_Other) ->
    erlang:error(badarg).

to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) -> unicode:characters_to_binary(List);
to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(_Other) -> erlang:error(badarg).

hex(Bin) ->
    <<
        <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0F))>>
     || <<Byte:8>> <= Bin
    >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + (N - 10).

config_error(Reason) ->
    throw({fixture_config_error, Reason}).
