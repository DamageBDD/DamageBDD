-module(nosternity_relay).
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

publish_event(Event0) ->
    Event = damage_nostr_event:normalize_event(Event0),
    gen_server:call(?MODULE, {publish, Event}, 5000).

subscribe(Filter) ->
    gen_server:call(?MODULE, {subscribe, Filter}).

get_events(Filter) ->
    gen_server:call(?MODULE, {get_events, Filter}).

%%% gen_server Callbacks

init([]) ->
    ets:new(?TABLE, [named_table, public, set]),
    State = #{subscribers => #{}, hydrate_offset => 0, hydrated => false},
    case application:get_env(nosternity, ae_event_store_rehydrate, true) of
        true -> self() ! hydrate;
        _ -> ok
    end,
    {ok, State}.

handle_call({publish, Event}, _From, State) ->
    {Reply, State1} = do_publish(Event, State),
    {reply, Reply, State1};
handle_call({subscribe, Filter}, _From, State) ->
    ?LOG_INFO("Subscribe filter: ~p", [Filter]),
    {reply, ok, State};
handle_call({get_events, Filter}, _From, State) ->
    Events = [E || {_, E} <- ets:tab2list(?TABLE), match_filter(E, Filter)],
    {reply, Events, State}.

handle_cast({publish, Event}, State) ->
    {_Reply, State1} = do_publish(Event, State),
    {noreply, State1};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(hydrate, State0) ->
    {noreply, hydrate_page(State0)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% Internal Helpers

do_publish(#{id := Id} = Event, State) ->
    case validate_event(Event) of
        true ->
            %% Nostr event ids are immutable. insert_new prevents duplicate
            %% relay deliveries from producing duplicate chain-store work.
            case ets:insert_new(?TABLE, {Id, Event}) of
                true ->
                    nosternity_event_store:store(Event),
                    broadcast_event(Event, State),
                    {ok, State};
                false ->
                    {ok, State}
            end;
        false ->
            ?LOG_WARNING("Ignoring invalid Nostr event ~p", [Id]),
            {{error, invalid_event}, State}
    end;
do_publish(Event, State) ->
    ?LOG_WARNING("Ignoring malformed Nostr event ~p", [Event]),
    {{error, invalid_event}, State}.

hydrate_page(#{hydrated := true} = State) ->
    State;
hydrate_page(State0) ->
    Offset = maps:get(hydrate_offset, State0, 0),
    PageSize = hydrate_page_size(),
    case nosternity_event_store:get_events(Offset, PageSize) of
        {ok, Events} when is_list(Events) ->
            lists:foreach(
                fun
                    (#{id := Id} = Event) -> ets:insert_new(?TABLE, {Id, Event});
                    (_) -> ok
                end,
                Events
            ),
            Count = length(Events),
            State1 = State0#{hydrate_offset => Offset + Count},
            case Count < PageSize of
                true ->
                    ?LOG_INFO("Nosternity relay rehydrated ~p Aeternity-backed events", [
                        Offset + Count
                    ]),
                    State1#{hydrated => true};
                false ->
                    self() ! hydrate,
                    State1
            end;
        {error, disabled} ->
            State0#{hydrated => true};
        {error, contract_unavailable} ->
            maybe_retry_hydrate(State0);
        {error, Reason} ->
            ?LOG_WARNING("Nosternity event-store rehydrate failed offset=~p reason=~p", [
                Offset, Reason
            ]),
            maybe_retry_hydrate(State0)
    end.

maybe_retry_hydrate(State) ->
    case application:get_env(nosternity, ae_event_store_enabled, false) of
        true ->
            Delay = application:get_env(nosternity, ae_event_store_retry_ms, 5000),
            erlang:send_after(positive_delay(Delay, 5000), self(), hydrate),
            State;
        _ ->
            State#{hydrated => true}
    end.

hydrate_page_size() ->
    case application:get_env(nosternity, ae_event_store_hydrate_page_size, 25) of
        N when is_integer(N), N > 0, N =< 100 -> N;
        _ -> 25
    end.

positive_delay(N, _Default) when is_integer(N), N > 0 -> N;
positive_delay(_, Default) -> Default.

validate_event(Event) when is_map(Event) ->
    case damage_nostr_event:verify(Event) of
        {ok, _} -> true;
        {error, _} -> false
    end;
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
