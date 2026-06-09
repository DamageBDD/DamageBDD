-module(erm_window_event_handler).
-behaviour(gen_server).

%% API
-export([start_link/0, stop/0, subscribe/1, unsubscribe/0]).

%% gen_server callbacks
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, terminate/2, code_change/3]).

-record(state, {
    port,
    current_tag = "unknown",
    %% [{Pid, CallbackFun}]
    subscribers = []
}).

-define(HERBSCLIENT, "herbstclient").

%%% Public API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:cast(?MODULE, stop).

%% Allow external modules to subscribe to herbst events
subscribe(Fun) when is_function(Fun, 1) ->
    gen_server:call(?MODULE, {subscribe, self(), Fun}).

unsubscribe() ->
    gen_server:call(?MODULE, {unsubscribe, self()}).

%%% GenServer Callbacks

init([]) ->
    Port = open_port({spawn, "herbstclient --idle"}, [stream, {line, 16384}, use_stdio]),
    {ok, #state{port = Port}}.

handle_info({Port, {data, Line}}, State = #state{port = Port, subscribers = Subs}) ->
    Event = parse_event(Line),
    [catch apply(Fun, [Event]) || {_Pid, Fun} <- Subs],
    {noreply, State};
handle_info({_Port, closed}, State) ->
    io:format("⚠️  herbstclient port closed.~n"),
    {stop, normal, State};
handle_info({'EXIT', Port, Reason}, State = #state{port = Port}) ->
    io:format("💥 herbstclient port died: ~p~n", [Reason]),
    {stop, normal, State};
handle_info({port, _Port, {data, Data}}, State) ->
    Line = binary_to_list(Data),
    case string:tokens(Line, " ") of
        ["tag_changed" | _] ->
            CurrentTag = get_tag(),
            NewState = State#state{current_tag = CurrentTag},
            update_xsetroot(CurrentTag),
            {noreply, NewState};
        _ ->
            {noreply, State}
    end;
handle_info(timeout, State) ->
    %% Initial set of tag
    CurrentTag = get_tag(),
    update_xsetroot(CurrentTag),
    {noreply, State#state{current_tag = CurrentTag}};
handle_info(_, State) ->
    {noreply, State}.

handle_call({subscribe, Pid, Fun}, _From, State) ->
    NewSubs = lists:keystore(Pid, 1, State#state.subscribers, {Pid, Fun}),
    {reply, ok, State#state{subscribers = NewSubs}};
handle_call({unsubscribe, Pid}, _From, State) ->
    NewSubs = lists:keydelete(Pid, 1, State#state.subscribers),
    {reply, ok, State#state{subscribers = NewSubs}};
handle_call(_, _From, State) ->
    {reply, ok, State}.

handle_cast(stop, State = #state{port = Port}) ->
    port_close(Port),
    {stop, normal, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

get_tag() ->
    case os:cmd(?HERBSCLIENT ++ " attr tags.focus.name") of
        [] -> "unknown";
        Tag -> string:trim(Tag)
    end.

update_xsetroot(Tag) ->
    _ = os:cmd("xsetroot -name '" ++ Tag ++ "'").

%%% Event Parsing

parse_event(Line) ->
    string:tokens(string:trim(Line), " ").
