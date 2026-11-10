%% Capability-limited local client. No distributed Erlang or remote MFA/ETF.
-module(erm_user_bridge).
-behaviour(gen_server).
-export([start_link/0, start_link/1, request/1, request/2, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([exchange/3, server_uid/1, options/1]).
-endif.
-define(MAX_FRAME, 65536).
-define(MAX_JOBS, 8).

start_link() -> start_link(maps:from_list(application:get_all_env(erm_user))).
start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).
request(Op) ->
    try gen_server:call(?MODULE, {request, Op}, 7500)
    catch exit:_ -> {error, unavailable} end.
%% Explicit local client, useful to ERM commands without depending on a running
%% desktop supervisor. The operation allowlist is identical to the OTP client.
request(Op, Opts) ->
    case options(Opts) of
        {ok, O} -> perform(Op, O);
        Error -> Error
    end.
status() ->
    try gen_server:call(?MODULE, status, 1000)
    catch exit:_ -> #{connected => false, last_error => unavailable} end.

init(Opts) ->
    case options(Opts) of
        {ok, O} ->
            self() ! probe,
            {ok, #{opts => O, jobs => #{}, timer => undefined, retry_ms => 1000,
                   connected => false, last_error => unavailable}};
        Error -> {stop, Error}
    end.
handle_call(status, _From, S) ->
    {reply, maps:with([connected, last_error], S), S};
handle_call({request, Op}, From, #{jobs := Jobs} = S) when map_size(Jobs) < ?MAX_JOBS ->
    case operation(Op) of
        {ok, WireOp} -> {noreply, launch(WireOp, From, S)};
        Error -> {reply, Error, S}
    end;
handle_call({request, _}, _From, S) -> {reply, {error, busy}, S};
handle_call(_, _, S) -> {reply, {error, unsupported_call}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(probe, #{jobs := Jobs} = S) when map_size(Jobs) < ?MAX_JOBS ->
    {noreply, launch(<<"ping">>, probe, S#{timer := undefined})};
handle_info(probe, S) -> {noreply, schedule(S)};
handle_info({bridge_result, Ref, Result}, #{jobs := Jobs} = S) ->
    case maps:take(Ref, Jobs) of
        {{Pid, Mon, From}, Remaining} ->
            erlang:demonitor(Mon, [flush]),
            _ = Pid,
            S1 = S#{jobs := Remaining},
            case From of
                probe -> {noreply, schedule(connection_result(Result, S1))};
                _ ->
                    gen_server:reply(From, Result),
                    {noreply, connection_result(Result, S1)}
            end;
        error -> {noreply, S}
    end;
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #{jobs := Jobs} = S) ->
    case [{R, F} || {R, {_P, M, F}} <- maps:to_list(Jobs), M =:= Mon] of
        [{Ref, From}] ->
            S1 = connection_result({error, unavailable}, S#{jobs := maps:remove(Ref, Jobs)}),
            case From of
                probe -> {noreply, schedule(S1)};
                _ -> gen_server:reply(From, {error, unavailable}), {noreply, S1}
            end;
        [] -> {noreply, S}
    end;
handle_info(_, S) -> {noreply, S}.
terminate(_, S) ->
    cancel(maps:get(timer, S)),
    maps:foreach(fun(_Ref, {Pid, _Mon, _From}) -> exit(Pid, shutdown) end, maps:get(jobs, S)),
    ok.
code_change(_, S, _) -> {ok, S}.

launch(Op, From, #{opts := O, jobs := Jobs} = S) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Result = try perform(Op, O) catch _:_ -> {error, unavailable} end,
        Parent ! {bridge_result, Ref, Result}
    end),
    S#{jobs := Jobs#{Ref => {Pid, Mon, From}}}.
connection_result({ok, _}, S) -> S#{connected := true, last_error := undefined, retry_ms := 1000};
connection_result({error, E}, S) -> S#{connected := false, last_error := E}.
schedule(S) ->
    cancel(maps:get(timer, S, undefined)),
    Delay = case maps:get(connected, S) of true -> 30000; false -> maps:get(retry_ms, S) end,
    S#{timer := erlang:send_after(Delay, self(), probe), retry_ms := min(30000, Delay * 2)}.
cancel(undefined) -> ok;
cancel(T) -> erlang:cancel_timer(T), ok.

options(Opts0) when is_list(Opts0) -> options(maps:from_list(Opts0));
options(Opts0) when is_map(Opts0) ->
    try
        Socket = maps:get(bridge_socket, Opts0, "/run/damage-erm/bridge.sock"),
        TokenPath = case maps:get(bridge_token_file, Opts0, default) of
            default -> erm_user_config:token_file(); P -> P
        end,
        C = maps:get(connect_timeout_ms, Opts0, 1000),
        R = maps:get(request_timeout_ms, Opts0, 3000),
        true = is_list(Socket) andalso is_list(TokenPath),
        true = is_integer(C) andalso C > 0 andalso C =< 3000,
        true = is_integer(R) andalso R > 0 andalso R =< 3000,
        %% Retain only supported non-secret options in the OTP server state.
        O = maps:with([bridge_server_uid, bridge_server_user], Opts0),
        {ok, O#{bridge_socket => Socket, bridge_token_file => TokenPath,
                connect_timeout_ms => C, request_timeout_ms => R}}
    catch _:_ -> {error, invalid_bridge_configuration} end;
options(_) -> {error, invalid_bridge_configuration}.

operation(ping) -> {ok, <<"ping">>};
operation(status) -> {ok, <<"status">>};
operation(capabilities) -> {ok, <<"capabilities">>};
operation(Op) when Op =:= <<"ping">>; Op =:= <<"status">>; Op =:= <<"capabilities">> -> {ok, Op};
operation(_) -> {error, unsupported_operation}.

perform(Op, O) ->
    case operation(Op) of
        {ok, WireOp} ->
            case server_uid(O) of
                {ok, Uid} ->
                    SocketPath = maps:get(bridge_socket, O),
                    case erm_user_config:validate_socket(SocketPath, Uid) of
                        ok -> authenticate_connect(SocketPath, WireOp, O);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

authenticate_connect(Path, Op, O) ->
    case erm_user_config:read_token(maps:get(bridge_token_file, O)) of
        {ok, Token} ->
            case gen_tcp:connect({local, Path}, 0,
                    [binary, {active, false}, {packet, 4}, {packet_size, ?MAX_FRAME},
                     {send_timeout, maps:get(request_timeout_ms, O)}, {send_timeout_close, true}],
                    maps:get(connect_timeout_ms, O)) of
                {ok, Socket} ->
                    try exchange(Socket, #{<<"v">> => 1, <<"op">> => Op, <<"token">> => Token},
                                 maps:get(request_timeout_ms, O))
                    after gen_tcp:close(Socket) end;
                {error, _} -> {error, unavailable}
            end;
        Error -> Error
    end.

exchange(Socket, Request, Timeout) ->
    case gen_tcp:send(Socket, jsx:encode(Request)) of
        ok ->
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, B} when byte_size(B) =< ?MAX_FRAME -> decode_response(B);
                {error, timeout} -> {error, timeout};
                _ -> {error, invalid_response}
            end;
        _ -> {error, unavailable}
    end.
decode_response(B) ->
    try jsx:decode(B, [return_maps]) of
        #{<<"v">> := 1, <<"ok">> := true, <<"result">> := Result} = R when map_size(R) =:= 3 ->
            {ok, Result};
        #{<<"v">> := 1, <<"ok">> := false, <<"error">> := Error} = R
          when map_size(R) =:= 3, is_binary(Error) ->
            remote_error(Error);
        _ -> {error, invalid_response}
    catch _:_ -> {error, invalid_response} end.
%% Fixed errors prevent a compromised local endpoint from putting credentials
%% or arbitrary peer strings into the monitor's status/log output.
remote_error(<<"unauthorized">>) -> {error, unauthorized};
remote_error(<<"forbidden">>) -> {error, forbidden};
remote_error(<<"invalid_request">>) -> {error, invalid_request};
remote_error(<<"unavailable">>) -> {error, unavailable};
remote_error(_) -> {error, remote_error}.

server_uid(O) ->
    case maps:find(bridge_server_uid, O) of
        {ok, Uid} when is_integer(Uid), Uid >= 0 -> {ok, Uid};
        {ok, _} -> {error, invalid_bridge_configuration};
        error -> passwd_uid(maps:get(bridge_server_user, O, "damage"))
    end.
passwd_uid(Name) when is_list(Name), length(Name) > 0, length(Name) < 128 ->
    case file:read_file("/etc/passwd") of
        {ok, B} ->
            Matches = [Uid || Line <- binary:split(B, <<"\n">>, [global]),
                [User, _, Uid | _] <- [binary:split(Line, <<":">>, [global])],
                User =:= list_to_binary(Name)],
            case Matches of
                [UidB] ->
                    try binary_to_integer(UidB) of
                        U when U >= 0 -> {ok, U};
                        _ -> {error, unknown_bridge_server_user}
                    catch _:_ -> {error, unknown_bridge_server_user} end;
                _ -> {error, unknown_bridge_server_user}
            end;
        _ -> {error, unknown_bridge_server_user}
    end;
passwd_uid(_) -> {error, invalid_bridge_configuration}.
