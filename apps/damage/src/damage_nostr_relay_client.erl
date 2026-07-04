%%--------------------------------------------------------------------
%% damage_nostr_relay_client
%%
%% Phase 3 relay bridge for the Damage NIP-46 nsecbunker.
%%
%% This module deliberately keeps relay publication outside bunker scope.
%% The bunker returns a signed response event. This module then attempts
%% relay publication and reports that result separately.
%%--------------------------------------------------------------------
-module(damage_nostr_relay_client).

-behaviour(gen_server).

-export([
    start_link/0,
    child_spec/0,
    status/0,
    subscribe/0,
    inbound_event/1,
    publish_event/1,
    handle_inbound_event/2,
    handle_bunker_result/2,
    publish_event/2,
    subscribe/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    config = #{},
    started_at = 0,
    subscribed = false
}).

-define(NIP46_KIND, 24133).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    }.

status() ->
    call(status).

subscribe() ->
    call(subscribe).

inbound_event(Event) when is_map(Event) ->
    call({inbound_event, Event}).

publish_event(Event) when is_map(Event) ->
    call({publish_event, Event}).

call(Request) ->
    case whereis(?MODULE) of
        undefined -> {error, relay_client_not_running};
        _Pid -> gen_server:call(?MODULE, Request, 30000)
    end.

%%====================================================================
%% gen_server
%%====================================================================

init([]) ->
    Config = phase3_config(),
    AutoSubscribe = maps:get(relay_autosubscribe, Config, false),
    Subscribed =
        case AutoSubscribe of
            true ->
                case subscribe(Config) of
                    {ok, _} -> true;
                    _ -> false
                end;
            _ ->
                false
        end,
    {ok, #state{config = Config, started_at = erlang:system_time(second), subscribed = Subscribed}}.

handle_call(
    status, _From, State = #state{config = Config, started_at = StartedAt, subscribed = Subscribed}
) ->
    {reply,
        #{
            running => true,
            started_at => StartedAt,
            subscribed => Subscribed,
            config => safe_config(Config)
        },
        State};
handle_call(subscribe, _From, State = #state{config = Config}) ->
    Reply = subscribe(Config),
    Subscribed =
        case Reply of
            {ok, _} -> true;
            _ -> false
        end,
    {reply, Reply, State#state{subscribed = Subscribed}};
handle_call({inbound_event, Event}, _From, State = #state{config = Config}) ->
    {reply, handle_inbound_event(Event, Config), State};
handle_call({publish_event, Event}, _From, State = #state{config = Config}) ->
    {reply, publish_event(Event, Config), State};
handle_call(_Other, _From, State) ->
    {reply, {error, unknown_relay_client_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Pure Phase 3 flow
%%====================================================================

handle_inbound_event(Event0, Config0) when is_map(Event0) ->
    Config = normalize_config(Config0),
    Event = damage_nostr_event:normalize_event(Event0),
    case validate_inbound_nip46(Event, Config) of
        ok ->
            BunkerResult = damage_nsecbunker:handle_nip46_event(Event),
            handle_bunker_result(BunkerResult, Config);
        {error, Reason} ->
            {error, Reason}
    end.

handle_bunker_result({ok, ResponseEvent0}, Config0) when is_map(ResponseEvent0) ->
    Config = normalize_config(Config0),
    ResponseEvent = damage_nostr_event:normalize_event(ResponseEvent0),
    PublishResult = publish_event(ResponseEvent, Config),
    {ok, #{
        signing_result => ok,
        response_event => ResponseEvent,
        publish_result => PublishResult
    }};
handle_bunker_result({error, Reason}, _Config) ->
    {error, Reason};
handle_bunker_result(Other, _Config) ->
    {error, {unexpected_bunker_result, Other}}.

validate_inbound_nip46(Event, Config) ->
    case maps:get(kind, Event, undefined) of
        ?NIP46_KIND -> validate_p_tag(Event, Config);
        Other -> {error, {unexpected_nip46_event_kind, Other}}
    end.

validate_p_tag(Event, Config) ->
    %% If bunker pubkey is configured, inbound events should be p-tagged to it.
    %% Keep this validation optional for direct tests and early relay bring-up.
    case maps:get(require_inbound_p_tag, Config, true) of
        false ->
            ok;
        true ->
            BunkerPubkey = bunker_pubkey(Config),
            case BunkerPubkey of
                <<>> ->
                    ok;
                _ ->
                    Values = damage_nostr_event:tag_values(Event, <<"p">>),
                    case lists:member(BunkerPubkey, Values) of
                        true -> ok;
                        false -> {error, inbound_event_not_p_tagged_to_bunker}
                    end
            end
    end.

subscribe(Config0) ->
    Config = normalize_config(Config0),
    Filter = nip46_filter(Config),
    case maps:get(relay_publication_mode, Config, normal) of
        return_only -> {ok, #{subscription => skipped_return_only, filter => Filter}};
        test_fail -> {error, relay_subscribe_test_failure};
        _ -> call_configured_relay_subscribe(Filter, Config)
    end.

publish_event(Event, Config0) when is_map(Event) ->
    Config = normalize_config(Config0),
    case maps:get(relay_publication_mode, Config, normal) of
        return_only ->
            {ok, #{
                publication => skipped_return_only, event_kind => maps:get(kind, Event, undefined)
            }};
        test_fail ->
            {error, relay_publish_test_failure};
        _ ->
            call_configured_relay_publish(Event, Config)
    end.

nip46_filter(Config) ->
    BunkerPubkey = bunker_pubkey(Config),
    Base = #{kinds => [?NIP46_KIND]},
    case BunkerPubkey of
        <<>> -> Base;
        _ -> Base#{<<"#p">> => [BunkerPubkey]}
    end.

call_configured_relay_subscribe(Filter, Config) ->
    case maps:get(relay_subscribe_mfa, Config, undefined) of
        {M, F} -> safe_apply(M, F, [Filter]);
        {M, F, ExtraArgs} when is_list(ExtraArgs) -> safe_apply(M, F, [Filter | ExtraArgs]);
        undefined -> try_known_subscribe(Filter)
    end.

call_configured_relay_publish(Event, Config) ->
    case maps:get(relay_publish_mfa, Config, undefined) of
        {M, F} -> safe_apply(M, F, [Event]);
        {M, F, ExtraArgs} when is_list(ExtraArgs) -> safe_apply(M, F, [Event | ExtraArgs]);
        undefined -> try_known_publish(Event, Config)
    end.

try_known_subscribe(Filter) ->
    case erlang:function_exported(nosternity_relay, subscribe, 1) of
        true -> safe_apply(nosternity_relay, subscribe, [Filter]);
        false -> {error, relay_subscribe_not_wired}
    end.

try_known_publish(Event, Config) ->
    Relays = maps:get(relays, Config, []),
    case erlang:function_exported(nosternity_relay, publish_event, 1) of
        true ->
            safe_apply(nosternity_relay, publish_event, [Event]);
        false ->
            case erlang:function_exported(nosternity_relay, broadcast_event, 2) of
                true -> safe_apply(nosternity_relay, broadcast_event, [Relays, Event]);
                false -> {error, relay_publish_not_wired}
            end
    end.

safe_apply(M, F, Args) ->
    try apply(M, F, Args) of
        {ok, _} = Ok -> Ok;
        ok -> {ok, ok};
        {error, _} = Error -> Error;
        Other -> {ok, Other}
    catch
        Class:Reason:Stack ->
            {error, {relay_mfa_failed, M, F, Class, Reason, Stack}}
    end.

phase3_config() ->
    case application:get_env(damage, nsecbunker) of
        {ok, Config} -> normalize_config(Config);
        undefined -> #{}
    end.

normalize_config(Config) when is_map(Config) -> Config;
normalize_config(Config) when is_list(Config) -> maps:from_list(Config);
normalize_config(_) -> #{}.

bunker_pubkey(Config) ->
    bin(first_defined([bunker_pubkey_hex, bunker_pubkey], Config, <<>>)).

first_defined([], _Config, Default) ->
    Default;
first_defined([Key | Rest], Config, Default) ->
    case maps:get(Key, Config, undefined) of
        undefined -> first_defined(Rest, Config, Default);
        Value -> Value
    end.

safe_config(Config) ->
    maps:without([vault_passphrase, secret, nsec, private_key], Config).

bin(undefined) -> <<>>;
bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> unicode:characters_to_binary(L);
bin(I) when is_integer(I) -> integer_to_binary(I);
bin(Other) -> unicode:characters_to_binary(io_lib:format("~p", [Other])).
