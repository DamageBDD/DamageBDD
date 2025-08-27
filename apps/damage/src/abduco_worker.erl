-module(abduco_worker).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {name, cmd}).

start_link(#{name := Name, cmd := Cmd}) ->
    gen_server:start_link({via, gproc, {n, l, Name}}, ?MODULE, #{name => Name, cmd => Cmd}, []).

init(#{name := Name, cmd := Cmd} = State) ->
    ensure_abduco_session(Name, Cmd),
    {ok, #state{name = Name, cmd = Cmd}}.

ensure_abduco_session(Name, Cmd) ->
    Sessions = os:cmd("abduco -l"),
    SessionList = string:tokens(Sessions, "\n"),
    case lists:any(fun(Line) -> string:find(Line, Name) =/= nomatch end, SessionList) of
        true ->
            ok;
        false ->
            Cmd0 = secrets:interpolate_template(Cmd),
            ?LOG_INFO("Starting abduco session ~s: ~s", [Name, Cmd0]),
            _ = os:cmd("abduco -n " ++ Name ++ " " ++ Cmd0),
            ok
    end.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
