%%--------------------------------------------------------------------
%% @doc
%% OTP Logger handler used by damage_ecai_log_bridge.
%%
%% Logger invokes log/2 in the process that emitted the log event. Keep this
%% callback deliberately tiny: reject bridge-internal events and forward the
%% raw event to the supervised bridge without formatting or inference work.
%% @end
%%--------------------------------------------------------------------
-module(damage_ecai_logger_handler).
-behaviour(logger_handler).

-export([
    adding_handler/1,
    changing_config/3,
    filter_config/1,
    log/2,
    removing_handler/1
]).

-define(DEFAULT_SERVER, damage_ecai_log_bridge).

adding_handler(Config) when is_map(Config) ->
    {ok, Config};
adding_handler(Config) ->
    {error, {invalid_handler_config, Config}}.

changing_config(_SetOrUpdate, _OldConfig, NewConfig) when is_map(NewConfig) ->
    {ok, NewConfig};
changing_config(_SetOrUpdate, _OldConfig, NewConfig) ->
    {error, {invalid_handler_config, NewConfig}}.

filter_config(Config) ->
    Config.

removing_handler(_Config) ->
    ok.

log(LogEvent, Config) ->
    %% A Logger handler exception can cause Logger to remove the handler. The
    %% bridge is advisory, so malformed events/configuration must be dropped.
    try
        do_log(LogEvent, Config)
    catch
        _:_ -> ok
    end.

do_log(LogEvent, Config) when is_map(LogEvent), is_map(Config) ->
    Meta = maps:get(meta, LogEvent, #{}),
    case is_map(Meta) andalso maps:get(damage_ecai_internal, Meta, false) =:= true of
        true ->
            ok;
        false ->
            HandlerConfig = maps:get(config, Config, #{}),
            Server = maps:get(server, HandlerConfig, ?DEFAULT_SERVER),
            MaxQueue = positive_int(maps:get(max_queue, HandlerConfig, 1000), 1000),
            forward(Server, MaxQueue, LogEvent)
    end;
do_log(_LogEvent, _Config) ->
    ok.

forward(Server, MaxQueue, LogEvent) ->
    case server_pid(Server) of
        undefined ->
            ok;
        Pid ->
            case process_info(Pid, message_queue_len) of
                {message_queue_len, Length} when Length >= MaxQueue ->
                    ok;
                {message_queue_len, _Length} ->
                    _ = erlang:send(
                        Pid,
                        {damage_ecai_logger_event, LogEvent},
                        [nosuspend]
                    ),
                    ok;
                undefined ->
                    ok
            end
    end.

server_pid(Pid) when is_pid(Pid) ->
    case is_process_alive(Pid) of
        true -> Pid;
        false -> undefined
    end;
server_pid(Name) when is_atom(Name) ->
    whereis(Name);
server_pid(_) ->
    undefined.

positive_int(Value, _Default) when is_integer(Value), Value > 0 -> Value;
positive_int(_Value, Default) -> Default.
