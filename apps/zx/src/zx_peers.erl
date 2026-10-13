%%% @doc
%%% ZX Peer Service Supervisor
%%%
%%% The service-level supervisor of the peer subsystem.
%%% The peer subsystem makes sure that external connections and write access to
%%% system resources are all passed through a single instance of zx_daemon. Once a
%%% zx_daemon recognizes that it is the first instance of ZX running on a system it
%%% declares itself the system proxy by writing a lock file in the main Zomp directory
%%% and opening a local port to listen to connections from other local ZX instances.
%%% @end

-module(zx_peers).
-vsn("0.14.0").
-behavior(supervisor).
-author("Craig Everett <zxq9@zxq9.com>").
-copyright("Craig Everett <zxq9@zxq9.com>").
-license("GPL-3.0").

-export([start_link/0]).
-export([init/1]).


-spec start_link() -> {ok, pid()}.
%% @private
%% This supervisor's own start function.

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, none).

-spec init(none) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
%% @private
%% The OTP init/1 function.

init(none) ->
    RestartStrategy = {rest_for_one, 1, 60},
    PeerSup = {zx_peer_sup,
               {zx_peer_sup, start_link, []},
               permanent,
               5000,
               supervisor,
               [zx_peer_sup]},
    PeerMan = {zx_peer_man,
               {zx_peer_man, start_link, []},
               permanent,
               5000,
               worker,
               [zx_peer_man]},
    Children  = [PeerSup, PeerMan],
    {ok, {RestartStrategy, Children}}.
