%%--------------------------------------------------------------------
%% damage_nostr_relay_client
%%
%% Thin adapter for NIP-46 relay flow. This module intentionally does not add
%% a second websocket stack by default. It can be wired to existing Damage
%% relay infrastructure, or left disabled while BDD exercises plain requests.
%%--------------------------------------------------------------------
-module(damage_nostr_relay_client).

-behaviour(gen_server).

-export([
    start_link/0,
    subscribe/0,
    publish/1,
    inbound_event/1,
    status/0
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    config = #{},
    relays = [],
    subscribed = false
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

subscribe() ->
    gen_server:call(?MODULE, subscribe, 30000).

publish(Event) when is_map(Event) ->
    gen_server:call(?MODULE, {publish, Event}, 30000).

%% Call this from the existing relay receive path when a kind:24133 event arrives.
inbound_event(Event) when is_map(Event) ->
    gen_server:cast(?MODULE, {inbound_event, Event}).

status() ->
    gen_server:call(?MODULE, status, 5000).

init([]) ->
    Config = damage_nsecbunker:config(),
    Relays = maps:get(relays, Config, damage_nostr:configured_relays()),
    {ok, #state{config = Config, relays = Relays}}.

handle_call(status, _From, State = #state{relays = Relays, subscribed = Subscribed}) ->
    {reply, #{relays => Relays, subscribed => Subscribed}, State};
handle_call(subscribe, _From, State = #state{config = Config}) ->
    Reply = subscribe_with_existing_stack(Config),
    NewState =
        case Reply of
            ok -> State#state{subscribed = true};
            _ -> State
        end,
    {reply, Reply, NewState};
handle_call({publish, Event}, _From, State = #state{config = Config}) ->
    {reply, publish_with_existing_stack(Event, Config), State};
handle_call(_Other, _From, State) ->
    {reply, {error, bad_call}, State}.

handle_cast({inbound_event, Event}, State) ->
    case damage_nsecbunker:handle_nip46_event(Event) of
        {ok, ResponseEvent} ->
            _ = publish_with_existing_stack(ResponseEvent, State#state.config),
            ok;
        _Other ->
            ok
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

subscribe_with_existing_stack(Config) ->
    BunkerPubkey = maps:get(bunker_pubkey_hex, damage_nsecbunker:policy(Config), <<>>),
    Filter = #{kinds => [24133], <<"#p">> => [BunkerPubkey]},
    case maybe_local_relay_subscribe(Filter) of
        ok -> ok;
        {error, _} -> {error, {relay_subscribe_not_wired, Filter}}
    end.

publish_with_existing_stack(Event, _Config) ->
    case maybe_local_relay_publish(Event) of
        ok -> ok;
        {error, _} -> {error, relay_publish_not_wired}
    end.

maybe_local_relay_publish(Event) ->
    _ = code:ensure_loaded(nosternity_relay),
    case erlang:function_exported(nosternity_relay, publish_event, 1) of
        true ->
            nosternity_relay:publish_event(Event),
            ok;
        false ->
            {error, no_local_relay_publish}
    end.

maybe_local_relay_subscribe(Filter) ->
    _ = code:ensure_loaded(nosternity_relay),
    case erlang:function_exported(nosternity_relay, subscribe, 1) of
        true -> nosternity_relay:subscribe(Filter);
        false -> {error, no_local_relay_subscribe}
    end.
