%% Permissioned operator API for funded indexing/verification rewards.
%% Not an HTTP API. Never expose caller-supplied Actor values over a network.
%% One coordinator owns one DETS ledger. Do not run replicas against one file.
-module(ecai_index_rewards).
-behaviour(gen_server).
-export([start_link/0, start_link/1, status/0, campaign/1, events/0,
         create/3, pool_create/3, register_participant/3, funding_invoice/2, refresh_funding/2, allocate/5,
         submit/5, attest/6, accept_work/5, cancel_unit/3, close/2,
         refund/2, submit_invoice/4, pay/4, reconcile/3, liquidity/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-record(st, {tab, ledger, config, adapter, pending = undefined, funding_hints = #{}, last_error = undefined}).
-define(TAB, ecai_index_reward_dets).

start_link() ->
    case application:get_env(ecai, index_rewards_enabled, false) of
        true -> start_link(application:get_env(ecai, index_rewards_config, #{}));
        _ -> {error, index_rewards_disabled}
    end.
start_link(Config) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).
status() -> gen_server:call(?MODULE, status).
campaign(Id) -> gen_server:call(?MODULE, {campaign, Id}).
events() -> gen_server:call(?MODULE, events).
create(Owner, Key, Contract) -> command({create, Owner, Key, Contract}).
%% Called only by the opt-in pool after DamageBDD bearer authentication. Keep
%% the ordinary operator API and its creator allowlist unchanged.
pool_create(Owner, Key, Contract) ->
    gen_server:call(?MODULE, {pool_create, Owner, Key, Contract}, 30000).
register_participant(Admin, Account, LightningNode) ->
    gen_server:call(?MODULE, {register_participant, Admin, Account, LightningNode}, 30000).
funding_invoice(Owner, Id) -> command({funding_invoice, Owner, Id}).
refresh_funding(Owner, Id) -> gen_server:call(?MODULE, {refresh_funding, Owner, Id}, 30000).
allocate(Owner, Id, Unit, Indexer, Verifier) -> command({allocate, Owner, Id, Unit, Indexer, Verifier}).
submit(Actor, Id, Unit, Artifact, Evidence) -> command({submit, Actor, Id, Unit, Artifact, Evidence}).
attest(Actor, Id, Unit, Artifact, Verdict, Report) -> command({attest, Actor, Id, Unit, Artifact, Verdict, Report}).
accept_work(Owner, Id, Unit, Artifact, Decision) -> command({accept_work, Owner, Id, Unit, Artifact, Decision}).
cancel_unit(Owner, Id, Unit) -> command({cancel_unit, Owner, Id, Unit}).
close(Owner, Id) -> command({close, Owner, Id}).
refund(Owner, Id) -> command({refund, Owner, Id}).
submit_invoice(Actor, Id, Pid, Bolt11) ->
    %% Decode outside the coordinator so a slow CLN RPC cannot block status or
    %% atomic budget reservations. The ledger rechecks all immutable fields.
    {Config, Adapter} = gen_server:call(?MODULE, adapter),
    case Adapter:decode(Config, Bolt11) of
        {ok, D} -> command({invoice, Actor, Id, Pid, Bolt11, D});
        Error -> Error
    end.
pay(Owner, Id, Pid, <<"pay indexing reward">>) -> command({pay, Owner, Id, Pid});
pay(_, _, _, _) -> {error, explicit_payment_confirmation_required}.
reconcile(Owner, Id, Pid) -> command({reconcile, Owner, Id, Pid}).
liquidity() -> ecai_index_rewards_cln:liquidity().
command(C) -> gen_server:call(?MODULE, {command, C}, 30000).

init(Config0) ->
    %% Explicit operator-owned storage only; no private keys/runes are stored here.
    File = filename:absname(maps:get(ledger_file, Config0)),
    ok = filelib:ensure_dir(File),
    case dets:open_file(?TAB, [{file, File}, {type, set}, {auto_save, 10000}]) of
        {ok, Tab} ->
            Saved = case dets:lookup(Tab, pool_participants) of
                [{pool_participants, P}] when is_map(P) -> P;
                [] -> #{}
            end,
            Configured = maps:get(participants, Config0, #{}),
            true = maps:fold(fun(A, N, Ok) -> Ok andalso maps:get(A, Configured, N) =:= N end, true, Saved),
            Config = Config0#{participants => maps:merge(Configured, Saved)},
            Old = case dets:lookup(Tab, ledger) of
                [] -> ecai_index_reward_ledger:new();
                [{ledger, #{schema := 1} = L}] -> L
            end,
            ok = ecai_index_reward_ledger:validate(Old, Config),
            L1 = ecai_index_reward_ledger:recover(Old, erlang:system_time(second)),
            persist(Tab, L1),
            _ = file:change_mode(File, 8#600),
            self() ! subscribe_funding,
            {ok, #st{tab = Tab, ledger = L1, config = Config,
                     adapter = maps:get(adapter, Config, ecai_index_rewards_cln)}};
        {error, R} -> {stop, {reward_ledger_unavailable, R}}
    end.

handle_call({register_participant, Admin, Account, Node}, _From, S) ->
    Allowed = application:get_env(ecai, index_pool_enabled, false) =:= true andalso
              ecai_node_admin:is_node_admin(Admin),
    Valid = is_binary(Account) andalso byte_size(Account) > 0 andalso byte_size(Account) =< 256
        andalso is_binary(Node) andalso re:run(Node, <<"^(02|03)[0-9a-f]{64}$">>, [{capture, none}]) =:= match,
    Ps = maps:get(participants, S#st.config, #{}),
    case {Allowed andalso Valid, maps:get(Account, Ps, Node) =:= Node} of
        {true, true} ->
            Next = Ps#{Account => Node},
            ok = dets:insert(S#st.tab, {pool_participants, Next}), ok = dets:sync(S#st.tab),
            {reply, ok, S#st{config = (S#st.config)#{participants => Next}}};
        {true, false} -> {reply, {error, participant_identity_pinned}, S};
        _ -> {reply, {error, admin_or_participant_invalid}, S}
    end;
handle_call({pool_create, Owner, Key, Contract}, _From, S) ->
    case application:get_env(ecai, index_pool_enabled, false) =:= true andalso
         ecai_node_admin:is_node_admin(Owner) of
        true ->
            Cfg = (S#st.config)#{creators => [Owner]},
            case ecai_index_reward_ledger:change({create, Owner, Key, Contract}, S#st.ledger, Cfg, erlang:system_time(second)) of
                {ok, Reply, L, none} -> persist(S#st.tab, L), {reply, {ok, Reply}, S#st{ledger = L}};
                Error -> {reply, Error, S}
            end;
        false -> {reply, {error, node_admin_required}, S}
    end;
handle_call(status, _From, S) ->
    Summary = ecai_index_reward_ledger:summary(S#st.ledger),
    {reply, Summary#{payments_enabled => maps:get(payments_enabled, S#st.config, false),
                     cln_operation_in_flight => S#st.pending =/= undefined,
                     last_error => S#st.last_error}, S};
handle_call({campaign, Id}, _From, S) -> {reply, ecai_index_reward_ledger:campaign(Id, S#st.ledger), S};
handle_call(events, _From, S) -> {reply, lists:reverse(maps:get(events, S#st.ledger)), S};
handle_call(adapter, _From, S) -> {reply, {S#st.config, S#st.adapter}, S};
handle_call({refresh_funding, Owner, Id}, _From, #st{pending = undefined} = S) ->
    case ecai_index_reward_ledger:campaign(Id, S#st.ledger) of
        {ok, #{owner := Owner, funding_label := Label}} ->
            {reply, {ok, funding_check_started}, launch({funding, Id, Label}, S)};
        _ -> {reply, {error, owner_required}, S}
    end;
handle_call({refresh_funding, _, _}, _From, S) -> {reply, {error, cln_operation_in_flight}, S};
handle_call({command, C}, _From, S) ->
    Network = lists:member(element(1, C), [funding_invoice, pay, reconcile]),
    case Network andalso S#st.pending =/= undefined of
        true -> {reply, {error, cln_operation_in_flight}, S};
        false ->
            case ecai_index_reward_ledger:change(C, S#st.ledger, S#st.config, erlang:system_time(second)) of
                {ok, Reply, L, Effect} ->
                    %% Failing a sync terminates this process BEFORE the effect.
                    persist(S#st.tab, L),
                    {reply, {ok, Reply}, launch(Effect, S#st{ledger = L, last_error = undefined})};
                Error -> {reply, Error, S}
            end
    end;
handle_call(_, _From, S) -> {reply, {error, unsupported_call}, S}.
handle_cast(_, S) -> {noreply, S}.

launch(none, S) -> S;
launch(Effect, #st{pending = undefined} = S) ->
    Parent = self(), Ref = make_ref(), A = S#st.adapter, Cfg = S#st.config,
    {Pid, Mon} = spawn_monitor(fun() ->
        Result = try effect(Effect, A, Cfg) catch _:_ -> {error, cln_unavailable} end,
        Parent ! {effect_result, Ref, Result}
    end),
    S#st{pending = #{ref => Ref, monitor => Mon, pid => Pid, effect => Effect}}.
effect({fund, _, Label, Amount}, A, Config) -> A:fund(Config, Label, Amount);
effect({funding, _, Label}, A, Config) -> A:funding(Config, Label);
effect({pay, _, _, P}, A, Config) -> A:pay(Config, P);
effect({reconcile, _, _, P}, A, Config) -> A:reconcile(Config, P).

handle_info({effect_result, Ref, Result}, #st{pending = #{ref := Ref, monitor := Mon, effect := E}} = S) ->
    erlang:demonitor(Mon, [flush]),
    {noreply, drain_funding(observe(E, Result, S#st{pending = undefined}))};
handle_info({'DOWN', Mon, process, _, _}, #st{pending = #{monitor := Mon, effect := E}} = S) ->
    {noreply, drain_funding(observe(E, {error, worker_interrupted}, S#st{pending = undefined}))};
handle_info(subscribe_funding, S) ->
    %% Existing DamageBDD/gproc topic. Registration is local, not a CLN RPC.
    _ = try damage_cln:register_listener(invoice_paid) catch _:_ -> unavailable end,
    {noreply, S};
handle_info({cln_event, invoice_paid, Hint}, S) when is_map(Hint) ->
    %% Events are hints only. NEVER credit the advertised amount or preimage.
    Label = maps:get(label, Hint, maps:get(<<"label">>, Hint, undefined)),
    Cs = maps:values(maps:get(campaigns, S#st.ledger)),
    Matches = [{maps:get(id, C), Label} || C <- Cs,
        maps:get(funding_label, C) =:= Label, maps:get(state, C) =:= awaiting_funding],
    Hints = maps:merge(S#st.funding_hints, maps:from_list(Matches)),
    {noreply, drain_funding(S#st{funding_hints = Hints})};
handle_info(_, S) -> {noreply, S}.

drain_funding(#st{pending = undefined, funding_hints = Hints} = S) when map_size(Hints) > 0 ->
    [{Id, Label} | _] = maps:to_list(Hints),
    launch({funding, Id, Label}, S#st{funding_hints = maps:remove(Id, Hints)});
drain_funding(S) -> S.

observe({fund, Id, _, _}, {ok, Invoice}, S) -> internal({funding_seen, Id, Invoice}, S);
observe({funding, Id, _}, {ok, Invoice}, S) -> internal({funding_seen, Id, Invoice}, S);
observe({Kind, Id, Pid, _}, Result, S) when Kind =:= pay; Kind =:= reconcile ->
    Outcome = case Result of {ok, M} when is_map(M) -> M; _ -> #{status => unknown} end,
    internal({payment_seen, Id, Pid, Outcome}, S);
observe(_, {error, Why}, S) -> S#st{last_error = Why};
observe(_, _, S) -> S#st{last_error = invalid_cln_response}.
internal(C, S) ->
    case ecai_index_reward_ledger:change(C, S#st.ledger, S#st.config, erlang:system_time(second)) of
        {ok, _Reply, L, none} -> persist(S#st.tab, L), S#st{ledger = L};
        {error, Why} -> S#st{last_error = Why}
    end.
persist(Tab, L) -> ok = dets:insert(Tab, {ledger, L}), ok = dets:sync(Tab).
terminate(_, S) -> dets:sync(S#st.tab), dets:close(S#st.tab), ok.
code_change(_, S, _) -> {ok, S}.
