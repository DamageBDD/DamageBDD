%% Trusted operator configuration. sys.config uses tuples, never maps.
-module(damage_webdriver_runtime_config).
-include_lib("kernel/include/file.hrl").
-export([load/1, parse/2, name/1, private_dir/1, json/1]).

name(chromedriver) -> damage_webdriver_chromedriver;
name(appium) -> damage_webdriver_appium;
name(fixture) -> damage_webdriver_fixture.

load(Backend) -> parse(Backend, application:get_env(damage, webdriver_runtime, [])).

parse(Backend, P) ->
    try
        _ = name(Backend),
        check(P, [enabled, data_dir, python, bootstrap, offline,
            bootstrap_timeout_ms, ready_timeout_ms, health_interval_ms,
            health_failures, restart_delay_ms, max_restart_delay_ms, max_failures,
            chromedriver, appium, fixture]),
        Ports = [proplists:get_value(port, Settings, default_port(K)) ||
            K <- [chromedriver, appium, fixture],
            Settings <- [proplists:get_value(K, P, [])],
            proplists:get_value(enabled, Settings, false) =:= true],
        true = length(Ports) =:= length(lists:usort(Ports)),
        B = proplists:get_value(Backend, P, []),
        check(B, backend_keys(Backend)),
        Enabled = boolean(enabled, P, false) andalso boolean(enabled, B, false),
        Root = damage_config:normalize_path(text(proplists:get_value(data_dir, P,
            filename:join(damage_config:state_dir(), "webdriver")))),
        Python = text(proplists:get_value(python, P, "python3")),
        Port = integer(port, B, default_port(Backend), 1024, 65535),
        %% Unauthenticated automation services must not listen on public interfaces.
        Base = text(proplists:get_value(base_path, B, "/")),
        match(Base, "^/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]*$"),
        Dir = filename:join(Root, atom_to_list(Backend)),
        MaxSessions = integer(max_sessions, B, 1, 1, 32),
        Source = proplists:get_value(source, B, download),
        true = lists:member(Source, [download, system]),
        BaseDelay = integer(restart_delay_ms, P, 5000, 100, 300000),
        MaxDelay = integer(max_restart_delay_ms, P, 60000, BaseDelay, 3600000),
        Node = section(node, B, [source, version, executable, sha256]),
        Java = section(java, B, [source, home, url, sha256, subdir]),
        Android = section(android, B, [enabled, source, home, command_tools_url,
            sha256, packages, accept_licenses]),
        Drivers = proplists:get_value(drivers, B, []),
        check(Drivers, [uiautomator2, xcuitest]),
        lists:foreach(fun({_K,V}) -> version(V) end, Drivers),
        Requested = proplists:get_value(version, B, default_version(Backend)),
        version(Requested),
        Req = #{schema => 1, backend => Backend, root => list_to_binary(Dir),
            bootstrap => boolean(bootstrap, P, false), offline => boolean(offline, P, false),
            source => Source, version => json(Requested),
            executable => json(proplists:get_value(executable, B, <<>>)),
            browser => json(proplists:get_value(browser, B, <<>>)),
            chrome_sha256 => json(proplists:get_value(chrome_sha256, B, <<>>)),
            driver_sha256 => json(proplists:get_value(driver_sha256, B, <<>>)),
            node => object(Node), java => object(Java), android => object(Android),
            drivers => object(Drivers), doctor => boolean(doctor, B, true),
            chromedriver_autodownload => boolean(chromedriver_autodownload, B, false),
            android_chromedriver => json(proplists:get_value(android_chromedriver, B, <<>>)),
            script => json(proplists:get_value(script, B, <<>>))},
        {ok, #{backend => Backend, enabled => Enabled, root => Root, dir => Dir,
            python => Python, port => Port, base_path => Base, max_sessions => MaxSessions,
            bootstrap_ms => integer(bootstrap_timeout_ms, P, 900000, 1000, 3600000),
            ready_ms => integer(ready_timeout_ms, P, 60000, 1000, 300000),
            health_ms => integer(health_interval_ms, P, 5000, 200, 60000),
            health_failures => integer(health_failures, P, 3, 1, 20),
            restart_ms => BaseDelay, max_restart_ms => MaxDelay,
            max_failures => integer(max_failures, P, 5, 1, 50), request => Req}}
    catch _:_ -> {error, invalid_webdriver_runtime_config}
    end.

backend_keys(chromedriver) -> [enabled, source, port, base_path, version, executable,
    browser, chrome_sha256, driver_sha256, max_sessions];
backend_keys(appium) -> [enabled, source, port, base_path, version, executable,
    node, java, android, drivers, doctor, chromedriver_autodownload, android_chromedriver, max_sessions];
backend_keys(fixture) -> [enabled, port, base_path, script, max_sessions].
default_port(chromedriver) -> 9515;
default_port(appium) -> 4723;
default_port(fixture) -> 8765.
default_version(chromedriver) -> stable;
default_version(appium) -> latest;
default_version(fixture) -> latest.

section(Key, P, Keys) -> V = proplists:get_value(Key, P, []), check(V, Keys), V.
check(P, Keys) when is_list(P) ->
    true = lists:all(fun({K,_}) -> lists:member(K, Keys); (_) -> false end, P),
    true = length(lists:usort([K || {K,_} <- P])) =:= length(P), ok.
boolean(K, P, D) -> V = proplists:get_value(K, P, D), true = is_boolean(V), V.
integer(K, P, D, Min, Max) ->
    V = proplists:get_value(K, P, D), true = is_integer(V) andalso V >= Min andalso V =< Max, V.
version(V) when V =:= stable; V =:= latest; V =:= lts -> ok;
version(V) -> match(text(V), "^[0-9]+(\\.[0-9]+){2,3}$").
match(V, Pattern) -> match = re:run(V, Pattern, [{capture, none}]), ok.
text(B) when is_binary(B) -> text(unicode:characters_to_list(B));
text(L) when is_list(L), L =/= [] ->
    true = lists:all(fun(C) -> is_integer(C) andalso C >= 32 andalso C =/= 127 end, L), L.
object(P) -> maps:from_list([{atom_to_binary(K, utf8), json(V)} || {K,V} <- P]).
json([]) -> [];
json([{_,_}|_] = P) -> object(P);
json([H|_] = S) when is_integer(H) -> unicode:characters_to_binary(S);
json(L) when is_list(L) -> [json(V) || V <- L];
json(true) -> true;
json(false) -> false;
json(A) when is_atom(A) -> atom_to_binary(A, utf8);
json(V) when is_binary(V); is_number(V) -> V.

%% No symlink traversal in the writable cache. Existing system ancestors keep
%% their permissions; only newly created directories are chmod'ed to 0700.
private_dir(Dir) ->
    Parts = filename:split(filename:absname(Dir)),
    _ = lists:foldl(fun(Part, Acc) ->
        Path = case Acc of "" -> Part; _ -> filename:join(Acc, Part) end,
        case file:read_link_info(Path) of
            {ok, #file_info{type = directory}} -> ok;
            {error, enoent} ->
                case file:make_dir(Path) of ok -> ok = file:change_mode(Path, 8#700);
                    {error, eexist} -> {ok, #file_info{type = directory}} = file:read_link_info(Path)
                end;
            _ -> error(unsafe_webdriver_cache_path)
        end,
        Path
    end, "", Parts),
    {ok, #file_info{mode = Mode}} = file:read_link_info(Dir),
    true = (Mode band 8#022) =:= 0,
    ok.
