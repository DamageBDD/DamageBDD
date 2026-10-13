%%%-------------------------------------------------------------------
%%% ERM display-manager public API.
%%%-------------------------------------------------------------------
-module(erm_dm).

-export([
    start_link/0,
    users/0,
    sessions/0,
    select_user/1,
    select_session/1,
    login/0,
    cancel/0,
    status/0,
    diagnostics/0,
    logout/0,
    restart_erm/0,
    poweroff/0,
    reboot/0,
    suspend/0
]).

start_link() -> erm_dm_sup:start_link().
users() -> erm_dm_users:list().
sessions() -> erm_dm_sessions:list().
select_user(User) -> gen_server:call(erm_dm_auth, {select_user, User}).
select_session(Session) -> gen_server:call(erm_dm_auth, {select_session, Session}).
login() -> gen_server:call(erm_dm_auth, login, 120000).
cancel() -> gen_server:call(erm_dm_auth, cancel, 5000).
status() -> erm_dm_diag:status().
diagnostics() -> erm_dm_diag:snapshot().
logout() -> erm_dm_ops:logout().
restart_erm() -> erm_dm_ops:restart_erm().
poweroff() -> erm_dm_ops:poweroff().
reboot() -> erm_dm_ops:reboot().
suspend() -> erm_dm_ops:suspend().
