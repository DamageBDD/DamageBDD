%%%-------------------------------------------------------------------
%%% GTKGS greeter UI. Authentication prompts themselves are native so no
%%% secret response traverses gtkgs/Erlang distribution.
%%%-------------------------------------------------------------------
-module(erm_dm_ui).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, show/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
show() -> gen_server:call(?MODULE, show, 10000).
status() -> gen_server:call(?MODULE, status).

init([]) -> self() ! build, {ok, #{window => undefined, users => [], sessions => [], message => <<"Select a user">>}}.
handle_call(show, _F, S = #{window := undefined}) ->
    S1 = build(S),
    case maps:get(window, S1, undefined) of
        undefined -> {reply, {error, ui_unavailable}, S1};
        _ -> {reply, ok, S1}
    end;
handle_call(show, _F, S) ->
    _ = safe(fun() -> gtkgs:config(dm_window,[{map,true}]) end),
    {reply, ok, S};
handle_call(status, _F, S) -> {reply, S, S};
handle_call(_,_,S) -> {reply,{error,unsupported_call},S}.
handle_cast(_,S) -> {noreply,S}.

handle_info(build, S) -> {noreply, build(S)};
handle_info({erm_dm_auth, Event}, S) -> {noreply, set_message(auth_message(Event), S)};
handle_info({gtkgs, dm_users, selection_changed, Data, _}, S) ->
    case selected_text(Data) of undefined -> {noreply,S}; User -> _=erm_dm:select_user(User), {noreply,set_message(<<"Ready to sign in">>,S)} end;
handle_info({gtkgs, dm_sessions, selection_changed, Data, _}, S) ->
    case selected_text(Data) of undefined -> {noreply,S}; Label -> select_session_by_label(Label,S) end;
handle_info({gtkgs, dm_login, click, _, _}, S) -> _=erm_dm:login(), {noreply,set_message(<<"Authenticating…">>,S)};
handle_info({gtkgs, dm_cancel, click, _, _}, S) -> _=erm_dm:cancel(), {noreply,set_message(<<"Cancelled">>,S)};
handle_info({gtkgs, dm_power, click, _, _}, S) -> _=erm_dm:poweroff(), {noreply,S};
handle_info({gtkgs, dm_reboot, click, _, _}, S) -> _=erm_dm:reboot(), {noreply,S};
handle_info(_,S) -> {noreply,S}.
terminate(_,_) -> ok.
code_change(_,S,_) -> {ok,S}.

build(S0) ->
    case {erm_dm_users:list(), erm_dm_sessions:list()} of
        {{ok, Users}, {ok, Sessions}} ->
            UserNames = [maps:get(username,U) || U <- Users],
            Labels = [maps:get(label,X) || X <- Sessions],
            Tree = [{window,dm_window,[{title,"erm login"},{width,520},{height,680},{map,true},{class,'erm-dm'}],[
                {frame,dm_root,[{orient,vertical},{spacing,12},{margin,24},{expand,true}],[
                    {label,dm_title,[{text,"erm"},{class,'title-1'}]},
                    {label,dm_subtitle,[{text,"Sign in"},{class,'title-3'}]},
                    {listbox,dm_users,[{items,UserNames},{selection,single},{expand,true}]},
                    {listbox,dm_sessions,[{items,Labels},{selection,single},{min_height,80}]},
                    {label,dm_status,[{text,"Select a user"},{wrap,true},{align,start}]},
                    {frame,dm_actions,[{orient,horizontal},{spacing,8}],[
                        {button,dm_login,[{label,"Sign in"}]},{button,dm_cancel,[{label,"Cancel"}]},
                        {button,dm_reboot,[{label,"Restart"}]},{button,dm_power,[{label,"Power off"}]}
                    ]}
                ]}
            ]}],
            case safe(fun() -> gtkgs:create_tree(gtkgs:server(), Tree) end) of
                {ok,[W]} -> S0#{window=>W,users=>Users,sessions=>Sessions};
                Error -> ?LOG_WARNING("erm dm ui build failed: ~p",[Error]), S0
            end;
        Error -> ?LOG_WARNING("erm dm data unavailable: ~p",[Error]), S0
    end.

select_session_by_label(Label, S) ->
    case [maps:get(id,X) || X <- maps:get(sessions,S), maps:get(label,X)=:=Label] of
        [Id|_] -> _=erm_dm:select_session(Id), {noreply,S};
        [] -> {noreply,S}
    end.
selected_text(Data) when is_map(Data) -> maps:get(text,Data,undefined);
selected_text(_) -> undefined.
set_message(M,S) -> _=safe(fun()->gtkgs:config(dm_status,[{text,M}]) end), S#{message=>M}.
auth_message(prompt) -> <<"Authentication input required">>;
auth_message(authenticating) -> <<"Authenticating…">>;
auth_message(accepted) -> <<"Starting session…">>;
auth_message(cancelled) -> <<"Cancelled">>;
auth_message(auth_failed) -> <<"Authentication failed">>;
auth_message(_) -> <<"Authentication error">>.
safe(F) -> try F() catch C:R -> {error,{C,R}} end.
