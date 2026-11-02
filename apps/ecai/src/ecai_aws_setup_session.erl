%% The bootstrap credential map crosses this sensitive process only once, then
%% lives inside the bounded Python subprocess. No credential args in child specs,
%% no shell, no secret files, no OS environment mutation and no raw error logs.
-module(ecai_aws_setup_session).
-behaviour(gen_server).
-export([start_link/0, connect/4, run/3, runtime/2, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, format_status/1, format_status/2]).

start_link() -> gen_server:start_link(?MODULE, [], []).
connect(Pid, Config, Credentials, Region) ->
    gen_server:call(Pid, {connect, Config, Credentials, Region}, 65000).
run(Pid, Action, Args) -> gen_server:call(Pid, {run, Action, Args}, 65000).
close(Pid) ->
    case catch gen_server:stop(Pid, normal, 2000) of
        ok -> ok;
        _ -> exit(Pid, kill), ok
    end.
runtime(Action, Args) ->
    process_flag(sensitive, true),
    case open() of
        {ok, Port} ->
            Result = exchange(Port, Args#{<<"mode">> => <<"runtime">>, <<"action">> => Action}),
            catch erlang:port_close(Port), Result;
        Error -> Error
    end.
init([]) ->
    process_flag(sensitive, true),
    process_flag(trap_exit, true),
    erlang:send_after(900000, self(), expire),
    {ok, #{port => undefined, expires => erlang:monotonic_time(millisecond) + 900000}}.
handle_call({connect, Config, Credentials, Region}, _From, #{port := undefined} = State) ->
    case open() of
        {ok, Port} ->
            Result = exchange(Port, #{<<"mode">> => <<"bootstrap">>, <<"config">> => Config,
                <<"credentials">> => Credentials, <<"region">> => Region}),
            case Result of
                {ok, _} -> {reply, Result, State#{port := Port}};
                _ -> catch erlang:port_close(Port), {stop, normal, Result, State}
            end;
        Error -> {stop, normal, Error, State}
    end;
handle_call({run, Action, Args}, _From, #{port := Port, expires := Expires} = State) when is_port(Port) ->
    case erlang:monotonic_time(millisecond) < Expires of
        true ->
            Result = exchange(Port, #{<<"action">> => Action, <<"args">> => Args}),
            case Result of
                {error, <<"bridge_timeout">>} -> {stop, normal, Result, State};
                {error, <<"bridge_closed">>} -> {stop, normal, Result, State};
                _ -> {reply, Result, State}
            end;
        false -> {stop, normal, {error, <<"setup_session_expired">>}, State}
    end;
handle_call(_, _From, State) -> {reply, {error, <<"setup_session_unavailable">>}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(expire, State) -> {stop, normal, State};
handle_info({'EXIT', _, _}, State) -> {stop, normal, State};
handle_info({_Port, {exit_status, _}}, State) -> {stop, normal, State};
handle_info(_, State) -> {noreply, State}.
terminate(_, #{port := Port}) when is_port(Port) -> catch erlang:port_close(Port), ok;
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.
format_status(Status) when is_map(Status) -> Status#{state => redacted, message => redacted, reason => redacted, log => []}.
format_status(_, _) -> [{data, [{"State", redacted}]}].

open() ->
    case ecai_aws_setup_config:python() of
        false -> {error, <<"python_not_installed">>};
        Python ->
            try open_port({spawn_executable, Python}, [binary, exit_status, use_stdio,
                    {line, 131072}, {args, ["-I", "-u", ecai_aws_setup_config:script()]}]) of
                Port -> {ok, Port}
            catch _:_ -> {error, <<"bridge_start_failed">>} end
    end.
exchange(Port, Payload) ->
    try
        Bytes = jsx:encode(Payload),
        true = byte_size(Bytes) =< 98303,
        true = port_command(Port, <<Bytes/binary, "\n">>),
        receive_result(Port, erlang:monotonic_time(millisecond) + 60000)
    catch _:_ -> {error, <<"bridge_protocol_error">>} end.
receive_result(Port, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, {eol, Bytes}}} ->
            try jsx:decode(Bytes, [return_maps]) of
                #{<<"ok">> := true, <<"data">> := Data} when is_map(Data) -> {ok, Data};
                #{<<"ok">> := false, <<"error">> := Code} when is_binary(Code), byte_size(Code) =< 80 -> {error, Code};
                _ -> {error, <<"bridge_protocol_error">>}
            catch _:_ -> {error, <<"bridge_protocol_error">>} end;
        {Port, {data, {noeol, _}}} -> catch erlang:port_close(Port), {error, <<"bridge_output_too_large">>};
        {Port, {exit_status, _}} -> {error, <<"bridge_closed">>};
        {'EXIT', Port, _} -> {error, <<"bridge_closed">>}
    after Remaining -> catch erlang:port_close(Port), {error, <<"bridge_timeout">>} end.
