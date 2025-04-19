-module(nosternity_websocket).
-behaviour(cowboy_websocket).

%% API
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).

%% Required for JSON parsing

%% State structure:
%% #{subscriptions => #{ClientPid => Filter}}

-record(state, {subscriptions = #{}}).

%%% WebSocket Lifecycle Callbacks %%%

init(Req, _State) ->
    {cowboy_websocket, Req, #state{}}.

websocket_init(State) ->
    {ok, State}.

websocket_handle({text, Msg}, State) ->
    case parse_json(Msg) of
        {ok, ["EVENT", Event]} ->
            handle_event(Event, State);
        {ok, ["REQ", SubId, Filter]} ->
            handle_subscription(SubId, Filter, State);
        {ok, ["CLOSE", SubId]} ->
            handle_unsubscribe(SubId, State);
        {error, _} ->
            {reply, {text, encode_json(["NOTICE", "Invalid message format"])}, State}
    end;
websocket_handle(_Data, State) ->
    {ok, State}.

websocket_info({broadcast, Event}, State) ->
    EncodedMsg = encode_json(["EVENT", Event]),
    {reply, {text, EncodedMsg}, State};
websocket_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _Req, _State) ->
    ok.

%%% Internal Functions %%%

handle_event(Event, State) ->
    case nostr_relay:publish_event(Event) of
        ok ->
            {reply, {text, encode_json(["NOTICE", "Event received"])}, State};
        error ->
            {reply, {text, encode_json(["NOTICE", "Invalid event"])}, State}
    end.

handle_subscription(SubId, Filter, #state{subscriptions = Subs} = State) ->
    UpdatedSubs = Subs#{SubId => Filter},
    Events = nostr_relay:get_events(Filter),
    Response = encode_json(["EVENTS", SubId, Events]),
    {reply, {text, Response}, State#state{subscriptions = UpdatedSubs}}.

handle_unsubscribe(SubId, #state{subscriptions = Subs} = State) ->
    UpdatedSubs = maps:remove(SubId, Subs),
    {reply, {text, encode_json(["NOTICE", "Unsubscribed"])}, State#state{
        subscriptions = UpdatedSubs
    }}.

%%% JSON Helpers %%%
parse_json(Message) ->
    try
        {ok, jsx:decode(Message, [{labels, atom}, return_maps])}
    catch
        _:_ -> {error, invalid_json}
    end.

encode_json(Data) ->
    jsx:encode(Data).
