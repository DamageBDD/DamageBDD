%%% Local, capability-scoped ERM IPC. No distributed Erlang or executable terms.
-module(damage_erm_bridge).
-behaviour(gen_server).
-include_lib("kernel/include/file.hrl").
-export([child_spec/0, start_link/0, start_link/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-ifdef(TEST).
-export([serve/2, configure/1, handle_frame/2]).
-endif.
-define(MAX_FRAME, 65536).
-define(OPS, [<<"ping">>, <<"status">>, <<"capabilities">>]).

child_spec() ->
    #{id => ?MODULE, start => {?MODULE, start_link, []}, restart => permanent,
      shutdown => 5000, type => worker, modules => [?MODULE]}.

start_link() -> start_link(application:get_env(damage, erm_bridge, #{})).
start_link(#{enabled := true} = Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []);
start_link(#{enabled := false}) -> ignore;
start_link(Config) when is_map(Config), not is_map_key(enabled, Config) -> ignore;
start_link(_) -> {error, invalid_bridge_config}.

status() ->
    case whereis(?MODULE) of
        undefined -> #{enabled => false};
        _ -> gen_server:call(?MODULE, status)
    end.

init(Config0) ->
    process_flag(trap_exit, true),
    case configure(Config0) of
        {ok, Config} ->
            case listen(Config) of
                {ok, Listener, Identity} ->
                    Count = maps:get(max_clients, Config),
                    Workers = [spawn_link(fun() -> accept_loop(Listener, Config) end)
                               || _ <- lists:seq(1, Count)],
                    {ok, #{listener => Listener, workers => Workers,
                           config => Config, socket_identity => Identity}};
                {error, Reason} -> {stop, Reason}
            end;
        {error, Reason} -> {stop, Reason}
    end.

handle_call(status, _From, State) ->
    {reply, #{enabled => true, acceptors => length(maps:get(workers, State))}, State};
handle_call(_, _From, State) -> {reply, {error, unsupported_call}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({'EXIT', Pid, _Reason}, #{workers := Workers} = State) ->
    case lists:member(Pid, Workers) of
        true ->
            Listener = maps:get(listener, State), Config = maps:get(config, State),
            Replacement = spawn_link(fun() -> accept_loop(Listener, Config) end),
            {noreply, State#{workers := [Replacement | lists:delete(Pid, Workers)]}};
        false -> {noreply, State}
    end;
handle_info(_, State) -> {noreply, State}.

terminate(_, State) ->
    gen_tcp:close(maps:get(listener, State)),
    [exit(Pid, shutdown) || Pid <- maps:get(workers, State)],
    remove_owned_socket(maps:get(socket, maps:get(config, State)),
                        maps:get(socket_identity, State)),
    ok.
code_change(_, State, _) -> {ok, State}.

configure(C) ->
    Socket = maps:get(socket, C, "/run/damage-erm/bridge.sock"),
    Grants = maps:get(grants_file, C, "/etc/damage/erm-users.config"),
    Count = maps:get(max_clients, C, 8),
    Timeout = maps:get(request_timeout_ms, C, 3000),
    case valid_path(Socket) andalso valid_path(Grants) andalso
         is_integer(Count) andalso Count >= 1 andalso Count =< 32 andalso
         is_integer(Timeout) andalso Timeout >= 100 andalso Timeout =< 3000 of
        true ->
            case own_uid() of
                {ok, Uid} ->
                    {ok, #{socket => path(Socket), grants_file => path(Grants),
                           max_clients => Count, request_timeout_ms => Timeout, uid => Uid}};
                _ -> {error, uid_unavailable}
            end;
        false -> {error, invalid_bridge_config}
    end.

valid_path(P) when is_binary(P) -> valid_path(binary_to_list(P));
valid_path(P) when is_list(P) ->
    length(P) > 1 andalso length(P) < 105 andalso hd(P) =:= $/ andalso
    lists:all(fun(C) -> is_integer(C) andalso C > 0 andalso C < 256 end, P) andalso
    not lists:member("..", filename:split(P));
valid_path(_) -> false.
path(P) when is_binary(P) -> binary_to_list(P);
path(P) -> P.

own_uid() ->
    %% Linux is the supported service platform. Do not trust $UID/$USER.
    case file:read_file_info("/proc/self") of
        {ok, #file_info{uid = Uid}} -> {ok, Uid};
        _ -> {error, uid_unavailable}
    end.

listen(C) ->
    P = maps:get(socket, C), Uid = maps:get(uid, C),
    case ensure_socket_directory(filename:dirname(P), Uid) of
        ok ->
            case clear_stale_socket(P, Uid) of
                ok ->
                    Timeout = maps:get(request_timeout_ms, C),
                    Options = [{inet_backend, inet}, binary, {ifaddr, {local, P}},
                               {packet, 4}, {packet_size, ?MAX_FRAME}, {active, false},
                               {backlog, maps:get(max_clients, C)},
                               {send_timeout, Timeout}, {send_timeout_close, true}],
                    case gen_tcp:listen(0, Options) of
                        {ok, Listener} ->
                            case file:change_mode(P, 8#666) of
                                ok ->
                                    {ok, Info} = file:read_link_info(P),
                                    {ok, Listener, identity(Info)};
                                _ -> gen_tcp:close(Listener), {error, socket_permissions_failed}
                            end;
                        {error, _} -> {error, socket_listen_failed}
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

ensure_socket_directory(Dir, Uid) ->
    case protected_grants_directory(filename:dirname(Dir), Uid) of
        ok -> ensure_owned_socket_directory(Dir, Uid);
        Error -> Error
    end.
ensure_owned_socket_directory(Dir, Uid) ->
    case file:read_link_info(Dir) of
        {error, enoent} ->
            case file:make_dir(Dir) of
                ok ->
                    case file:change_mode(Dir, 8#755) of
                        ok -> ensure_socket_directory(Dir, Uid);
                        _ -> {error, unsafe_socket_directory}
                    end;
                _ -> {error, socket_directory_missing}
            end;
        {ok, #file_info{type = directory, uid = Uid, mode = Mode}} when Mode band 8#022 =:= 0 -> ok;
        _ -> {error, unsafe_socket_directory}
    end.

clear_stale_socket(P, Uid) ->
    case file:read_link_info(P) of
        {error, enoent} -> ok;
        {ok, #file_info{type = other, uid = Uid, mode = Mode} = Info}
          when Mode band 8#170000 =:= 8#140000 ->
            %% An existing live listener is never removed, nor is a regular file
            %% or symlink. Only a stale socket with the same inode is removed.
            case gen_tcp:connect({local, P}, 0,
                                 [{inet_backend, inet}, binary, {active, false}], 100) of
                {ok, S} -> gen_tcp:close(S), {error, socket_in_use};
                {error, econnrefused} ->
                    case file:read_link_info(P) of
                        {ok, Current} ->
                            case identity(Current) =:= identity(Info) of
                                true -> file:delete(P);
                                false -> {error, socket_changed}
                            end;
                        _ -> {error, socket_changed}
                    end;
                _ -> {error, unsafe_existing_socket}
            end;
        _ -> {error, unsafe_existing_socket}
    end.
identity(#file_info{inode = Inode, major_device = Device, uid = Uid, type = Type}) ->
    {Device, Inode, Uid, Type}.
remove_owned_socket(P, Identity) ->
    case file:read_link_info(P) of
        {ok, Info} ->
            case identity(Info) =:= Identity of true -> file:delete(P); false -> ok end;
        _ -> ok
    end.

accept_loop(Listener, C) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            %% Errors stay in this bounded acceptor; request data is never logged.
            try serve(Socket, C) catch _:_ -> ok
            after gen_tcp:close(Socket) end,
            accept_loop(Listener, C);
        {error, closed} -> ok;
        {error, _} -> timer:sleep(50), accept_loop(Listener, C)
    end.
serve(Socket, C) ->
    case gen_tcp:recv(Socket, 0, maps:get(request_timeout_ms, C)) of
        {ok, Frame} when byte_size(Frame) =< ?MAX_FRAME ->
            Reply = try handle_frame(Frame, C) catch _:_ -> failure(<<"invalid_request">>) end,
            Encoded = jsx:encode(Reply),
            case byte_size(Encoded) =< ?MAX_FRAME of
                true -> gen_tcp:send(Socket, Encoded);
                false -> gen_tcp:send(Socket, jsx:encode(failure(<<"response_too_large">>)))
            end;
        _ -> ok
    end.
handle_frame(Frame, C) ->
    Request = jsx:decode(Frame, [return_maps]),
    case valid_request(Request) of
        true ->
            Token = maps:get(<<"token">>, Request), Op = maps:get(<<"op">>, Request),
            case authenticate(Token, C) of
                {ok, Principal} ->
                    case lists:member(Op, maps:get(operations, Principal)) of
                        true -> success(dispatch(Op, Principal));
                        false -> failure(<<"forbidden">>)
                    end;
                {error, Code} -> failure(Code)
            end;
        false -> failure(<<"invalid_request">>)
    end.
valid_request(#{<<"v">> := 1, <<"token">> := Token, <<"op">> := Op} = Request) ->
    map_size(Request) =:= 3 andalso hex64(Token) andalso
    is_binary(Op) andalso byte_size(Op) > 0 andalso byte_size(Op) =< 64;
valid_request(_) -> false.

authenticate(Token, C) ->
    case read_grants(maps:get(grants_file, C), maps:get(uid, C)) of
        {ok, Grants} ->
            Hash = hex(crypto:hash(sha256, Token)),
            Matches = [G || G <- Grants, crypto:hash_equals(Hash, maps:get(token_sha256, G))],
            case Matches of [G] -> {ok, G}; _ -> {error, <<"unauthorized">>} end;
        _ -> {error, <<"authorization_unavailable">>}
    end.
read_grants(P, Uid) ->
    case {protected_grants_directory(filename:dirname(P), Uid), file:read_link_info(P)} of
        {ok, {ok, #file_info{type = regular, uid = Owner, mode = Mode, size = Size}}}
          when (Owner =:= 0 orelse Owner =:= Uid), Mode band 8#027 =:= 0,
               Size =< ?MAX_FRAME ->
            case file:read_file(P) of
                {ok, Data} when byte_size(Data) =< ?MAX_FRAME -> parse_grants(Data);
                _ -> {error, invalid_grants}
            end;
        _ -> {error, unsafe_grants}
    end.
protected_grants_directory(Dir, Uid) ->
    case file:read_link_info(Dir) of
        {ok, #file_info{type = directory, uid = Owner, mode = Mode}}
          when (Owner =:= 0 orelse Owner =:= Uid), Mode band 8#022 =:= 0 ->
            protected_parent(Dir, Uid);
        %% Root-owned sticky directories (e.g. /tmp) protect existing owned
        %% entries from replacement. Every following component is still checked.
        {ok, #file_info{type = directory, uid = 0, mode = Mode}}
          when Mode band 8#1000 =/= 0 -> protected_parent(Dir, Uid);
        _ -> {error, unsafe_grants_directory}
    end.
protected_parent("/", _) -> ok;
protected_parent(Dir, Uid) -> protected_grants_directory(filename:dirname(Dir), Uid).
parse_grants(Data) ->
    %% This file is trusted administrator configuration, never wire input.
    case erl_scan:string(binary_to_list(Data)) of
        {ok, Tokens, _} ->
            case erl_parse:parse_term(Tokens) of
                {ok, Grants} when is_list(Grants), length(Grants) =< 256 ->
                    case lists:all(fun valid_grant/1, Grants) andalso unique_grants(Grants) of
                        true -> {ok, Grants};
                        false -> {error, invalid_grants}
                    end;
                _ -> {error, invalid_grants}
            end;
        _ -> {error, invalid_grants}
    end.
valid_grant(#{id := Id, token_sha256 := Hash, operations := Ops} = G) ->
    map_size(G) =:= 3 andalso is_binary(Id) andalso byte_size(Id) > 0 andalso
    byte_size(Id) =< 128 andalso hex64(Hash) andalso is_list(Ops) andalso
    length(Ops) =< 3 andalso lists:all(fun(Op) -> lists:member(Op, ?OPS) end, Ops);
valid_grant(_) -> false.
unique_grants(Grants) ->
    Ids = [maps:get(id, G) || G <- Grants],
    Hashes = [maps:get(token_sha256, G) || G <- Grants],
    length(lists:usort(Ids)) =:= length(Ids) andalso
    length(lists:usort(Hashes)) =:= length(Hashes).
hex64(B) when is_binary(B), byte_size(B) =:= 64 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
              binary_to_list(B));
hex64(_) -> false.
hex(B) -> << <<(digit(H)), (digit(L))>> || <<H:4,L:4>> <= B >>.
digit(N) when N < 10 -> $0 + N;
digit(N) -> $a + N - 10.

success(Result) -> #{<<"v">> => 1, <<"ok">> => true, <<"result">> => Result}.
failure(Code) -> #{<<"v">> => 1, <<"ok">> => false, <<"error">> => Code}.
dispatch(<<"ping">>, _) -> #{<<"pong">> => true};
dispatch(<<"capabilities">>, G) ->
    #{<<"principal">> => maps:get(id, G), <<"operations">> => maps:get(operations, G)};
dispatch(<<"status">>, _) ->
    Running = application:which_applications(),
    #{<<"damage_started">> => lists:keymember(damage, 1, Running),
      <<"damage_supervised">> => is_pid(whereis(damage_sup)),
      <<"ecai_started">> => lists:keymember(ecai, 1, Running)}.
