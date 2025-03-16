-module(nostr_relay).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

%% API
-export([start_link/0, publish_event/1, subscribe/1, get_events/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(TABLE, nostr_events).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

publish_event(Event) ->
    gen_server:cast(?MODULE, {publish, Event}).

subscribe(Filter) ->
    gen_server:call(?MODULE, {subscribe, Filter}).

get_events(Filter) ->
    gen_server:call(?MODULE, {get_events, Filter}).

%%% gen_server Callbacks

init([]) ->
    ets:new(?TABLE, [named_table, public, set]),
    {ok, #{subscribers => #{}}}.

handle_call({subscribe, Filter}, _From, State) ->
    ?LOG_INFO("Subscribe filter: ~p", [Filter]),
    {reply, ok, State};
handle_call({get_events, Filter}, _From, State) ->
    Events = [E || {_, E} <- ets:tab2list(?TABLE), match_filter(E, Filter)],
    {reply, Events, State}.

handle_cast({publish, #{id := Id} = Event}, State) ->
    case validate_event(Event) of
        true ->
            ets:insert(?TABLE, {Id, Event}),
            broadcast_event(Event, State),
            {noreply, State};
        false ->
            {noreply, State}
    end.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% Internal Helpers

validate_event(#{
    id := Id, pubkey := Pubkey, created_at := CreatedAt, kind := Kind, content := Content
}) ->
    is_binary(Id) andalso is_binary(Pubkey) andalso is_integer(CreatedAt) andalso is_integer(Kind) andalso
        is_binary(Content);
validate_event(_) ->
    false.

match_filter(Event, Filter) ->
    ?LOG_INFO("Match event: ~p filter: ~p", [Event, Filter]),
    %% TODO: Implement real filter logic
    true.

broadcast_event(Event, State) ->
    ?LOG_INFO("broadcast event: ~p filter: ~p", [Event, State]),
    %% TODO: Implement broadcasting to subscribers
    ok.
