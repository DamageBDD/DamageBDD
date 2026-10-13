%%% @doc
%%% The ZX Connection Supervisor
%%%
%%% This supervisor maintains the lifecycle of all zomp_client worker processes.
%%% @end

-module(zx_conn_sup).
-vsn("0.14.0").
-behavior(supervisor).
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([start_conn/1]).
-export([start_link/0]).
-export([init/1]).



%%% Interface Functions

-spec start_conn(Host) -> Result
    when Host   :: zx:host(),
         Result :: {ok, pid()}
                 | {error, Reason},
         Reason :: term().
%% @doc
%% Start an upstream connection handler.
%% (Should only be called from zx_conn).

start_conn(Host) ->
    supervisor:start_child(?MODULE, [Host]).



%%% Startup

-spec start_link() -> Result
    when Result :: {ok, pid()}
                 | {error, Reason},
         Reason :: {already_started, pid()}
                 | {shutdown, term()}
                 | term().
%% @private
%% Called by zx_sup.
%%
%% Spawns a single, registered supervisor process.
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
    RestartStrategy = {simple_one_for_one, 1, 60},

    Client = {zx_conn,
              {zx_conn, start_link, []},
              temporary,
              brutal_kill,
              worker,
              [zx_conn]},

    Children = [Client],
    {ok, {RestartStrategy, Children}}.
