%%%-------------------------------------------------------------------
%%% gtknode4 - Controller for the GTK4 C-node
%%%
%%% Responsibilities:
%%%   - Maintain connection to gtknode4 C-node
%%%   - Provide a small, clean API for the rest of the system
%%%   - Translate replies & signals into Erlang messages / callbacks
%%%-------------------------------------------------------------------
-module(gtknode4).

-behaviour(gen_server).

%% Public API
-export([
    start_link/0,
    load_ui/1,
    set_label/2,
    get_label/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    % remote C-node pid
    gtk_pid :: pid() | undefined,
    % ref -> gen_server from
    pending :: #{reference() => pid()},
    % room for config later
    options :: map()
}).

%%%===================================================================
%%% Public API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

%% Load a GtkBuilder UI file on the C-node
-spec load_ui(file:filename()) -> ok | {error, term()}.
load_ui(Filename) ->
    gen_server:call(?MODULE, {load_ui, Filename}).

%% Set label on a widget (button/label)
-spec set_label(
    WidgetName :: atom() | binary() | string(),
    Text :: iodata()
) -> ok | {error, term()}.
set_label(WidgetName, Text) ->
    gen_server:call(?MODULE, {set_label, WidgetName, iolist_to_binary(Text)}).

%% Get label from widget (button/label)
-spec get_label(WidgetName :: atom() | binary() | string()) ->
    {ok, binary()} | {error, term()}.
get_label(WidgetName) ->
    gen_server:call(?MODULE, {get_label, WidgetName}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),

    %% In your real system you will either:
    %%   - spawn the C-node as an OS process, OR
    %%   - let it connect in as a distributed node and send {gtknode4, ok}.
    %%
    %% Here we simply log and wait for the hello.
    io:format("~p: waiting for gtknode4 C-node handshake~n", [?MODULE]),

    {ok, #state{
        gtk_pid = undefined,
        pending = #{},
        options = Opts
    }}.

handle_call(_Req, _From, State = #state{gtk_pid = undefined}) ->
    {reply, {error, not_connected}, State};
handle_call({load_ui, Filename}, From, State) ->
    Ref = make_ref(),
    Command = {load_ui, Filename},
    ok = send_call(State, Ref, Command),
    {noreply, remember_pending(Ref, From, State)};
handle_call({set_label, WidgetName, Text}, From, State) ->
    Ref = make_ref(),
    Command = {set_label, normalize_name(WidgetName), Text},
    ok = send_call(State, Ref, Command),
    {noreply, remember_pending(Ref, From, State)};
handle_call({get_label, WidgetName}, From, State) ->
    Ref = make_ref(),
    Command = {get_label, normalize_name(WidgetName)},
    ok = send_call(State, Ref, Command),
    {noreply, remember_pending(Ref, From, State)}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({gtknode4, ok}, State) ->
    %% Handshake from C-node; message will be delivered to this
    %% registered process name (peer_regname on C side).
    io:format("~p: gtknode4 C-node handshake OK~n", [?MODULE]),
    {noreply, State};
%% Reply from C-node: {gtknode4, reply, Ref, Result}
handle_info({gtknode4, reply, Ref, Result}, State) ->
    case maps:take(Ref, State#state.pending) of
        {From, Pending1} ->
            gen_server:reply(From, Result),
            {noreply, State#state{pending = Pending1}};
        error ->
            %% Unknown ref; maybe log
            io:format(
                "~p: stray reply from gtknode4 ~p~n",
                [?MODULE, Ref]
            ),
            {noreply, State}
    end;
%% Signal from C-node: {gtknode4, signal, WidgetName, SignalName, Payload}
handle_info({gtknode4, signal, WidgetName, SignalName, Payload}, State) ->
    %% You can route this to a pubsub, another process, or handle inline.
    io:format(
        "gtknode4 signal: ~p ~p ~p~n",
        [WidgetName, SignalName, Payload]
    ),
    {noreply, State};
%% If you decide to track the remote pid explicitly:
handle_info(
    {'EXIT', Pid, Reason},
    State = #state{gtk_pid = Pid}
) ->
    io:format("gtknode4: C-node exited: ~p~n", [Reason]),
    %% Optionally fail hard, or try re-connect/spawn.
    {noreply, State#state{gtk_pid = undefined}};
handle_info(Other, State) ->
    io:format("~p: unexpected message ~p~n", [?MODULE, Other]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal helpers
%%%===================================================================

-spec send_call(#state{}, reference(), term()) -> ok.
send_call(#state{gtk_pid = undefined}, _Ref, _Command) ->
    exit({gtknode4_not_connected, no_pid});
send_call(#state{gtk_pid = Pid}, Ref, Command) ->
    %% Shape: {gtknode4, call, Ref, Command}
    Pid ! {gtknode4, call, Ref, Command},
    ok.

remember_pending(Ref, From, State = #state{pending = Pending}) ->
    State#state{pending = Pending#{Ref => From}}.

normalize_name(Name) when is_binary(Name) ->
    Name;
normalize_name(Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
normalize_name(Name) when is_list(Name) ->
    list_to_binary(Name).
