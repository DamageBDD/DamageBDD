-module(price_feed).
-behaviour(gen_server).

%% API
-export([start_link/0, get_price/0]).

%% gen_server callbacks
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

% 10 minutes in milliseconds
-define(INTERVAL, 10 * 60 * 1000).

-record(state, {
    price = undefined :: undefined | float()
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_price() ->
    gen_server:call(?MODULE, get_price).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    self() ! fetch,
    {ok, #state{}}.

handle_info(fetch, State) ->
    NewState =
        case fetch_btc_aud_price() of
            {ok, Price} ->
                ?LOG_DEBUG("Fetched BTC/AUD price: ~p", [Price]),
                State#state{price = Price};
            {error, Reason} ->
                ?LOG_WARNING("Failed to fetch BTC/AUD price: ~p", [Reason]),
                State
        end,
    erlang:send_after(?INTERVAL, self(), fetch),
    {noreply, NewState};
handle_info(_, State) ->
    {noreply, State}.

handle_call(get_price, _From, State) ->
    {reply, State#state.price, State};
handle_call(_, _From, State) ->
    {reply, ok, State}.

handle_cast(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

-spec fetch_btc_aud_price() -> {ok, float()} | {error, term()}.
fetch_btc_aud_price() ->
    % TODO: use oracles instead
    {ok, ConnPid} = gun:open("api.coinbase.com", 443, #{
        transport => tls, tls_opts => [{verify, verify_none}]
    }),
    StreamRef = gun:get(ConnPid, "/v2/prices/BTC-AUD/spot", [
        {<<"accept">>, <<"application/json">>}
    ]),
    case gun:await(ConnPid, StreamRef, 600000) of
        {response, nofin, Status, _Headers0} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            ?LOG_DEBUG("read_stream Status ~p Response: ~p", [Status, Body]),
            case catch jsx:decode(Body, [return_maps]) of
                [
                    <<"data">>,
                    #{
                        <<"code">> := 5,
                        <<"error">> :=
                            _Error,
                        <<"message">> :=
                            Message
                    }
                ] ->
                    ?LOG_DEBUG("Got unexpected response ~p.", [Message]),
                    {error, Message};
                Map when is_map(Map) ->
                    PriceStr = maps:get(<<"amount">>, maps:get(<<"data">>, Map)),
                    {ok, binary_to_float(PriceStr)};
                Other ->
                    ?LOG_DEBUG("Got unexpected response ~p.", [Other]),
                    {error, Other}
            end
    end.
