-module(nosternity_app).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-behaviour(application).

-export([start/2, stop/1]).
-export([start_phase/3]).

-ifdef(TEST).
-export([transport_options/0, protocol_options/1, start_listener/1]).
-endif.

-include_lib("kernel/include/logger.hrl").

start(_StartType, _StartArgs) ->
    case nosternity_config:validate() of
        ok -> nosternity_sup:start_link();
        {error, _} = Error -> Error
    end.
get_trails() ->
    Handlers =
        [
            nosternity_http,
            nosternity_search_http
        ],
    Trails =
        [
            {"/nostr", nosternity_websocket, #{}},
            {"/", cowboy_static, {priv_file, nosternity, "static/nosternity.html"}}
            | trails:trails(Handlers)
        ],
    trails:store(Trails),
    trails:single_host_compile(Trails).

start_phase(start_trails_http, _StartType, []) ->
    case nosternity_config:get(enabled) andalso nosternity_config:get(http_enabled) of
        true -> start_http();
        false -> ok
    end;
start_phase(os_tune, _StartType, []) ->
    case nosternity_config:get(enabled) of
        true ->
            ?LOG_INFO("Tuning os."),
            {ok, _} = exec:run("ulimit -n 1000000", [sync]),
            ok;
        false -> ok
    end.

stop(_State) ->
    %% gun belongs to the shared application dependency graph. Stopping this
    %% listener must not interrupt HTTP clients in DamageBDD or ECAI.
    try cowboy:stop_listener(http_nosternity) of
        _ -> ok
    catch
        _:_ -> ok
    end,
    ok.

%% internal functions
start_http() ->
    Dependencies = [gun, yamerl, prometheus_cowboy, cowboy_telemetry, erlexec, throttle, gproc],
    case ensure_dependencies(Dependencies) of
        ok ->
            case start_listener(get_trails()) of
                ok ->
                    damage_metrics:init(),
                    ?LOG_INFO("Started Nosternity HTTP/WebSocket listener on ~p:~p",
                        [nosternity_config:get(ip), nosternity_config:get(port)]),
                    ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

ensure_dependencies([]) -> ok;
ensure_dependencies([App | Rest]) ->
    case application:ensure_all_started(App) of
        {ok, _} -> ensure_dependencies(Rest);
        {error, Reason} -> {error, {nosternity_dependency_start_failed, App, Reason}}
    end.

start_listener(Dispatch) ->
    case cowboy:start_clear(http_nosternity, transport_options(), protocol_options(Dispatch)) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok;
        {error, Reason} -> {error, {http_listener_start_failed, Reason}}
    end.

transport_options() ->
    Ip = nosternity_config:get(ip),
    Family = case tuple_size(Ip) of 8 -> [inet6]; 4 -> [] end,
    #{
        num_acceptors => nosternity_config:get(http_num_acceptors),
        %% Ranch applies max_connections per connection supervisor.
        num_conns_sups => 1,
        max_connections => nosternity_config:get(http_max_connections),
        socket_opts => Family ++ [
            {ip, Ip},
            {port, nosternity_config:get(port)}
        ]
    }.

protocol_options(Dispatch) ->
    #{
        env => #{dispatch => Dispatch},
        idle_timeout => nosternity_config:get(http_idle_timeout_ms),
        request_timeout => nosternity_config:get(http_request_timeout_ms),
        metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
        stream_handlers => [cowboy_telemetry_h, cowboy_metrics_h, cowboy_stream_h]
    }.
