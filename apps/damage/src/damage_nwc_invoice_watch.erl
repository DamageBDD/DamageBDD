-module(damage_nwc_invoice_watch).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(GUARD_TABLE, damage_nwc_invoice_watch_guard).
-define(RESTORE_PAGE_LIMIT, 100).

-record(state, {
    %% Wallet => queue:[InvoiceOrPayload]
    queues = #{} :: map(),
    %% MonitorRef => Wallet
    in_flight = #{} :: map()
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    ok = ensure_guard_table(),
    ok = ensure_invoice_paid_subscription(),
    ?LOG_INFO("invoice watcher init pid=~p", [self()]),
    {ok, #state{}}.

handle_call(restore_open_invoices, _From, State) ->
    Reply =
        case whereis(cln) of
            undefined ->
                {error, cln_not_started};
            _ ->
                restore_open_invoices_into_self()
        end,
    {reply, Reply, State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({cln_event, invoice_paid, Payload}, State) ->
    case wallet_from_invoice(Payload) of
        {ok, Wallet} ->
            {noreply, enqueue_and_maybe_start(Wallet, Payload, State)};
        {error, Why} ->
            ?LOG_INFO("damage_nwc_invoice_watch ignores payload reason=~p payload=~p", [
                Why, Payload
            ]),
            {noreply, State}
    end;
handle_info({process_wallet_invoice, Wallet}, State) ->
    {noreply, maybe_start_next(Wallet, State)};
handle_info({'DOWN', Ref, process, _Pid, Reason}, #state{in_flight = InFlight0} = State) ->
    case maps:take(Ref, InFlight0) of
        {Wallet, InFlight} ->
            ?LOG_DEBUG("wallet invoice worker done wallet=~p reason=~p", [Wallet, Reason]),
            State1 = State#state{in_flight = InFlight},
            {noreply, maybe_start_next(Wallet, State1)};
        error ->
            {noreply, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    catch gproc:unreg({p, l, {cln_event, invoice_paid}}),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Queueing / sequencing
%% ------------------------------------------------------------------

enqueue_and_maybe_start(Wallet, InvoiceOrPayload, #state{queues = Queues0} = State) ->
    Q0 = maps:get(Wallet, Queues0, queue:new()),
    Q1 = queue:in(InvoiceOrPayload, Q0),
    Queues = Queues0#{Wallet => Q1},
    maybe_start_next(Wallet, State#state{queues = Queues}).

maybe_start_next(Wallet, #state{queues = Queues, in_flight = InFlight} = State) ->
    case wallet_busy(Wallet, InFlight) of
        true ->
            State;
        false ->
            case maps:get(Wallet, Queues, queue:new()) of
                Q ->
                    case queue:out(Q) of
                        {{value, InvoiceOrPayload}, Q2} ->
                            Queues2 =
                                case queue:is_empty(Q2) of
                                    true -> maps:remove(Wallet, Queues);
                                    false -> Queues#{Wallet => Q2}
                                end,
                            Ref = start_invoice_worker(Wallet, InvoiceOrPayload),
                            State#state{
                                queues = Queues2,
                                in_flight = InFlight#{Ref => Wallet}
                            };
                        {empty, _} ->
                            State
                    end
            end
    end.

wallet_busy(Wallet, InFlight) ->
    lists:any(
        fun({_Ref, W}) -> W =:= Wallet end,
        maps:to_list(InFlight)
    ).

start_invoice_worker(Wallet, InvoiceOrPayload) ->
    Parent = self(),
    {Pid, Ref} =
        spawn_monitor(fun() ->
            process_invoice_for_wallet(Wallet, InvoiceOrPayload),
            Parent ! {process_wallet_invoice, Wallet}
        end),
    _ = Pid,
    Ref.

process_invoice_for_wallet(_Wallet, InvoiceOrPayload) ->
    case resolve_settled_invoice(InvoiceOrPayload) of
        {ok, Invoice} ->
            Label = invoice_label(Invoice),
            case safe_handle_settled_invoice(Label, Invoice) of
                ok ->
                    ok;
                {error, Why} ->
                    ?LOG_ERROR("invoice watch hook failed label=~p reason=~p", [Label, Why]),
                    ok
            end;
        {error, Why} ->
            ?LOG_ERROR("invoice watch resolve settled failed reason=~p payload=~p", [
                Why, InvoiceOrPayload
            ]),
            ok
    end.

%% ------------------------------------------------------------------
%% Restore
%% ------------------------------------------------------------------

restore_open_invoices_into_self() ->
    Now = erlang:system_time(second),
    Opts = #{
        page_limit => ?RESTORE_PAGE_LIMIT,
        unpaid_only => false,
        paid_only => true,
        label_prefix => <<"nwc:">>,
        min_expires_at => Now - 7 * 24 * 60 * 60
    },
    case cln:list_all_invoices(Opts) of
        {ok, Invoices} ->
            lists:foreach(
                fun(Invoice) ->
                    case wallet_from_invoice(Invoice) of
                        {ok, Wallet} ->
                            self() ! {cln_event, invoice_paid, Invoice},
                            ?LOG_DEBUG("restored settled invoice wallet=~p label=~p", [
                                Wallet, invoice_label(Invoice)
                            ]);
                        {error, _} ->
                            ok
                    end
                end,
                Invoices
            ),
            ok;
        Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% Safe settlement handling
%% ------------------------------------------------------------------

safe_handle_settled_invoice(Label, Invoice) when is_binary(Label) ->
    case claim_settled(Label) of
        claimed ->
            try damage_nwc_invoice_hooks:handle_settled_invoice(Invoice) of
                ok ->
                    ok = mark_settled_done(Label),
                    ok;
                {ok, _} ->
                    ok = mark_settled_done(Label),
                    ok;
                already_done ->
                    ok = mark_settled_done(Label),
                    ok;
                Other ->
                    ok = release_settled(Label),
                    {error, {unexpected_hook_result, Other}}
            catch
                Class:Reason:Stack ->
                    ok = release_settled(Label),
                    ?LOG_ERROR(
                        "invoice settled hook crashed label=~p class=~p reason=~p stack=~p",
                        [Label, Class, Reason, Stack]
                    ),
                    {error, {hook_failed, Class, Reason}}
            end;
        already_handled ->
            ok;
        in_progress ->
            ok
    end.

resolve_settled_invoice(Invoice) when is_map(Invoice) ->
    case is_settled(Invoice) of
        true ->
            {ok, Invoice};
        false ->
            case invoice_label(Invoice) of
                Label when is_binary(Label), Label =/= <<>> ->
                    case cln:list_invoices_by_label(Label) of
                        #{invoices := Invoices} ->
                            case find_settled_invoice(Invoices) of
                                {ok, SettledInvoice} -> {ok, SettledInvoice};
                                false -> {error, invoice_not_yet_settled}
                            end;
                        Other ->
                            {error, {unexpected_invoice_lookup_result, Other}}
                    end;
                _ ->
                    {error, missing_label}
            end
    end.

find_settled_invoice(Invoices) ->
    case lists:filter(fun is_settled/1, Invoices) of
        [Invoice | _] -> {ok, Invoice};
        [] -> false
    end.

is_settled(#{state := <<"SETTLED">>}) -> true;
is_settled(#{<<"state">> := <<"SETTLED">>}) -> true;
is_settled(#{status := <<"paid">>}) -> true;
is_settled(#{<<"status">> := <<"paid">>}) -> true;
is_settled(_) -> false.

%% ------------------------------------------------------------------
%% Label / wallet parsing
%% ------------------------------------------------------------------

wallet_from_invoice(Invoice) when is_map(Invoice) ->
    case invoice_label(Invoice) of
        Label when is_binary(Label) ->
            wallet_from_label(Label);
        _ ->
            {error, missing_label}
    end.

wallet_from_label(Label) when is_binary(Label) ->
    case binary:split(Label, <<":">>, [global]) of
        [<<"nwc">>, Wallet, _Session, _Ref] ->
            {ok, Wallet};
        [<<"nwc">>, Wallet, _Ref] ->
            {ok, Wallet};
        Other ->
            {error, {bad_label, Other}}
    end.

invoice_label(#{label := Label}) when is_binary(Label) -> Label;
invoice_label(#{<<"label">> := Label}) when is_binary(Label) -> Label;
invoice_label(#{details := #{label := Label}}) when is_binary(Label) -> Label;
invoice_label(#{<<"details">> := #{<<"label">> := Label}}) when is_binary(Label) -> Label;
invoice_label(_) -> undefined.

%% ------------------------------------------------------------------
%% Shared guard
%% ------------------------------------------------------------------

ensure_guard_table() ->
    case ets:info(?GUARD_TABLE) of
        undefined ->
            try ets:new(?GUARD_TABLE, [named_table, public, set, {read_concurrency, true}]) of
                _ -> ok
            catch
                error:badarg -> ok
            end;
        _ ->
            ok
    end.

claim_settled(Label) ->
    ok = ensure_guard_table(),
    case ets:insert_new(?GUARD_TABLE, {{settled, Label}, in_progress}) of
        true ->
            claimed;
        false ->
            case ets:lookup(?GUARD_TABLE, {settled, Label}) of
                [{{settled, Label}, done}] -> already_handled;
                [{{settled, Label}, in_progress}] -> in_progress;
                _ -> in_progress
            end
    end.

mark_settled_done(Label) ->
    ok = ensure_guard_table(),
    ets:insert(?GUARD_TABLE, {{settled, Label}, done}),
    ok.

release_settled(Label) ->
    ok = ensure_guard_table(),
    case ets:lookup(?GUARD_TABLE, {settled, Label}) of
        [{{settled, Label}, in_progress}] ->
            ets:delete(?GUARD_TABLE, {settled, Label}),
            ok;
        _ ->
            ok
    end.

ensure_invoice_paid_subscription() ->
    case catch gproc:reg({p, l, {cln_event, invoice_paid}}) of
        true -> ok;
        ok -> ok;
        {error, {already_registered, _}} -> ok;
        _ -> ok
    end.
