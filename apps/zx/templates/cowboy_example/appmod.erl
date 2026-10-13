%%% @doc
%%% 〘*PROJECT NAME*〙
%%% @end

-module(〘*APP MOD*〙).
-vsn("〘*VERSION*〙").
〘*AUTHOR*〙
〘*COPYRIGHT*〙
〘*LICENSE*〙

-export([start/0, start/1]).
-export([start/2, stop/1]).



-spec start() -> ok.
%% @doc
%% Start the server in an "ignore" state.

start() ->
    ok = application:start(hello_web),
    io:format("Starting...").


-spec start(PortNum) -> ok
    when PortNum :: inet:port_number().
%% @doc
%% Start the server and begin listening immediately. Slightly more convenient when
%% playing around in the shell.

start(PortNum) ->
    ok = start(),
    io:format("Startup complete, listening on ~w~n", [PortNum]).


-spec start(normal, term()) -> {ok, pid()}.
%% @private
%% Called by OTP to kick things off. This is for the use of the "application" part of
%% OTP, not to be called by user code.
%% See: http://erlang.org/doc/apps/kernel/application.html

start(normal, _Args) ->
    ok = application:ensure_started(sasl),
    {ok, Started} = application:ensure_all_started(cowboy),
    ok = io:format("Started: ~p~n", [Started]),
    Routes = [{'_', [{"/", 〘*PREFIX*〙_top, []}]}],
    Dispatch = cowboy_router:compile(Routes),
    Env = #{env => #{dispatch => Dispatch}},
    {ok, _} = cowboy:start_clear(〘*PREFIX*〙_listener, [{port, 8080}], Env),
    〘*PREFIX*〙_sup:start_link().


-spec stop(term()) -> ok.
%% @private
%% Similar to start/2 above, this is to be called by the "application" part of OTP,
%% not client code. Causes a (hopefully graceful) shutdown of the application.

stop(_State) ->
    ok.
