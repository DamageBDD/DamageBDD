-module(lightning_auth_cache).
-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").

-behaviour(gen_server).

-export([start_link/0, store/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).
-export([fetch_by_k1/1]).
-export([fetch_key_by_lnaddress/1]).
-export([store_key_for_lnaddress/2]).

-define(TABLE, auth_challenges).
-define(LNADDR_TABLE, lnaddress_keys).
% seconds
-define(TTL, 600).

%%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
store(Challenge, Meta) ->
    ?LOG_DEBUG("storing cache ~p", [Challenge]),
    gen_server:call(?MODULE, {store, Challenge, Meta}).
store_key_for_lnaddress(LnAddress, PubKey) ->
    gen_server:call(?MODULE, {store_key_for_lnaddress, LnAddress, PubKey}).

fetch_by_k1(Challenge) ->
    gen_server:call(?MODULE, {fetch_by_k1, Challenge}).
fetch_key_by_lnaddress(LnAddress) ->
    gen_server:call(?MODULE, {fetch_key_by_lnaddress, LnAddress}).

%%% Callbacks
init([]) ->
    ets:new(?TABLE, [named_table, public, set]),
    timer:send_interval(60000, clean_expired),
    {ok, #{}}.
handle_call({store, Challenge, Meta}, _From, State) ->
    Timestamp = erlang:system_time(seconds),
    ets:insert(?TABLE, {Challenge, Meta, Timestamp}),
    {reply, ok, State};
handle_call({store_key_for_lnaddress, LnAddress, PubKey}, _From, State) ->
    ets:insert(?LNADDR_TABLE, {LnAddress, PubKey}),
    {reply, ok, State};
handle_call({fetch_key_by_lnaddress, LnAddress}, _From, State) ->
    case ets:lookup(?LNADDR_TABLE, LnAddress) of
        [{LnAddress, Key}] ->
            {reply, {ok, Key}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;
handle_call({fetch_by_k1, Challenge}, _From, State) ->
    case ets:lookup(?TABLE, Challenge) of
        [{Challenge, Meta, Timestamp}] ->
            Now = erlang:system_time(seconds),
            case Now - Timestamp =< ?TTL of
                true -> {reply, {ok, {Meta, Timestamp}}, State};
                false -> {reply, {error, expired}, State}
            end;
        [] ->
            {reply, {error, not_found}, State}
    end.

handle_info(clean_expired, State) ->
    Now = erlang:system_time(seconds),
    [ets:delete(?TABLE, K) || {K, _, T} <- ets:tab2list(?TABLE), Now - T > ?TTL],
    {noreply, State};
handle_info(_, State) ->
    {noreply, State}.

handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.
