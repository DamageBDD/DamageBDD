%%% @doc
%%% ZX Daemon Supervisor
%%%
%%% This supervisor maintains the lifecycle of the zx_daemon worker process.
%%% @end

-module(zx_sup).
-vsn("0.14.0").
-behavior(supervisor).
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([start_link/0, init/1]).



%%% Startup

-spec start_link() -> Result
    when Result    :: {ok, pid()}
                    | {error, Reason},
         Reason    :: {already_started, pid()}
                    | {shutdown, term()}
                    | term().
%% @private
%% Called by zx:subscribe/1.
%% Starts this single, registered supervisor.
%%
%% Error conditions, supervision strategies, and other important issues are
%% explained in the supervisor module docs:
%% http://erlang.org/doc/man/supervisor.html

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, none).


-spec init(none) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
%% @private
%% Do not call this function directly -- it is exported only because it is a
%% necessary part of the OTP supervisor behavior.

init(none) ->
    RestartStrategy = {rest_for_one, 1, 60},

    Daemon      = {zx_daemon,
                   {zx_daemon, start_link, []},
                   permanent,
                   10000,
                   worker,
                   [zx_daemon]},

    ConnSup     = {zx_conn_sup,
                   {zx_conn_sup, start_link, []},
                   permanent,
                   brutal_kill,
                   supervisor,
                   [zx_conn_sup]},

    Proxy       = {zx_proxy,
                   {zx_proxy, start_link, []},
                   permanent,
                   5000,
                   worker,
                   [zx_proxy]},

    PeerService = {zx_peers,
                   {zx_peers, start_link, []},
                   permanent,
                   5000,
                   supervisor,
                   [zx_peers]},
    Children = [Daemon, ConnSup, Proxy, PeerService],
    {ok, {RestartStrategy, Children}}.
