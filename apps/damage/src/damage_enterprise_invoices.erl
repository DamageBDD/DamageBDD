%% Enterprise receivables, separate from DAMAGE credit/top-up invoices.
%% A single supervised writer owns numbering, calendar cursors and the outbox.
%% No BDD reports, IPFS uploads, public payment routes or wallet debit authority.
-module(damage_enterprise_invoices).
-behaviour(gen_server).
-license("Apache-2.0").
-include_lib("kernel/include/logger.hrl").
-export([start_link/0, request/2, tick/0, cfg/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, format_status/1]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
%% Account must come from verified transport authentication. Local VM callers
%% are trusted, as with the existing Damage admin APIs.
request(Account, Command) when is_binary(Account) ->
    try gen_server:call(?MODULE, {request, Account, Command}, 30000)
    catch exit:_ -> {error, unavailable} end.
tick() ->
    case whereis(?MODULE) of undefined -> ok; Pid -> gen_server:cast(Pid, tick) end.
cfg(Key, Default) -> proplists:get_value(Key, application:get_env(damage, enterprise_invoices, []), Default).

init([]) ->
    process_flag(trap_exit, true),
    {ok, #{data => undefined, backend => cfg(backend, damage_invoice_backend), busy => none,
           last_tick => erlang:monotonic_time(second) - 60}}.

handle_call({request, Account, Command}, _From, S0) ->
    case ready(S0) of
        {error, S} -> {reply, {error, unavailable}, S};
        {ok, #{data := D} = S} ->
            Role = role(Account, D),
            case Role of
                denied -> {reply, {error, forbidden}, S};
                _ ->
                    try command(Command, Account, Role, D, S) of
                        {Reply, D1} ->
                            {Result, S1} = commit(Reply, D1, S),
                            {reply, Result, S1}
                    catch
                        throw:{validation, Message} -> {reply, {error, {validation, Message}}, S};
                        throw:{conflict, Message} -> {reply, {error, {conflict, Message}}, S};
                        throw:not_found -> {reply, {error, not_found}, S};
                        throw:forbidden -> {reply, {error, forbidden}, S};
                        _:_ ->
                            ?LOG_ERROR("Enterprise billing command failed (payload omitted)"),
                            {reply, {error, unavailable}, S}
                    end
            end
    end;
handle_call({begin_smtp, Ref}, _From, #{busy := #{ref := Ref, id := Id, kind := email}, data := D} = S)
    when is_map(D) ->
    I = fetch(invoices, Id, D),
    B = maps:get(backend, S),
    Permitted = cfg(enabled, false) =:= true andalso safe_ready(B) andalso email_allowed(I, D),
    case {maps:get(status, I), maps:get(status, maps:get(delivery, I)), Permitted} of
        {<<"issued">>, <<"queued">>, true} ->
            Delivery = (maps:get(delivery, I))#{status => <<"sending">>, started_at => now_s()},
            I1 = audit_invoice(I#{delivery => Delivery}, <<"system">>, <<"smtp_started">>, <<>>),
            {Reply, S1} = commit(ok, put(invoices, Id, I1, D), S),
            {reply, Reply, S1};
        _ -> {reply, {error, cancelled}, S}
    end;
handle_call({begin_smtp, _}, _From, S) -> {reply, {error, cancelled}, S};
handle_call({begin_settlement_nft, Ref}, _From,
            #{busy := #{ref := Ref, id := Id, kind := settlement_nft}, data := D} = S)
    when is_map(D) ->
    I = fetch(invoices, Id, D),
    Settlement = maps:get(settlement_nft, I, #{status => <<"not_requested">>}),
    Permitted = settlement_allowed(Settlement),
    case {maps:get(status, I), maps:get(status, Settlement, <<"not_requested">>), Permitted} of
        {<<"paid">>, <<"queued">>, true} ->
            S1Map = Settlement#{status => <<"minting">>, started_at => now_s()},
            I1 = audit_invoice(I#{settlement_nft => S1Map}, <<"system">>,
                               <<"settlement_reward_started">>, <<>>),
            {Reply, S1} = commit(ok, put(invoices, Id, I1, D), S),
            {reply, Reply, S1};
        _ -> {reply, {error, cancelled}, S}
    end;
handle_call({begin_settlement_nft, _}, _From, S) -> {reply, {error, cancelled}, S};
handle_call(_, _From, S) -> {reply, {error, bad_request}, S}.

handle_cast(tick, S0) ->
    Now = erlang:monotonic_time(second),
    case Now - maps:get(last_tick, S0) >= 60 of
        false -> {noreply, S0};
        true ->
            S1 = S0#{last_tick => Now},
            case ready(S1) of
                {error, S} -> {noreply, S};
                {ok, S} ->
                    D = maps:get(data, S),
                    D1 = scheduled(D, S),
                    {_, S2} = commit(ok, D1, S),
                    {noreply, start_job(S2)}
            end
    end;
handle_cast(kick, S) -> {noreply, start_job(S)};
handle_cast(_, S) -> {noreply, S}.

handle_info({invoice_job, Ref, Result}, #{busy := #{ref := Ref} = Job} = S0) ->
    cancel_job_timer(Job),
    erlang:demonitor(maps:get(monitor, Job), [flush]),
    S = finish_job(Job, Result, S0#{busy => none}),
    gen_server:cast(self(), kick),
    {noreply, S};
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #{busy := #{monitor := Mon} = Job} = S0) ->
    cancel_job_timer(Job),
    S = finish_job(Job, {error, worker_stopped}, S0#{busy => none}),
    gen_server:cast(self(), kick),
    {noreply, S};
handle_info({invoice_job_timeout, Ref}, #{busy := #{ref := Ref, pid := Pid}} = S) ->
    exit(Pid, kill),
    {noreply, S};
handle_info({'EXIT', _, _}, S) -> {noreply, S};
handle_info(_, S) -> {noreply, S}.
terminate(_, S) -> stop_job(S), B = maps:get(backend, S), B:close(), ok.
code_change(_, S, _) -> {ok, S}.
format_status(Status) ->
    Status#{state => <<"enterprise invoice state redacted">>,
            message => <<"redacted">>, reason => <<"redacted">>}.

%% Authentication roles are derived from trusted configuration and private
%% grants. Never use client JSON, user-editable account context or booleans.
role(Account, D) ->
    Shared = application:get_env(damage, l402_account, undefined),
    case Account =:= to_bin(Shared) of
        true -> denied;
        false ->
            case damage_auth:is_node_admin_account(Account) of
                true -> node_admin;
                false ->
                    Admins = configured_admins() ++ maps:get(admins, D, []),
                    case lists:member(Account, Admins) of true -> invoice_admin; false -> denied end
            end
    end.
configured_admins() ->
    [to_bin(A) || A <- application:get_env(damage, invoice_admins, []), is_binary(A) orelse is_list(A)].

ready(#{backend := B} = S) ->
    case cfg(enabled, false) =:= true andalso safe_ready(B) of
        false -> stop_job(S), B:close(), {error, S#{data => undefined, busy => none}};
        true -> load(S)
    end.
safe_ready(B) -> try B:ready() =:= true catch _:_ -> false end.
load(#{data := D} = S) when is_map(D) -> {ok, S};
load(#{backend := B} = S) ->
    case B:load() of
        {ok, D0} ->
            D = recover(D0),
            case B:save(D) of
                ok -> {ok, S#{data => D}};
                _ -> B:close(), {error, S}
            end;
        _ -> B:close(), {error, S}
    end.
recover(D) ->
    Is = maps:map(fun(_, I0) ->
        Delivery = maps:get(delivery, I0),
        I1 = case maps:get(status, Delivery) of
            <<"sending">> ->
                audit_invoice(I0#{delivery => Delivery#{status => <<"unknown">>,
                    last_error => <<"Restart during SMTP; check relay before retrying">>}},
                    <<"system">>, <<"smtp_outcome_unknown">>, <<>>);
            _ -> I0
        end,
        Settlement = maps:get(settlement_nft, I1, #{status => <<"not_requested">>}),
        case maps:get(status, Settlement, <<"not_requested">>) of
            <<"minting">> ->
                audit_invoice(I1#{settlement_nft => Settlement#{status => <<"unknown">>,
                    last_error => <<"Restart during settlement mint; retry safely to reconcile the unique attestation hash">>}},
                    <<"system">>, <<"settlement_reward_outcome_unknown">>, <<>>);
            _ -> I1
        end
    end, maps:get(invoices, D)),
    D#{invoices => Is}.

commit(Reply, D, #{data := D} = S) -> {Reply, S};
commit(Reply, D, #{backend := B} = S) ->
    case B:save(D) of
        ok -> gen_server:cast(self(), kick), {Reply, S#{data => D}};
        _ ->
            ?LOG_ERROR("Enterprise billing persistence failed; stopping invoice work"),
            stop_job(S), B:close(),
            {{error, unavailable}, S#{data => undefined, busy => none}}
    end.

command(session, _A, Role, D, _S) ->
    Settings = effective_settings(D),
    {{ok, #{role => Role, can_manage_admins => Role =:= node_admin,
            can_manage_settings => Role =:= node_admin,
            auto_send_enabled => cfg(auto_send, false), clock => cfg(clock, node_local),
            send_hour => cfg(send_hour, 9),
            payment_profiles => [<<"default">> | [to_bin(K) || {K, _} <- cfg(payment_profiles, [])]],
            settlement_rewards => damage_invoice_settlement_nft:status(),
            seller_country => maps:get(country_code, maps:get(seller, Settings)),
            default_tax_bps => maps:get(default_rate_bps, maps:get(tax, maps:get(seller, Settings))),
            admin_count => length(maps:get(admins, D))}}, D};
command(settings, _, _, D, _) -> {{ok, effective_settings(D)}, D};
command({save_settings, M}, A, node_admin, D, _) ->
    Old = effective_settings(D),
    damage_invoice_model:revision(M, Old),
    Settings = damage_invoice_model:billing_settings(M, Old),
    D1 = root_audit(D#{settings => Settings}, A, <<"billing_settings_saved">>, <<"seller">>),
    {{ok, Settings}, D1};
command({save_settings, _}, _, _, _, _) -> throw(forbidden);
command(summary, _, _, D, _) -> {{ok, billing_summary(D)}, D};
command({list, customers}, _, _, D, _) -> {{ok, #{items => sorted(customers, D)}}, D};
command({list, plans}, _, _, D, _) -> {{ok, #{items => sorted(plans, D)}}, D};
command({list_invoices, Query}, _, _, D, _) -> {{ok, invoice_page(Query, D)}, D};
command({get_invoice, Id}, _, _, D, _) -> {{ok, fetch(invoices, Id, D)}, D};
command({get_pdf, Id}, _, _, D, #{backend := B}) ->
    I = fetch(invoices, Id, D),
    require(lists:member(maps:get(status, I), [<<"issued">>, <<"paid">>, <<"void">>])
            andalso maps:is_key(pdf_sha256, I), <<"Invoice PDF is not issued yet">>),
    Reply = case B:get_pdf(Id) of
        {ok, PDF} ->
            case hash(PDF) =:= maps:get(pdf_sha256, I) of
                true -> {pdf, maps:get(number, I), PDF};
                false -> {error, unavailable}
            end;
        _ -> {error, unavailable}
    end,
    {Reply, D};
command({create_customer, M}, A, _, D, _) ->
    Id = create_customer_id(M, D),
    Seller = maps:get(seller, effective_settings(D)),
    M1 = case maps:is_key(<<"country_code">>, M) of
        true -> M;
        false -> M#{<<"country_code">> => maps:get(country_code, Seller, <<"AU">>)}
    end,
    C = damage_invoice_model:customer(M1#{<<"id">> => Id}, #{}),
    {{ok, C}, root_audit(put(customers, Id, C, D), A, <<"customer_created">>, Id)};
command({save_customer, Id, M}, A, _, D, _) ->
    Old = maps:get(Id, maps:get(customers, D), #{}),
    update_revision(M, Old),
    C = damage_invoice_model:customer(M#{<<"id">> => Id}, Old),
    {{ok, C}, root_audit(put(customers, Id, C, D), A, <<"customer_saved">>, Id)};
command({save_plan, Id, M}, A, _, D, _) ->
    Old = maps:get(Id, maps:get(plans, D), #{}),
    update_revision(M, Old),
    P = damage_invoice_model:plan(M#{<<"id">> => Id}, Old),
    C = fetch(customers, maps:get(customer_id, P), D),
    require(not maps:get(enabled, P) orelse maps:get(enabled, C), <<"Enable and complete the customer first">>),
    {{ok, P}, root_audit(put(plans, Id, P, D), A, <<"plan_saved">>, Id)};
command({generate, Id, M}, A, _, D, S) ->
    damage_invoice_model:json_keys(M, [period_start]),
    Start = damage_invoice_model:get(period_start, M, <<>>),
    _ = damage_invoice_model:date(Start),
    {I, D1} = generate(Id, Start, A, D, S),
    {{ok, I}, D1};
command({edit_invoice, Id, M}, A, _, D, _) ->
    I = fetch(invoices, Id, D),
    damage_invoice_model:revision(M, I),
    I1 = audit_invoice(damage_invoice_model:edit_draft(I, M), A, <<"draft_edited">>, <<>>),
    {{ok, I1}, put(invoices, Id, I1, D)};
command({action, Id, <<"issue">>, M}, A, _, D, S) ->
    damage_invoice_model:json_keys(M, [revision]),
    I = fetch(invoices, Id, D),
    damage_invoice_model:revision(M, I),
    {I1, D1} = issue(I, A, D, S),
    {{ok, I1}, D1};
command({action, Id, <<"send">>, M}, A, _, D, _) ->
    damage_invoice_model:json_keys(M, [revision, confirm_resend]),
    I = fetch(invoices, Id, D),
    Delivery = maps:get(delivery, I),
    DS = maps:get(status, Delivery),
    require(maps:get(status, I) =:= <<"issued">>, <<"Issue the invoice before sending it">>),
    case lists:member(DS, [<<"queued">>, <<"sending">>]) of
        true -> {{ok, I}, D};
        false ->
            damage_invoice_model:revision(M, I),
            require(not lists:member(DS, [<<"sent">>, <<"unknown">>]) orelse
                    damage_invoice_model:get(confirm_resend, M, false) =:= true,
                    <<"This may duplicate an email; confirm after checking relay history">>),
            Generation = maps:get(generation, Delivery, 0) + 1,
            I1 = audit_invoice(I#{delivery => #{status => <<"queued">>, generation => Generation}},
                               A, <<"email_queued">>, <<>>),
            {{ok, I1}, put(invoices, Id, I1, D)}
    end;
command({action, Id, Action, M}, A, _, D, S) when Action =:= <<"paid">>; Action =:= <<"void">> ->
    Allowed = case Action of
        <<"paid">> -> [revision, note, paid_on, payment_reference, mint_settlement_nft, settlement_recipient];
        <<"void">> -> [revision, note]
    end,
    damage_invoice_model:json_keys(M, Allowed),
    I = fetch(invoices, Id, D),
    damage_invoice_model:revision(M, I),
    require(not busy_id(Id, S), <<"An operation is in flight for this invoice">>),
    Status = maps:get(status, I),
    I0 = case Action of
        <<"paid">> ->
            require(Status =:= <<"issued">>, <<"Only an issued invoice can be marked paid">>),
            PaidOn = damage_invoice_model:get(paid_on, M, <<>>),
            _ = damage_invoice_model:date(PaidOn),
            require(PaidOn =< today(S), <<"Payment date cannot be in the future">>),
            Reference = damage_invoice_model:text(damage_invoice_model:get(payment_reference, M, <<>>), 1, 200),
            Paid = I#{status => <<"paid">>, paid_on => PaidOn, payment_reference => Reference},
            case damage_invoice_model:get(mint_settlement_nft, M, false) of
                false -> Paid;
                true -> queue_settlement_reward(Paid, M, D);
                _ -> throw({validation, <<"mint_settlement_nft must be boolean">>})
            end;
        <<"void">> ->
            require(lists:member(Status, [<<"draft">>, <<"issue_failed">>, <<"issued">>]),
                    <<"Cannot void this invoice; paid invoices need a separate adjustment">>),
            I#{status => <<"void">>}
    end,
    Note = damage_invoice_model:text(damage_invoice_model:get(note, M, <<>>), 1, 1000),
    Delivery0 = maps:get(delivery, I0),
    Delivery = case maps:get(status, Delivery0) of
        <<"queued">> -> Delivery0#{status => <<"cancelled">>}; _ -> Delivery0
    end,
    I1 = audit_invoice(I0#{delivery => Delivery}, A, Action, Note),
    {{ok, I1}, put(invoices, Id, I1, D)};
command({action, Id, <<"settlement_nft">>, M}, A, _, D, S) ->
    damage_invoice_model:json_keys(M, [revision, settlement_recipient]),
    I = fetch(invoices, Id, D),
    damage_invoice_model:revision(M, I),
    require(maps:get(status, I) =:= <<"paid">>, <<"Settlement rewards require a paid invoice">>),
    require(not busy_id(Id, S), <<"An operation is in flight for this invoice">>),
    Settlement0 = maps:get(settlement_nft, I, #{status => <<"not_requested">>}),
    SettlementStatus = maps:get(status, Settlement0, <<"not_requested">>),
    require(not lists:member(SettlementStatus, [<<"queued">>, <<"minting">>, <<"minted">>]),
            <<"Settlement reward is already queued, minting or minted">>),
    I0 = case SettlementStatus of
        <<"unknown">> -> retry_unknown_settlement_reward(I, M);
        _ -> queue_settlement_reward(I, M, D)
    end,
    I1 = audit_invoice(I0, A, <<"settlement_reward_queued">>, <<>>),
    {{ok, I1}, put(invoices, Id, I1, D)};
command(list_admins, _, node_admin, D, _) ->
    Configured = configured_admins(),
    Accounts = lists:usort(Configured ++ maps:get(admins, D)),
    {{ok, #{items => [#{account => A, source => case lists:member(A, Configured) of
                 true -> <<"config">>; false -> <<"managed">> end} || A <- Accounts],
            audit => maps:get(audit, D)}}, D};
command({set_admin, M}, A, node_admin, D, _) ->
    damage_invoice_model:json_keys(M, [account, enabled]),
    Account = damage_invoice_model:text(damage_invoice_model:get(account, M, <<>>), 4, 100),
    require(re:run(Account, <<"^ak_[1-9A-HJ-NP-Za-km-z]+$">>, [{capture, none}]) =:= match,
            <<"Expected an Aeternity account address">>),
    require(Account =/= to_bin(application:get_env(damage, l402_account, undefined)),
            <<"Shared L402 identities cannot administer invoices">>),
    Enabled = damage_invoice_model:get(enabled, M, false),
    require(is_boolean(Enabled), <<"enabled must be boolean">>),
    require(Enabled orelse not lists:member(Account, configured_admins()),
            <<"This grant is managed in invoice_admins configuration">>),
    Admins = case Enabled of true -> lists:usort([Account | maps:get(admins, D)]);
                            false -> lists:delete(Account, maps:get(admins, D)) end,
    D1 = root_audit(D#{admins => Admins}, A, case Enabled of true -> <<"admin_granted">>;
                                                         false -> <<"admin_revoked">> end, Account),
    {{ok, #{account => Account, enabled => Enabled}}, D1};
command(list_admins, _, _, _, _) -> throw(forbidden);
command({set_admin, _}, _, _, _, _) -> throw(forbidden);
command(_, _, _, _, _) -> throw({validation, <<"Unknown billing operation">>}).

issue(#{status := <<"issue_failed">>} = I, A, D, _) ->
    I1 = audit_invoice(I#{status => <<"issuing">>}, A, <<"issue_retried">>, <<>>),
    {I1, put(invoices, maps:get(id, I), I1, D)};
issue(I, A, D, S) ->
    require(maps:get(status, I) =:= <<"draft">>, <<"Invoice has already been issued">>),
    B = maps:get(backend, S),
    %% The current billing profile is snapshotted into the issued invoice.
    %% Later configuration edits never rewrite an already-issued document.
    Seller = B:seller(I#{billing_settings => effective_settings(D)}),
    Seq = maps:get(sequence, D) + 1,
    Prefix = to_bin(cfg(number_prefix, <<"DBDD-ENT">>)),
    require(re:run(Prefix, <<"^[A-Z0-9-]{1,32}$">>, [{capture, none}]) =:= match,
            <<"Invalid invoice number prefix configuration">>),
    Number = iolist_to_binary(io_lib:format("~s-~6..0B", [Prefix, Seq])),
    I1 = audit_invoice(damage_invoice_model:issue(I, Seller, Number, today(S)),
                       A, <<"issue_requested">>, <<>>),
    {I1, put(invoices, maps:get(id, I), I1, D#{sequence => Seq})}.

generate(Id, Start, A, D, S) ->
    Existing = [I || I <- maps:values(maps:get(invoices, D)), maps:get(plan_id, I) =:= Id,
                    maps:get(period_start, I) =:= Start],
    case Existing of
        [I | _] -> {I, D};
        [] ->
            P = fetch(plans, Id, D),
            C = fetch(customers, maps:get(customer_id, P), D),
            require(maps:get(enabled, C), <<"Customer is paused or incomplete">>),
            I = audit_invoice(damage_invoice_model:draft(P, C, Start, now_s()), A, <<"draft_created">>, <<>>),
            P1 = P#{next_date => damage_invoice_model:next_date(P, Start),
                    generated_count => maps:get(generated_count, P) + 1,
                    revision => maps:get(revision, P) + 1},
            _ = S,
            {I, put(invoices, maps:get(id, I), I, put(plans, Id, P1, D))}
    end.

scheduled(D, S) ->
    try
        B = maps:get(backend, S),
        {Today, Hour} = B:billing_clock(),
        case Hour >= cfg(send_hour, 9) of
            false -> D;
            true ->
                Due = lists:sort(fun(P1, P2) -> maps:get(next_date, P1) =< maps:get(next_date, P2) end,
                    [P || P <- maps:values(maps:get(plans, D)), maps:get(enabled, P),
                          maps:get(next_date, P) =/= null, maps:get(next_date, P) =< Today]),
                lists:foldl(fun(P, Acc) -> scheduled_plan(P, Today, Acc, S) end,
                    D, lists:sublist(Due, cfg(max_periods_per_tick, 20)))
        end
    catch _:_ -> ?LOG_WARNING("Enterprise billing calendar check deferred"), D end.
scheduled_plan(P, Today, D, S) ->
    try generate(maps:get(id, P), maps:get(next_date, P), <<"scheduler">>, D, S) of
        {I, D1} ->
            Auto = cfg(auto_send, false) =:= true andalso maps:get(auto_send, P) andalso
                   maps:get(period_start, I) =:= Today,
            case Auto of
                false -> D1;
                true ->
                    try issue(I, <<"scheduler">>, D1, S) of
                        {Issued, D2} ->
                            I1 = Issued#{send_after_issue => true},
                            put(invoices, maps:get(id, I1), I1, D2)
                    catch _:_ -> D1 end
            end
    catch _:_ -> D end.

start_job(#{busy := Busy} = S) when Busy =/= none -> S;
start_job(#{data := undefined} = S) -> S;
start_job(#{data := D, backend := B} = S) ->
    case cfg(enabled, false) =:= true andalso safe_ready(B) of
        false -> S;
        true ->
            All = lists:sort(fun(I, J) -> maps:get(created_at, I) =< maps:get(created_at, J) end,
                             maps:values(maps:get(invoices, D))),
            Render = [{render, I} || I <- All, maps:get(status, I) =:= <<"issuing">>],
            Emails = [{email, I} || I <- All, maps:get(status, I) =:= <<"issued">>,
                          maps:get(status, maps:get(delivery, I)) =:= <<"queued">>, email_allowed(I, D)],
            Settlements = [{settlement_nft, I} || I <- All, maps:get(status, I) =:= <<"paid">>,
                          maps:get(status, maps:get(settlement_nft, I, #{status => <<"not_requested">>})) =:= <<"queued">>,
                          settlement_allowed(maps:get(settlement_nft, I, #{}))],
            case Render ++ Emails ++ Settlements of
                [] -> S;
                [{Kind, I} | _] ->
                    Owner = self(), Ref = make_ref(),
                    {Pid, Mon} = spawn_opt(fun() ->
                        Result = try work(Kind, I, B, Owner, Ref) catch _:_ -> {error, worker_failed} end,
                        Owner ! {invoice_job, Ref, Result}
                    end, [link, monitor]),
                    Timer = erlang:send_after(cfg(job_timeout_ms, 120000), self(), {invoice_job_timeout, Ref}),
                    S#{busy => #{id => maps:get(id, I), kind => Kind, ref => Ref,
                                  pid => Pid, monitor => Mon, timer => Timer}}
            end
    end.
work(render, I, B, _, _) ->
    case B:render(I) of
        {ok, PDF} ->
            case B:put_pdf(maps:get(id, I), PDF) of
                ok -> {ok, hash(PDF)};
                _ -> {error, pdf_storage_failed}
            end;
        _ -> {error, pdf_generation_failed}
    end;
work(email, I, B, Owner, Ref) ->
    case B:prepare_email(I) of
        {ok, Mail} ->
            case gen_server:call(Owner, {begin_smtp, Ref}, 30000) of
                ok -> B:send(Mail);
                _ -> {error, cancelled}
            end;
        _ -> {error, email_preparation_failed}
    end;
work(settlement_nft, I, B, Owner, Ref) ->
    case gen_server:call(Owner, {begin_settlement_nft, Ref}, 30000) of
        ok -> B:settlement_nft(I);
        _ -> {error, cancelled}
    end.
finish_job(#{id := Id, kind := Kind}, Result, #{data := D} = S) when is_map(D) ->
    I = fetch(invoices, Id, D),
    Delivery = maps:get(delivery, I),
    I0 = case {Kind, Result} of
        {render, {ok, Hash}} ->
            NewDelivery = case maps:get(send_after_issue, I, false) of
                true -> #{status => <<"queued">>, generation => 1, automatic => true};
                false -> Delivery
            end,
            (maps:remove(send_after_issue, I))#{status => <<"issued">>, pdf_sha256 => Hash,
                                              delivery => NewDelivery};
        {render, _} -> I#{status => <<"issue_failed">>, last_error => <<"PDF generation/storage failed; fix configuration then retry issuance">>};
        {email, {ok, accepted}} -> I#{delivery => Delivery#{status => <<"sent">>, accepted_at => now_s()}};
        {email, {error, cancelled}} -> I#{delivery => Delivery#{status => <<"cancelled">>,
            last_error => <<"Email cancelled before SMTP by current feature, vault or automatic-send policy">>}};
        {email, _} ->
            Started = maps:get(status, Delivery) =:= <<"sending">>,
            I#{delivery => Delivery#{status => case Started of true -> <<"unknown">>; false -> <<"failed">> end,
                 last_error => case Started of
                    true -> <<"SMTP outcome uncertain. Check relay before retrying.">>;
                    false -> <<"Email preparation failed before SMTP. Check PDF and mail configuration.">> end}};
        {settlement_nft, {ok, Mint}} when is_map(Mint) ->
            Current = maps:get(settlement_nft, I, #{}),
            I#{settlement_nft => maps:merge(Current, Mint#{status => <<"minted">>, minted_at => now_s()})};
        {settlement_nft, {error, cancelled}} -> I;
        {settlement_nft, {error, settlement_outcome_unknown}} ->
            Current = maps:get(settlement_nft, I, #{}),
            I#{settlement_nft => Current#{status => <<"unknown">>,
                last_error => <<"Mint outcome is uncertain. Retry safely to reconcile the unique attestation hash.">>}};
        {settlement_nft, {error, settlement_lookup_failed}} ->
            settlement_failed(I, <<"Settlement lookup failed before submission. Check contract/node read access, then retry.">>);
        {settlement_nft, {error, settlement_mint_failed}} ->
            settlement_failed(I, <<"Settlement mint failed before a tracked submission. Check signing and contract configuration, then retry.">>);
        {settlement_nft, {error, {settlement_mint_rejected, _}}} ->
            settlement_failed(I, <<"Settlement mint was rejected on chain. Check contract administration and configuration, then retry only after correcting the cause.">>);
        {settlement_nft, _} ->
            Current = maps:get(settlement_nft, I, #{}),
            Started = maps:get(status, Current, <<"not_requested">>) =:= <<"minting">>,
            I#{settlement_nft => Current#{status => case Started of true -> <<"unknown">>; false -> <<"failed">> end,
                last_error => case Started of
                    true -> <<"Mint outcome is uncertain. Retry safely to reconcile the unique attestation hash.">>;
                    false -> <<"Settlement reward mint failed before submission. Check contract and node configuration, then retry.">>
                end}}
    end,
    Action = case {Kind, Result} of
        {render, {ok, _}} -> <<"issued">>;
        {render, _} -> <<"issue_failed">>;
        {email, {ok, accepted}} -> <<"smtp_accepted">>;
        {email, _} -> <<"email_failed_or_unknown">>;
        {settlement_nft, {ok, _}} -> <<"settlement_reward_minted">>;
        {settlement_nft, {error, cancelled}} -> <<"settlement_reward_cancelled">>;
        {settlement_nft, _} -> <<"settlement_reward_failed_or_unknown">>
    end,
    I1 = audit_invoice(I0, <<"system">>, Action, <<>>),
    {_, S1} = commit(ok, put(invoices, Id, I1, D), S), S1;
finish_job(_, _, S) -> S.
settlement_failed(I, Message) ->
    Current = maps:get(settlement_nft, I, #{}),
    I#{settlement_nft => Current#{status => <<"failed">>, last_error => Message}}.

%% Automatic outbox work also observes current opt-outs, not just the
%% flags captured when a scheduled invoice was first generated.
email_allowed(I, D) ->
    case maps:get(automatic, maps:get(delivery, I), false) of
        false -> true;
        true ->
            P = maps:get(maps:get(plan_id, I), maps:get(plans, D), #{}),
            CustomerId = maps:get(id, maps:get(customer, I)),
            C = maps:get(CustomerId, maps:get(customers, D), #{}),
            cfg(auto_send, false) =:= true andalso maps:get(enabled, P, false) andalso
                maps:get(auto_send, P, false) andalso maps:get(enabled, C, false)
    end.
stop_job(#{busy := #{pid := Pid} = Job}) -> cancel_job_timer(Job), exit(Pid, kill), ok;
stop_job(_) -> ok.
cancel_job_timer(Job) -> erlang:cancel_timer(maps:get(timer, Job)), ok.
busy_id(Id, #{busy := #{id := Id}}) -> true;
busy_id(_, _) -> false.

queue_settlement_reward(I, M, D) ->
    SnapshotCustomer = maps:get(customer, I, #{}),
    CustomerId = maps:get(id, SnapshotCustomer, <<>>),
    CurrentCustomer = maps:get(CustomerId, maps:get(customers, D, #{}), #{}),
    DefaultRecipient = maps:get(account, CurrentCustomer, maps:get(account, SnapshotCustomer, <<>>)),
    Recipient = damage_invoice_model:get(settlement_recipient, M, DefaultRecipient),
    Recipient1 = damage_invoice_model:text(Recipient, 1, 100),
    case damage_invoice_settlement_nft:prepare(I, Recipient1) of
        {ok, Settlement} -> I#{settlement_nft => Settlement};
        {error, Message} when is_binary(Message) -> throw({validation, Message});
        _ -> throw({validation, <<"Settlement reward configuration is unavailable">>})
    end.

retry_unknown_settlement_reward(I, M) ->
    Settlement = maps:get(settlement_nft, I),
    ExistingRecipient = maps:get(recipient, Settlement),
    RequestedRecipient = damage_invoice_model:get(settlement_recipient, M, ExistingRecipient),
    require(RequestedRecipient =:= ExistingRecipient,
            <<"An uncertain mint must be retried with the original recipient">>),
    require(maps:get(attestation_sha256, Settlement, <<>>) =:=
                damage_invoice_settlement_nft:attestation_hash(I),
            <<"Settlement attestation no longer matches the paid invoice">>),
    Current = damage_invoice_settlement_nft:status(),
    require(maps:get(enabled, Current, false) =:= true,
            <<"Settlement reward NFT is not enabled on this node">>),
    require(maps:get(contract_id, Current, null) =:= maps:get(contract_id, Settlement, undefined),
            <<"The settlement contract changed while mint outcome was uncertain; reconcile the original contract before retrying">>),
    require(maps:get(reward_class, Current, <<>>) =:= maps:get(reward_class, Settlement, <<>>),
            <<"The settlement reward class changed while mint outcome was uncertain; restore the original configuration before retrying">>),
    Settlement1 = maps:without([last_error, started_at, minted_at, token_id, tx_hash, reused], Settlement),
    I#{settlement_nft => Settlement1#{status => <<"queued">>}}.

settlement_allowed(Settlement) ->
    Status = damage_invoice_settlement_nft:status(),
    maps:get(enabled, Status, false) =:= true andalso
        maps:get(contract_id, Status, null) =:= maps:get(contract_id, Settlement, undefined).

effective_settings(D) ->
    maps:get(settings, D, legacy_billing_settings()).

legacy_billing_settings() ->
    S = cfg(seller, []),
    Name0 = to_bin(proplists:get_value(name, S, <<"DAMAGEBDD">>)),
    Name = case Name0 of <<>> -> <<"DAMAGEBDD">>; _ -> Name0 end,
    Legal0 = to_bin(proplists:get_value(legal_name, S, Name)),
    Legal = case Legal0 of <<>> -> Name; _ -> Legal0 end,
    Registered = proplists:get_value(gst_registered, S, false) =:= true,
    Scheme = to_bin(proplists:get_value(tax_scheme, S,
                 case Registered of true -> <<"gst">>; false -> <<"none">> end)),
    TaxName0 = to_bin(proplists:get_value(tax_name, S, <<"GST">>)),
    TaxName = case TaxName0 of <<>> -> <<"Tax">>; _ -> TaxName0 end,
    RegLabel0 = to_bin(proplists:get_value(tax_registration_label, S, <<"ABN">>)),
    RegLabel = case RegLabel0 of <<>> -> <<"Tax registration ID">>; _ -> RegLabel0 end,
    RegId = to_bin(proplists:get_value(tax_registration_id, S,
                                      proplists:get_value(abn, S, <<>>))),
    Country0 = to_bin(proplists:get_value(country_code, S, <<"AU">>)),
    Country = case Country0 of <<>> -> <<"AU">>; _ -> Country0 end,
    #{revision => 0, seller => #{
        legal_name => Legal, display_name => Name,
        email => to_bin(proplists:get_value(email, S, <<>>)),
        address => to_bin(proplists:get_value(address, S, <<>>)),
        logo_path => to_bin(proplists:get_value(logo_path, S, <<>>)),
        country_code => Country,
        tax => #{scheme => Scheme, name => TaxName, registration_label => RegLabel,
                 registration_id => RegId, registered => Registered,
                 default_rate_bps => proplists:get_value(default_tax_bps, S, 0),
                 invoice_title => to_bin(proplists:get_value(tax_invoice_title, S, <<"TAX INVOICE">>))}
    }}.

create_customer_id(M, D) ->
    case damage_invoice_model:get(id, M, <<>>) of
        <<>> -> unique_customer_id(maps:get(customers, D), 8);
        Id0 ->
            Id = damage_invoice_model:id(Id0),
            require(not maps:is_key(Id, maps:get(customers, D)), <<"Customer ID already exists">>),
            Id
    end.

unique_customer_id(_Customers, 0) ->
    throw({conflict, <<"Could not allocate a unique customer ID; retry">>});
unique_customer_id(Customers, Attempts) ->
    Hex = string:lowercase(binary:encode_hex(crypto:strong_rand_bytes(12))),
    Id = <<"cus_", Hex/binary>>,
    case maps:is_key(Id, Customers) of
        true -> unique_customer_id(Customers, Attempts - 1);
        false -> Id
    end.

billing_summary(D) ->
    Invoices = maps:values(maps:get(invoices, D)),
    NeedsAction = length([ok || I <- Invoices, needs_billing_action(I)]),
    Outstanding = [I || I <- Invoices, maps:get(status, I) =:= <<"issued">>],
    Paid = [I || I <- Invoices, maps:get(status, I) =:= <<"paid">>],
    Rewards = [I || I <- Paid, maps:get(status, maps:get(settlement_nft, I, #{status => <<"not_requested">>})) =:= <<"minted">>],
    Amounts = lists:foldl(fun(I, Acc) ->
        Currency = maps:get(currency, I),
        Acc#{Currency => maps:get(Currency, Acc, 0) + maps:get(total_minor, I)}
    end, #{}, Outstanding),
    #{needs_action => NeedsAction, outstanding_count => length(Outstanding),
      outstanding_minor => Amounts, paid_count => length(Paid),
      settlement_rewards_minted => length(Rewards)}.

needs_billing_action(I) ->
    Status = maps:get(status, I),
    DeliveryStatus = maps:get(status, maps:get(delivery, I)),
    SettlementStatus = maps:get(status, maps:get(settlement_nft, I, #{status => <<"not_requested">>})),
    lists:member(Status, [<<"draft">>, <<"issue_failed">>]) orelse
        lists:member(DeliveryStatus, [<<"failed">>, <<"unknown">>]) orelse
        lists:member(SettlementStatus, [<<"failed">>, <<"unknown">>]).

invoice_page(Q, D) ->
    Limit = query_int(<<"limit">>, Q, 50, 1, 100), Offset = query_int(<<"offset">>, Q, 0, 0, 1000000),
    Status = maps:get(<<"status">>, Q, <<>>), Customer = maps:get(<<"customer_id">>, Q, <<>>),
    Invoices = [I || I <- maps:values(maps:get(invoices, D)),
        (Status =:= <<>> orelse Status =:= maps:get(status, I)),
        (Customer =:= <<>> orelse Customer =:= maps:get(id, maps:get(customer, I)))],
    Sorted = lists:sort(fun(I, J) -> {maps:get(created_at, I), maps:get(id, I)} >
                                    {maps:get(created_at, J), maps:get(id, J)} end, Invoices),
    Page = lists:sublist(lists:nthtail(min(Offset, length(Sorted)), Sorted), Limit),
    #{items => [maps:without([items, seller, notes, audit], I) || I <- Page], total => length(Sorted),
      offset => Offset, limit => Limit}.
query_int(K, Q, Def, Min, Max) ->
    V = maps:get(K, Q, integer_to_binary(Def)),
    try binary_to_integer(V) of I when I >= Min, I =< Max -> I; _ -> throw({validation, <<"Invalid pagination">>})
    catch error:_ -> throw({validation, <<"Invalid pagination">>}) end.
sorted(Type, D) -> lists:sort(fun(A, B) -> maps:get(name, A) =< maps:get(name, B) end, maps:values(maps:get(Type, D))).
fetch(Type, Id, D) -> case maps:find(Id, maps:get(Type, D)) of {ok, V} -> V; error -> throw(not_found) end.
put(Type, Id, V, D) -> D#{Type => (maps:get(Type, D))#{Id => V}}.
update_revision(_, Old) when map_size(Old) =:= 0 -> ok;
update_revision(M, Old) -> damage_invoice_model:revision(M, Old).
root_audit(D, A, Action, Id) ->
    E = #{at => now_s(), actor => A, action => Action, target => Id},
    D#{audit => maps:get(audit, D) ++ [E]}.
audit_invoice(I, A, Action, Note) ->
    E = #{at => now_s(), actor => A, action => Action, note => Note},
    I#{audit => maps:get(audit, I) ++ [E], revision => maps:get(revision, I) + 1}.
require(true, _) -> ok;
require(false, M) -> throw({conflict, M}).
now_s() -> erlang:system_time(second).
today(#{backend := B}) -> {Today, _} = B:billing_clock(), Today.
hash(B) -> string:lowercase(binary:encode_hex(crypto:hash(sha256, B))).
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(_) -> <<>>.
