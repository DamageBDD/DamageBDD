%%% @doc
%%% 〘*PROJECT NAME*〙 : 〘*CAP SERVICE*〙 Worker Supervisor
%%% @end

-module(〘*PREFIX*〙_〘*SERVICE*〙_sup).
-vsn("〘*VERSION*〙").
-behaviour(supervisor).
〘*AUTHOR*〙
〘*COPYRIGHT*〙
〘*LICENSE*〙


-export([start_〘*SERVICE*〙/0]).
-export([start_link/0]).
-export([init/1]).


-spec start_〘*SERVICE*〙() -> Result
    when Result       :: {ok, pid()}
                       | {error, Reason},
         Reason       :: {already_started, pid()}
                       | {shutdown, term()}
                       | term().

start_〘*SERVICE*〙() ->
    supervisor:start_child(?MODULE, []).


-spec start_link() -> {ok, pid()}.

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, none).


-spec init(none) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
%% @private
%% The OTP init/1 function.

init(none) ->
    RestartStrategy = {simple_one_for_one, 1, 60},
    〘*CAP SERVICE*〙 =
        {〘*PREFIX*〙_〘*SERVICE*〙,
         {〘*PREFIX*〙_〘*SERVICE*〙, start_link, []},
         temporary,
         brutal_kill,
         worker,
         [〘*PREFIX*〙_〘*SERVICE*〙]},
    {ok, {RestartStrategy, [〘*CAP SERVICE*〙]}}.
