%%% Durable, node-local theme catalog, selection and purchase journal.
%%% Only this supervised process writes the DETS table; sync after mutations.
-module(damage_theme_store).
-behaviour(gen_server).
-export([start_link/0, list/0, get/1, put/1, selection/1, select/3,
         order/1, put_order/1, update_order/2, update_theme/2,
         active_order_count/1, begin_mint/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-define(TABLE, damage_theme_store_data).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
list() -> gen_server:call(?MODULE, list).
get(K) -> gen_server:call(?MODULE, {get, K}).
put(M) -> gen_server:call(?MODULE, {put, M}).
update_theme(K, Changes) -> gen_server:call(?MODULE, {update_theme, K, Changes}).
selection(App) -> gen_server:call(?MODULE, {selection, App}).
select(App, Key, Brand) -> gen_server:call(?MODULE, {select, App, Key, Brand}).
order(Id) -> gen_server:call(?MODULE, {order, Id}).
put_order(O) -> gen_server:call(?MODULE, {put_order, O}).
update_order(Id, State) -> gen_server:call(?MODULE, {update_order, Id, State}).
active_order_count(Account) -> gen_server:call(?MODULE, {active_order_count, Account}).
begin_mint(Id) -> gen_server:call(?MODULE, {begin_mint, Id}).

init([]) ->
    Path = filename:join([damage_config:state_dir(), "themes", "catalog.dets"]),
    ok = filelib:ensure_dir(Path),
    case dets:open_file(?TABLE, [{file, Path}, {type, set}, {repair, true}]) of
        {ok, Tab} -> {ok, #{table => Tab}};
        {error, Reason} -> {stop, {theme_store_unavailable, Reason}}
    end.

handle_call(list, _From, State) ->
    Rows = dets:foldl(fun({{theme, _K}, V}, Acc) -> [V | Acc]; (_, Acc) -> Acc end, [], ?TABLE),
    {reply, {ok, Rows}, State};
handle_call({get, Key}, _From, State) -> {reply, lookup({theme, Key}), State};
handle_call({put, #{<<"key">> := Key} = Theme}, _From, State) ->
    Reply = case lookup({theme, Key}) of
        {ok, _} -> {error, already_published};
        not_found -> write({theme, Key}, Theme)
    end,
    {reply, Reply, State};
handle_call({update_theme, Key, Changes}, _From, State) ->
    Reply = case lookup({theme, Key}) of
        {ok, Theme} -> write({theme, Key}, maps:merge(Theme, maps:with([<<"status">>], Changes)));
        not_found -> {error, theme_not_found}
    end,
    {reply, Reply, State};
handle_call({selection, App}, _From, State) ->
    {reply, case lookup({selection, App}) of
        {ok, Selection} -> {ok, Selection};
        not_found -> {ok, #{<<"key">> => <<"damage-dark@1.0.0">>, <<"branding">> => #{}}}
    end, State};
handle_call({select, App, Key, Brand}, _From, State) ->
    {reply, write({selection, App}, #{<<"key">> => Key, <<"branding">> => Brand}), State};
handle_call({order, Id}, _From, State) -> {reply, lookup({order, Id}), State};
handle_call({active_order_count, Account}, _From, State) ->
    {reply, active_orders(Account), State};
handle_call({put_order, #{<<"order_id">> := Id, <<"account">> := Account} = Order}, _From, State) ->
    %% Enforce the limit atomically, so simultaneous HTTP requests cannot
    %% create an unbounded number of outstanding Lightning checkouts.
    Reply = case lookup({order, Id}) of
        not_found ->
            case active_orders(Account) < 5 of
                true -> write({order, Id}, Order);
                false -> {error, too_many_pending_invoices}
            end;
        _ -> {error, duplicate_order}
    end,
    {reply, Reply, State};
handle_call({begin_mint, Id}, _From, State) ->
    %% Compare-and-swap the journal state BEFORE initiating a chain write.
    %% No second polling request may rebroadcast the same paid order.
    Reply = case lookup({order, Id}) of
        {ok, #{<<"status">> := <<"unpaid">>} = Order} ->
            case write({order, Id}, Order#{<<"status">> => <<"minting">>}) of
                ok -> {ok, Order};
                Error -> Error
            end;
        {ok, _} -> {error, order_already_processing};
        not_found -> {error, order_not_found}
    end,
    {reply, Reply, State};
handle_call({update_order, Id, Changes}, _From, State) ->
    Reply = case lookup({order, Id}) of
        {ok, Order} -> write({order, Id}, maps:merge(Order, Changes));
        not_found -> {error, order_not_found}
    end,
    {reply, Reply, State};
handle_call(_, _From, State) -> {reply, {error, bad_call}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> dets:close(?TABLE), ok.
code_change(_, State, _) -> {ok, State}.

lookup(Key) ->
    case dets:lookup(?TABLE, Key) of
        [{Key, Value}] -> {ok, Value};
        [] -> not_found
    end.
write(Key, Value) ->
    case dets:insert(?TABLE, {Key, Value}) of
        ok -> dets:sync(?TABLE);
        Error -> Error
    end.

active_orders(Account) ->
    Now = erlang:system_time(second),
    dets:foldl(fun
        ({{order, _Id}, #{<<"account">> := Owner, <<"status">> := <<"unpaid">>,
                         <<"expires_at">> := Expires}}, Count)
            when Owner =:= Account, Expires >= Now -> Count + 1;
        (_, Count) -> Count
    end, 0, ?TABLE).
