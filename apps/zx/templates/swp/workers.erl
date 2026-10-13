%%% @doc
%%% 〘*PROJECT NAME*〙: 〘*CAP SERVICE*〙 Service Supervisor
%%%
%%% This is the service-level supervisor of the system. It is the parent of both the
%%% client connection handlers and the client manager (which manages the client
%%% connection handlers). This is the child of 〘*PREFIX*〙_sup.
%%%
%%% See: http://erlang.org/doc/apps/kernel/application.html
%%% @end

-module(〘*PREFIX*〙_〘*SERVICE*〙s).
-vsn("〘*VERSION*〙").
-behavior(supervisor).
〘*AUTHOR*〙
〘*COPYRIGHT*〙
〘*LICENSE*〙

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
    〘*CAP SERVICE*〙Man = 
        {〘*PREFIX*〙_〘*SERVICE*〙_man,
         {〘*PREFIX*〙_〘*SERVICE*〙_man, start_link, []},
         permanent,
         5000,
         worker,
         [〘*PREFIX*〙_〘*SERVICE*〙_man]},
    〘*CAP SERVICE*〙Sup =
        {〘*PREFIX*〙_〘*SERVICE*〙_sup,
         {〘*PREFIX*〙_〘*SERVICE*〙_sup, start_link, []},
         permanent,
         5000,
         supervisor,
         [〘*PREFIX*〙_〘*SERVICE*〙_sup]},
    Children  = [〘*CAP SERVICE*〙Sup, 〘*CAP SERVICE*〙Man],
    {ok, {RestartStrategy, Children}}.
