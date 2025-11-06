%%% @doc
%%% ZX Peer Supervisor
%%%
%%% This process supervises the peer socket handlers themselves. It is a peer of the
%%% zx_peer_man, and a child of the supervisor named zx_peers.
%%% @end

-module(zx_peer_sup).
-vsn("0.14.0").
-behaviour(supervisor).
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([start_acceptor/1]).
-export([start_link/0]).
-export([init/1]).



-spec start_acceptor(ListenSocket) -> Result
    when ListenSocket :: gen_tcp:socket(),
         Result       :: {ok, pid()}
                       | {error, Reason},
         Reason       :: {already_started, pid()}
                       | {shutdown, term()}
                       | term().
%% @private
%% Spawns the first listener at the request of the zx_peer_man when es:listen/1
%% is called, or the next listener at the request of the currently listening zx_peer
%% when a connection is made.
%%
%% Error conditions, supervision strategies and other important issues are
%% explained in the supervisor module docs:
%% http://erlang.org/doc/man/supervisor.html

start_acceptor(ListenSocket) ->
    supervisor:start_child(?MODULE, [ListenSocket]).


-spec start_link() -> {ok, pid()}.
%% @private
%% This supervisor's own start function.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, none).


-spec init(none) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
%% @private
%% The OTP init/1 function.

init(none) ->
    RestartStrategy = {simple_one_for_one, 1, 60},
    Peer = {zx_peer,
            {zx_peer, start_link, []},
            temporary,
            brutal_kill,
            worker,
            [zx_peer]},
    {ok, {RestartStrategy, [Peer]}}.
