-module(webdriver_bidi_client).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

%% API

-export([start_link/1, send_command/2, subscribe_events/2]).

%% gen_server callbacks

-export(
    [
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
    ]
).
-export([test/0]).

%% Record to store state

-record(state, {
    %% Gun connection process
    conn,
    %% WebSocket stream reference
    stream_ref,
    %% Optional session ID
    session_id
}).

%%% Public API
%% Start the gen_server

start_link(Url) -> gen_server:start_link(?MODULE, Url, []).

%% Send a command to the WebDriver BiDi endpoint

send_command(Pid, Command) -> gen_server:call(Pid, {send_command, Command}).

%% Subscribe to WebDriver BiDi events

subscribe_events(Pid, Events) ->
    Command = #{method => <<"session.subscribe">>, params => #{events => Events}},
    send_command(Pid, Command).

%%% gen_server Callbacks
%% Initialize the gen_server

init(Url) ->
    {ok, Host, Port, Path} = parse_url(Url),
    %% Start the Gun connection
    {ok, Conn} = gun:open(Host, Port),
    %% Upgrade to WebSocket
    StreamRef = gun:ws_upgrade(Conn, Path),
    {ok, #state{conn = Conn, stream_ref = StreamRef, session_id = undefined}}.

%% Handle synchronous calls

handle_call(
    {send_command, Command},
    _From,
    State = #state{conn = Conn, stream_ref = StreamRef}
) ->
    %% Serialize the command as JSON
    JsonCommand = jsx:encode(Command),
    %% Send the command as a WebSocket message
    ok = gun:ws_send(Conn, StreamRef, {text, JsonCommand}),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, error, State}.

handle_cast(Event, State) ->
    ?LOG_DEBUG("webdriver_bidi got cast ~p", [Event, State]),
    {noreply, State}.

%% Handle asynchronous messages

handle_info({gun_ws, _Conn, _StreamRef, {text, Message}}, State) ->
    %% Handle incoming WebSocket messages
    io:format("Received message: ~s~n", [Message]),
    {noreply, State};
handle_info({gun_up, Conn, Protocol}, State) ->
    %% Handle Gun connection establishment
    io:format("Gun connection established: ~p, Protocol: ~p~n", [Conn, Protocol]),
    {noreply, State};
handle_info({gun_down, Conn, _, Reason, _}, State) ->
    %% Handle Gun connection termination
    io:format("Gun connection closed: ~p, Reason: ~p~n", [Conn, Reason]),
    {stop, Reason, State};
handle_info(_Info, State) ->
    {noreply, State}.

%% Terminate the gen_server

terminate(_Reason, #state{conn = Conn}) ->
    %% Close the Gun connection
    gun:close(Conn),
    ok.

%% Handle code changes (not needed for now)

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%% Helper Functions
%% Parse URL into components

parse_url(Url) ->
    #{scheme := "ws", host := Host, port := Port, path := Path} =
        uri_string:parse(Url),
    {ok, Host, Port, Path}.

test() ->
    %% Start the gen_server
    {ok, Pid} = webdriver_bidi_client:start_link("ws://localhost:9222/session"),
    %% Send a command (example: navigate to a URL)
    Command =
        #{
            method => <<"browsingContext.navigate">>,
            params =>
                #{url => <<"https://example.com">>, context => <<"my-context-id">>}
        },
    webdriver_bidi_client:send_command(Pid, Command),
    %% Subscribe to events
    webdriver_bidi_client:subscribe_events(Pid, [<<"log.entryAdded">>]).
