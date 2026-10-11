%% Side-effect-free adapter boundary for future Coinstore POST_ONLY execution.
%% Does NOT sign, send, or cancel exchange orders.
-module(ecai_mm_execution_plan).
-export([build/2, reconcile/3]).

build(Quotes, Config) when is_list(Quotes), is_map(Config) ->
    P = maps:get(price_decimals, Config, 8),
    Q = maps:get(quantity_decimals, Config, 4),
    Symbol = maps:get(symbol, Config, <<"DAMAGEUSDT">>),
    case is_integer(P) andalso P >= 0 andalso P =< 16 andalso
         is_integer(Q) andalso Q >= 0 andalso Q =< 16 of
        false -> {error, invalid_precision};
        true ->
            try {ok, [order(X, Symbol, P, Q) || X <- Quotes]}
            catch _:_ -> {error, invalid_quote} end
    end;
build(_, _) -> {error, invalid_quote}.

order(Quote, Symbol, P, Q) ->
    Side = case maps:get(side, Quote) of
        buy -> <<"BUY">>;
        sell -> <<"SELL">>
    end,
    #{symbol => Symbol, side => Side, ordType => <<"POST_ONLY">>,
      ordPrice => iolist_to_binary(io_lib:format("~.*f", [P, maps:get(price, Quote)])),
      ordQty => iolist_to_binary(io_lib:format("~.*f", [Q, maps:get(remaining_qty, Quote)])),
      clOrdId => maps:get(client_id, Quote)}.

%% Explicit ownership ledger is required. Never cancel manual orders, including
%% those on the same symbol/API key as the engine.
reconcile(OwnedIds, ActiveIds, DesiredOrders) when
    is_list(OwnedIds), is_list(ActiveIds), is_list(DesiredOrders) ->
    DesiredIds = [maps:get(clOrdId, Q) || Q <- DesiredOrders],
    #{cancel_ids => [Id || Id <- OwnedIds,
                           lists:member(Id, ActiveIds),
                           not lists:member(Id, DesiredIds)],
      create => [Q || Q <- DesiredOrders,
                       not lists:member(maps:get(clOrdId, Q), ActiveIds)]}.
