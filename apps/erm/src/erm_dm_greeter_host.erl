%%%-------------------------------------------------------------------
%%% Owns the temporary greeter Xorg. The authenticated desktop gets a fresh
%%% Xorg from erm_dm_session_host after greetd replaces the greeter session.
%%%-------------------------------------------------------------------
-module(erm_dm_greeter_host).
-behaviour(gen_server).

-export([start_link/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state,{xorg=undefined,display=undefined,xauthority=undefined,phase=starting}).

start_link() -> gen_server:start_link({local,?MODULE},?MODULE,[],[]).
status() -> gen_server:call(?MODULE,status).

init([]) -> process_flag(trap_exit,true), erlang:send_after(100,self(),start_xorg), {ok,#state{}}.
handle_call(status,_F,S) -> {reply,#{phase=>S#state.phase,display=>S#state.display,
    xauthority_present=>S#state.xauthority=/=undefined,xorg_alive=>is_port(S#state.xorg)},S};
handle_call(_,_,S) -> {reply,{error,unsupported_call},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info(start_xorg,S) ->
    case erm_dm_xorg:start_greeter_display() of
        {ok,#{port:=P,display:=D,xauthority:=XA}} ->
            link(P), os:putenv("DISPLAY",binary_to_list(D)), os:putenv("XAUTHORITY",binary_to_list(XA)),
            _=erm_display:refresh(), self() ! start_gtk,
            {noreply,S#state{xorg=P,display=D,xauthority=XA,phase=display_ready}};
        Error -> {stop,{greeter_xorg_failed,Error},S}
    end;
handle_info(start_gtk,S) ->
    _=erm_sup:sync_gtknode4(),
    erlang:send_after(250,self(),show_ui),
    {noreply,S};
handle_info(show_ui,S) ->
    case catch erm_dm_ui:show() of
        ok -> {noreply,S#state{phase=running}};
        _ -> erlang:send_after(500,self(),show_ui), {noreply,S}
    end;
handle_info({P,{exit_status,Status}},S=#state{xorg=P}) -> {stop,{xorg_exit,Status},S};
handle_info({'EXIT',P,Reason},S=#state{xorg=P}) -> {stop,{xorg_exit,Reason},S};
handle_info(_,S) -> {noreply,S}.
terminate(_,S) ->
    case S#state.xorg of undefined->ok; P when is_port(P)->catch port_close(P) end,
    case S#state.xauthority of undefined->ok; XA->file:delete(binary_to_list(XA)) end,
    ok.
code_change(_,S,_) -> {ok,S}.
