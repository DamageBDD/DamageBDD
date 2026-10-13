%%% @doc
%%% ZX Network Functions
%%%
%%% A few common network functions concentrated in one place.
%%% @end

-module(zx_net).
-vsn("0.14.0").
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([peername/1,
         host_string/1,
         disconnect/1,
         tx/2, tx/3,
         rx/1, rx/2, rx/3,
         err_ex/1, err_in/1]).

-include("zx_logger.hrl").



%%% Library Functions

-spec peername(Socket) -> Result
    when Socket :: gen_tcp:socket(),
         Result :: {ok, zx:host()}
                 | {error, inet:posix()}.
%% @doc
%% Returns the IPv4 or IPv6 peer-side address of a connected socket, translating the
%% address to IPv4 in the case that it is a translated IPv4 -> IPv6 address.

peername(Socket) ->
    case inet:peername(Socket) of
        {ok, {{0, 0, 0, 0, 0, 65535, X, Y}, Port}} ->
            <<A:8, B:8, C:8, D:8>> = <<X:16, Y:16>>,
            {ok, {{A, B, C, D}, Port}};
        Other ->
            Other
    end.


-spec host_string(zx:host()) -> string().

host_string({Address, Port}) when is_list(Address) ->
    PortS = integer_to_list(Port),
    Address ++ ":" ++ PortS;
host_string({Address, Port}) ->
    AddressS = inet:ntoa(Address),
    PortS = integer_to_list(Port),
    AddressS ++ ":" ++ PortS.


-spec disconnect(Socket) -> ok
    when Socket :: gen_tcp:socket().
%% @doc
%% Disconnects from a socket, handling the case where the socket is already
%% disconnected on the other side.

disconnect(Socket) ->
    case peername(Socket) of
        {ok, {Addr, Port}} ->
            Host = inet:ntoa(Addr),
            disconnect(Socket, Host, Port);
        {error, Reason} ->
            log(warning, "Disconnect failed with: ~w", [Reason])
    end.


-spec disconnect(Socket, Host, Port) -> ok
    when Socket :: gen_tcp:socket(),
         Host   :: string(),
         Port   :: inet:port_number().

disconnect(Socket, Host, Port) ->
    case gen_tcp:shutdown(Socket, read_write) of
        ok ->
            ok;
        {error, enotconn} ->
            receive
                {tcp_closed, Socket} -> ok
                after 0              -> ok
            end;
        {error, E} ->
            ok = log(warning, "~ts:~w disconnect failed with: ~w", [Host, Port, E]),
            receive
                {tcp_closed, Socket} -> ok
                after 0              -> ok
            end
    end.


-spec tx(Socket, Bytes) -> Result
    when Socket :: gen_tcp:socket(),
         Bytes  :: iodata(),
         Result :: ok
                 | {error, Reason},
         Reason :: tcp_closed
                 | timeout
                 | inet:posix().

tx(Socket, Bytes) ->
    tx(Socket, Bytes, 5000).


-spec tx(Socket, Bytes, Timeout) -> Result
    when Socket  :: gen_tcp:socket(),
         Bytes   :: iodata(),
         Timeout :: pos_integer(),
         Result  :: ok
                  | {error, Reason},
         Reason  :: tcp_closed
                  | timeout
                  | inet:posix().

tx(Socket, Bytes, Timeout) ->
    ok = inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, <<0:8>>} -> tx2(Socket, Bytes, Timeout);
        {tcp, Socket, Bin}     -> {error, Bin};
        {tcp_closed, Socket}   -> {error, tcp_closed}
        after Timeout          -> {error, timeout}
    end.


tx2(Socket, Bytes, Timeout) ->
    case gen_tcp:send(Socket, Bytes) of
        ok ->
            ok = inet:setopts(Socket, [{active, once}]),
            receive
                {tcp, Socket, <<0:8>>} -> ok;
                {tcp, Socket, Bin}     -> {error, Bin};
                {tcp_closed, Socket}   -> {error, tcp_closed}
                after Timeout          -> {error, timeout}
            end;
        Error ->
            Error
    end.


-spec rx(Socket) -> Result
    when Socket :: gen_tcp:socket(),
         Result :: {ok, binary()}
                 | {error, timeout | tcp_closed}.
%% @doc
%% Abstract large receives with a fixed timeout of 5 seconds between segments.

rx(Socket) ->
    rx(Socket, 5000, []).


-spec rx(Socket, Timeout) -> Result
    when Socket  :: gen_tcp:socket(),
         Timeout :: pos_integer(),
         Result  :: {ok, binary()}
                  | {error, timeout | tcp_closed}.
%% @doc
%% Abstract large receives with a fixed timeout between segments.

rx(Socket, Timeout) ->
    rx(Socket, Timeout, []).


-spec rx(Socket, Timeout, Watchers) -> Result
    when Socket   :: gen_tcp:socket(),
         Timeout  :: pos_integer(),
         Watchers :: [pid()],
         Result   :: {ok, binary()}
                   | {error, timeout | tcp_closed}.
%% @doc
%% Abstract large receives with a fixed timeout between segments and progress update
%% messages to listening processes.
%% NOTE: The gen_tcp:send/2 on the second line of this function mimics the behavior of
%% the {packet, 4} option which is standard outside of bulk RX/TX.

rx(Socket, Timeout, Watchers) ->
    ok = inet:setopts(Socket, [{active, once}, {packet, 0}]),
    ok = gen_tcp:send(Socket, <<1:32, 0:8>>),
    receive
        {tcp, Socket, <<Size:32, Bin/binary>>} ->
            Received = byte_size(Bin),
            rx(Socket, Watchers, Size, Received, Bin, Timeout);
        {tcp_closed, Socket} ->
            {error, tcp_closed}
        after Timeout ->
            {error, timeout}
    end.

rx(Socket, Watchers, Size, Received, Buffer, Timeout) when Size > Received ->
    ok = broadcast({rx, Size, Received}, Watchers),
    ok = inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, Bin} ->
            NewReceived = Received + byte_size(Bin),
            rx(Socket, Watchers, Size, NewReceived, <<Buffer/binary, Bin/binary>>, Timeout);
        {tcp_closed, Socket} ->
            {error, tcp_closed}
        after Timeout ->
            {error, timeout}
    end;
rx(Socket, Watchers, Size, Size, Bin, _) ->
    ok = inet:setopts(Socket, [{packet, 4}]),
    ok = gen_tcp:send(Socket, <<0:8>>),
    ok = broadcast({rx, done}, Watchers),
    {ok, Bin};
rx(_, Watchers, Size, Received, _, _) when Size < Received ->
    ok = broadcast({rx, overflow}, Watchers),
    {error, bad_message}.


broadcast(Message, Pids) ->
    Notify = fun(P) -> P ! Message end,
    lists:foreach(Notify, Pids).


err_ex(bad_message)      -> <<0:1,  1:7>>;
err_ex(timeout)          -> <<0:1,  2:7>>;
err_ex(bad_realm)        -> <<0:1,  3:7>>;
err_ex(bad_package)      -> <<0:1,  4:7>>;
err_ex(bad_version)      -> <<0:1,  5:7>>;
err_ex(bad_serial)       -> <<0:1,  6:7>>;
err_ex(bad_user)         -> <<0:1,  7:7>>;
err_ex(bad_key)          -> <<0:1,  8:7>>;
err_ex(bad_sig)          -> <<0:1,  9:7>>;
err_ex(no_permission)    -> <<0:1, 10:7>>;
err_ex(unknown_user)     -> <<0:1, 11:7>>;
err_ex(bad_request)      -> <<0:1, 12:7>>;
err_ex(realm_mismatch)   -> <<0:1, 13:7>>;
err_ex(not_prime)        -> <<0:1, 14:7>>;
err_ex(bad_auth)         -> <<0:1, 15:7>>;
err_ex(unauthorized_key) -> <<0:1, 16:7>>;
err_ex(already_exists)   -> <<0:1, 17:7>>;
err_ex(busy)             -> <<0:1, 18:7>>;
err_ex(not_sysop)        -> <<0:1, 19:7>>;
err_ex({retry, Seconds}) -> <<0:1, 20:7, Seconds:24>>;
err_ex(Reason)           -> [<<0:1, 127:7>>, io_lib:format("~tw", [Reason])].


err_in(<<0:1,  1:7>>)                 -> bad_message;
err_in(<<0:1,  2:7>>)                 -> timeout;
err_in(<<0:1,  3:7>>)                 -> bad_realm;
err_in(<<0:1,  4:7>>)                 -> bad_package;
err_in(<<0:1,  5:7>>)                 -> bad_version;
err_in(<<0:1,  6:7>>)                 -> bad_serial;
err_in(<<0:1,  7:7>>)                 -> bad_user;
err_in(<<0:1,  8:7>>)                 -> bad_key;
err_in(<<0:1,  9:7>>)                 -> bad_sig;
err_in(<<0:1, 10:7>>)                 -> no_permission;
err_in(<<0:1, 11:7>>)                 -> unknown_user;
err_in(<<0:1, 12:7>>)                 -> bad_request;
err_in(<<0:1, 13:7>>)                 -> realm_mismatch;
err_in(<<0:1, 14:7>>)                 -> not_prime;
err_in(<<0:1, 15:7>>)                 -> bad_auth;
err_in(<<0:1, 16:7>>)                 -> unauthorized_key;
err_in(<<0:1, 17:7>>)                 -> already_exists;
err_in(<<0:1, 18:7>>)                 -> busy;
err_in(<<0:1, 19:7>>)                 -> not_sysop;
err_in(<<0:1, 20:7, Seconds:24>>)     -> {retry, Seconds};
err_in(<<0:1, 127:7, Reason/binary>>) -> unicode:characters_to_list(Reason).
