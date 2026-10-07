%%%-------------------------------------------------------------------
%%% Redacted display-manager diagnostics. Never reads secret material.
%%%-------------------------------------------------------------------
-module(erm_dm_diag).

-export([status/0, snapshot/0]).

status() ->
    #{auth => safe(fun erm_dm_auth:status/0),
      display => safe(fun erm_display:status/0),
      gtknode4 => safe(fun gtknode4:status/0)}.

snapshot() ->
    #{status => status(),
      os => #{otp_release => list_to_binary(erlang:system_info(otp_release)),
              system_architecture => list_to_binary(erlang:system_info(system_architecture)),
              node => atom_to_binary(node(), utf8)},
      login => login_snapshot(),
      sessions => safe(fun erm_dm_sessions:list/0),
      users => user_summary()}.

login_snapshot() ->
    #{xdg_session_id => env("XDG_SESSION_ID"),
      xdg_session_type => env("XDG_SESSION_TYPE"),
      xdg_seat => env("XDG_SEAT"),
      xdg_vtnr => env("XDG_VTNR"),
      display => env("DISPLAY"),
      xauthority_present => env_present("XAUTHORITY"),
      greetd_socket_present => env_present("GREETD_SOCK")}.

user_summary() ->
    case erm_dm_users:list() of
        {ok, Users} -> #{count => length(Users), usernames => [maps:get(username, U) || U <- Users]};
        Error -> Error
    end.

env(Name) -> case os:getenv(Name) of false -> undefined; V -> unicode:characters_to_binary(V) end.
env_present(Name) -> os:getenv(Name) =/= false.
safe(F) -> try F() catch C:R -> {error, {C, R}} end.
