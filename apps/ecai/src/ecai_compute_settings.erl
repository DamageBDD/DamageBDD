%% Per-account cloud compute policy, guarded reservations and mint intents.
%% No provider secret or wallet private key is accepted or stored.
-module(ecai_compute_settings).
-behaviour(gen_server).
-export([
    start_link/0, start_link/1,
    snapshot/1,
    put_policy/2,
    put_provider/3,
    provider/2,
    mark_verified/3,
    quote/1,
    reserve/3,
    cancel_reservation/2,
    request_mint/5
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(st, {table}).
% USD 1m, a configuration sanity bound
-define(MAX_CENTS, 100000000).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).
snapshot(Owner) -> gen_server:call(?MODULE, {snapshot, Owner}, 30000).
put_policy(Owner, Policy) -> gen_server:call(?MODULE, {policy, Owner, Policy}, 30000).
put_provider(Owner, Provider, Config) ->
    gen_server:call(?MODULE, {provider, Owner, Provider, Config}, 30000).
provider(Owner, Provider) -> gen_server:call(?MODULE, {get_provider, Owner, Provider}, 30000).
mark_verified(Owner, Provider, Digest) ->
    gen_server:call(?MODULE, {verified, Owner, Provider, Digest}, 30000).
quote(Spec) -> quote_spec(Spec).
reserve(Owner, Key, Spec) -> gen_server:call(?MODULE, {reserve, Owner, Key, Spec}, 30000).
cancel_reservation(Owner, Id) -> gen_server:call(?MODULE, {cancel, Owner, Id}, 30000).
request_mint(Owner, JobId, Metadata, Recipient, FeeCapCents) ->
    gen_server:call(?MODULE, {mint, Owner, JobId, Metadata, Recipient, FeeCapCents}, 30000).

init(Opts) ->
    DefaultPath = filename:join(ecai_paths:index_state_dir(), "compute_settings.dets"),
    Path = ecai_paths:normalize(
        maps:get(
            path,
            Opts,
            application:get_env(ecai, compute_settings_path, DefaultPath)
        )
    ),
    ok = ecai_paths:ensure_parent(Path),
    case
        dets:open_file(ecai_compute_settings_dets, [{file, Path}, {type, set}, {auto_save, 1000}])
    of
        {ok, Table} -> {ok, #st{table = Table}};
        {error, Reason} -> {stop, {compute_settings_store_failed, Reason}}
    end.

handle_call({snapshot, Owner}, _From, State) ->
    reply({ok, account_snapshot(State#st.table, Owner)}, State);
handle_call({get_provider, Owner, Name}, _From, State) ->
    Conf = account(State#st.table, Owner),
    Providers = maps:get(<<"providers">>, Conf),
    case maps:find(Name, Providers) of
        {ok, Value} -> reply({ok, Value}, State);
        error -> reply({error, not_configured}, State)
    end;
handle_call({policy, Owner, Input}, _From, State) ->
    T = State#st.table,
    Old = account(T, Owner),
    case validate_policy(Input) of
        {ok, Budget, Mint} ->
            Spent = monthly_totals(T, Owner),
            Compute = maps:get(compute, Spent),
            MintCents = maps:get(mint, Spent),
            Limit = maps:get(<<"monthly_cents">>, Budget),
            MintLimit = maps:get(<<"mint_monthly_cents">>, Budget),
            if
                Limit < Compute ->
                    reply({error, below_reserved_compute_budget}, State);
                MintLimit < MintCents ->
                    reply({error, below_reserved_mint_budget}, State);
                true ->
                    New = Old#{<<"budget">> => Budget, <<"mint">> => Mint},
                    reply(save(T, {account, Owner}, New, {ok, New}), State)
            end;
        Error ->
            reply(Error, State)
    end;
handle_call({provider, Owner, Name, Input}, _From, State) ->
    T = State#st.table,
    Conf = account(T, Owner),
    Ps = maps:get(<<"providers">>, Conf),
    case validate_provider(Name, Input) of
        {ok, Config} ->
            %% Preserve a non-secret external id for an existing AWS connection.
            Prev = maps:get(Name, Ps, #{}),
            External =
                case Name of
                    <<"aws_batch">> ->
                        maps:get(
                            <<"external_id">>, Prev, binary:encode_hex(crypto:strong_rand_bytes(24))
                        );
                    _ ->
                        undefined
                end,
            NewProvider0 = Config#{<<"status">> => <<"unverified">>, <<"verified_at_ms">> => null},
            NewProvider =
                case External of
                    undefined -> NewProvider0;
                    _ -> NewProvider0#{<<"external_id">> => External}
                end,
            %% No credentials and no authenticated cloud access are inferred from saving.
            New = Conf#{<<"providers">> => Ps#{Name => NewProvider}},
            reply(save(T, {account, Owner}, New, {ok, NewProvider}), State);
        Error ->
            reply(Error, State)
    end;
handle_call({verified, Owner, Name, Digest}, _From, State) ->
    T = State#st.table,
    Conf = account(T, Owner),
    Ps = maps:get(<<"providers">>, Conf),
    case maps:find(Name, Ps) of
        {ok, P} ->
            case crypto:hash(sha256, term_to_binary(P)) =:= Digest of
                true ->
                    NewP = P#{
                        <<"status">> => <<"identity_verified">>,
                        <<"verified_at_ms">> => erlang:system_time(millisecond)
                    },
                    New = Conf#{<<"providers">> => Ps#{Name => NewP}},
                    reply(save(T, {account, Owner}, New, {ok, NewP}), State);
                false ->
                    reply({error, provider_changed_during_verification}, State)
            end;
        error ->
            reply({error, not_configured}, State)
    end;
handle_call({reserve, Owner, Key, Spec}, _From, State) ->
    T = State#st.table,
    case {validate_key(Key), quote_spec(Spec)} of
        {ok, {ok, Quote}} ->
            Conf = account(T, Owner),
            ProviderName = maps:get(<<"provider">>, Spec),
            Providers = maps:get(<<"providers">>, Conf),
            Provider = maps:get(ProviderName, Providers, #{}),
            Amount = maps:get(<<"reserve_cents">>, Quote),
            Budget = maps:get(<<"budget">>, Conf),
            Current = monthly_totals(T, Owner),
            Existing = dets:lookup(T, {reservation_key, Owner, Key}),
            SpecHash = crypto:hash(sha256, term_to_binary(Spec)),
            case Existing of
                [{{reservation_key, Owner, Key}, Saved}] ->
                    case maps:get(<<"spec_hash">>, Saved) =:= SpecHash of
                        true -> reply({ok, public_reservation(Saved)}, State);
                        false -> reply({error, idempotency_conflict}, State)
                    end;
                [] ->
                    case checks_for_reserve(Provider, Amount, Budget, Current) of
                        ok ->
                            Id = binary:encode_hex(crypto:strong_rand_bytes(16)),
                            Entry = #{
                                <<"id">> => Id,
                                <<"owner">> => Owner,
                                <<"key">> => Key,
                                <<"spec">> => Spec,
                                <<"spec_hash">> => SpecHash,
                                <<"quote">> => Quote,
                                <<"month">> => month_utc(),
                                <<"state">> => <<"awaiting_dispatch">>,
                                <<"reserved_cents">> => Amount,
                                <<"created_at_ms">> => erlang:system_time(millisecond)
                            },
                            reply(
                                save(
                                    T,
                                    {reservation_key, Owner, Key},
                                    Entry,
                                    {ok, public_reservation(Entry)}
                                ),
                                State
                            );
                        Error ->
                            reply({error, Error}, State)
                    end
            end;
        {Err, _} when Err =/= ok -> reply({error, Err}, State);
        {_, Error} ->
            reply(Error, State)
    end;
handle_call({cancel, Owner, Id}, _From, State) ->
    T = State#st.table,
    Matches = dets:foldl(
        fun
            ({{reservation_key, O, _Key}, E}, Acc) when O =:= Owner ->
                case maps:get(<<"id">>, E) =:= Id of
                    true -> [E | Acc];
                    false -> Acc
                end;
            (_, Acc) ->
                Acc
        end,
        [],
        T
    ),
    case Matches of
        [E] ->
            case maps:get(<<"state">>, E) of
                <<"awaiting_dispatch">> ->
                    New = E#{<<"state">> => <<"canceled">>, <<"reserved_cents">> => 0},
                    K = maps:get(<<"key">>, E),
                    reply(
                        save(
                            T,
                            {reservation_key, Owner, K},
                            New,
                            {ok, public_reservation(New)}
                        ),
                        State
                    );
                _ ->
                    reply({error, reservation_not_cancelable}, State)
            end;
        _ ->
            reply({error, reservation_not_found}, State)
    end;
handle_call({mint, Owner, JobId, Metadata, Recipient, FeeCap}, _From, State) ->
    T = State#st.table,
    Conf = account(T, Owner),
    Budget = maps:get(<<"budget">>, Conf),
    Mint = maps:get(<<"mint">>, Conf),
    Current = monthly_totals(T, Owner),
    Sha = maps:get(<<"manifest_sha256">>, Metadata, undefined),
    Key = {mint, Owner, JobId},
    case dets:lookup(T, Key) of
        [{Key, E}] ->
            case
                maps:get(<<"manifest_sha256">>, E) =:= Sha andalso
                    maps:get(<<"recipient">>, E) =:= Recipient andalso
                    maps:get(<<"fee_cap_cents">>, E) =:= FeeCap
            of
                true -> reply({ok, E}, State);
                false -> reply({error, mint_request_conflict}, State)
            end;
        [] ->
            case mint_check(Mint, Sha, Recipient, FeeCap, Budget, Current) of
                ok ->
                    Entry = #{
                        <<"job_id">> => JobId,
                        <<"owner">> => Owner,
                        <<"status">> => <<"awaiting_wallet_signature">>,
                        <<"chain">> => <<"aeternity">>,
                        <<"recipient">> => Recipient,
                        <<"manifest_sha256">> => Sha,
                        <<"metadata">> => Metadata,
                        <<"fee_cap_cents">> => FeeCap,
                        <<"month">> => month_utc(),
                        <<"created_at_ms">> => erlang:system_time(millisecond)
                    },
                    reply(save(T, Key, Entry, {ok, Entry}), State);
                Error ->
                    reply({error, Error}, State)
            end
    end;
handle_call(_Message, _From, State) ->
    reply({error, bad_request}, State).

handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, #st{table = T}) -> dets:close(T).
code_change(_, State, _) -> {ok, State}.
reply(Result, State) -> {reply, Result, State}.

save(T, Key, Value, Response) ->
    case dets:insert(T, {Key, Value}) of
        ok ->
            case dets:sync(T) of
                ok -> Response;
                Error -> {error, {sync_failed, Error}}
            end;
        Error ->
            {error, {write_failed, Error}}
    end.

account(T, Owner) ->
    case dets:lookup(T, {account, Owner}) of
        [{{account, Owner}, Value}] -> Value;
        _ -> default_account()
    end.
default_account() ->
    #{
        <<"providers">> => #{},
        <<"budget">> => #{
            <<"remote_enabled">> => false,
            <<"monthly_cents">> => 0,
            <<"per_job_cents">> => 0,
            <<"mint_monthly_cents">> => 0
        },
        <<"mint">> => #{
            <<"enabled">> => false,
            <<"recipient">> => <<>>,
            <<"chain">> => <<"aeternity">>
        }
    }.
account_snapshot(T, Owner) -> account_snapshot(T, Owner, account(T, Owner)).
account_snapshot(T, Owner, Account) ->
    Totals = monthly_totals(T, Owner),
    Reservations = dets:foldl(
        fun
            ({{reservation_key, O, _}, E}, Acc) when O =:= Owner ->
                [public_reservation(E) | Acc];
            (_, Acc) ->
                Acc
        end,
        [],
        T
    ),
    Mints = dets:foldl(
        fun
            ({{mint, O, _}, E}, Acc) when O =:= Owner -> [E | Acc];
            (_, Acc) -> Acc
        end,
        [],
        T
    ),
    Account#{
        <<"period_utc">> => month_utc(),
        <<"reserved_compute_cents">> => maps:get(compute, Totals),
        <<"reserved_mint_cents">> => maps:get(mint, Totals),
        <<"reservations">> => lists:sublist(
            lists:reverse(lists:sort(fun newer/2, Reservations)), 30
        ),
        <<"mint_requests">> => lists:sublist(lists:reverse(lists:sort(fun newer/2, Mints)), 30),
        <<"actual_billed_cents">> => null,
        <<"execution_integration">> => <<"pending">>,
        <<"mint_submission_integration">> => <<"pending">>
    }.
newer(A, B) -> maps:get(<<"created_at_ms">>, A, 0) < maps:get(<<"created_at_ms">>, B, 0).
public_reservation(E) -> maps:without([<<"spec_hash">>, <<"owner">>, <<"key">>], E).
month_utc() ->
    {{Year, Month, _Day}, _} = calendar:universal_time(),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B", [Year, Month])).
monthly_totals(T, Owner) ->
    Period = month_utc(),
    dets:foldl(
        fun
            ({{reservation_key, O, _}, E}, Acc) when O =:= Owner ->
                case maps:get(<<"month">>, E) =:= Period of
                    true ->
                        Acc#{
                            compute := maps:get(compute, Acc) + maps:get(<<"reserved_cents">>, E, 0)
                        };
                    false ->
                        Acc
                end;
            ({{mint, O, _}, E}, Acc) when O =:= Owner ->
                case maps:get(<<"month">>, E) =:= Period of
                    true -> Acc#{mint := maps:get(mint, Acc) + maps:get(<<"fee_cap_cents">>, E, 0)};
                    false -> Acc
                end;
            (_, Acc) ->
                Acc
        end,
        #{compute => 0, mint => 0},
        T
    ).

validate_key(B) when is_binary(B), byte_size(B) >= 8, byte_size(B) =< 128 -> ok;
validate_key(_) -> invalid_idempotency_key.
valid_cents(N) -> is_integer(N) andalso N >= 0 andalso N =< ?MAX_CENTS.
validate_policy(#{<<"budget">> := Budget, <<"mint">> := Mint} = Input) when
    is_map(Budget), is_map(Mint)
->
    BK = [<<"monthly_cents">>, <<"per_job_cents">>, <<"mint_monthly_cents">>],
    MK = [<<"enabled">>, <<"recipient">>, <<"chain">>],
    case
        allowed_keys(Input, [<<"budget">>, <<"mint">>]) andalso
            allowed_keys(Budget, [<<"remote_enabled">> | BK]) andalso allowed_keys(Mint, MK) andalso
            is_boolean(maps:get(<<"remote_enabled">>, Budget, undefined)) andalso
            lists:all(fun(K) -> valid_cents(maps:get(K, Budget, -1)) end, BK) andalso
            is_boolean(maps:get(<<"enabled">>, Mint, undefined)) andalso
            maps:get(<<"chain">>, Mint, null) =:= <<"aeternity">> andalso
            valid_recipient(
                maps:get(<<"recipient">>, Mint, <<>>),
                maps:get(<<"enabled">>, Mint, false) =:= false
            )
    of
        true -> {ok, Budget, Mint};
        false -> {error, invalid_policy}
    end;
validate_policy(_) ->
    {error, invalid_policy}.
valid_recipient(<<>>, true) -> true;
valid_recipient(<<"ak_", Rest/binary>>, _) -> byte_size(Rest) >= 20 andalso byte_size(Rest) =< 100;
valid_recipient(_, _) -> false.
allowed_keys(Map, Allowed) ->
    lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(Map)).

validate_provider(<<"aws_batch">>, Input) when is_map(Input) ->
    Fields = [<<"role_arn">>, <<"region">>, <<"job_queue">>, <<"job_definition">>, <<"bucket">>],
    Arn = maps:get(<<"role_arn">>, Input, <<>>),
    case
        allowed_keys(Input, Fields) andalso
            text_ok(Arn, <<"^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$">>) andalso
            lengths(Input, Fields) andalso
            text_ok(maps:get(<<"region">>, Input, <<>>), <<"^[a-z0-9-]+$">>) andalso
            lists:all(
                fun(K) -> text_ok(maps:get(K, Input, <<>>), <<"^[A-Za-z0-9._/-]+$">>) end,
                [<<"job_queue">>, <<"job_definition">>]
            ) andalso
            text_ok(maps:get(<<"bucket">>, Input, <<>>), <<"^[a-z0-9.-]+$">>)
    of
        true -> {ok, Input};
        false -> {error, invalid_aws_connection}
    end;
validate_provider(<<"cloud_run">>, Input) when is_map(Input) ->
    Fields = [<<"project_id">>, <<"region">>, <<"job">>, <<"bucket">>, <<"service_account">>],
    case
        allowed_keys(Input, Fields) andalso lengths(Input, Fields) andalso
            lists:all(
                fun(K) -> text_ok(maps:get(K, Input, <<>>), <<"^[a-z0-9-]+$">>) end,
                [<<"project_id">>, <<"region">>, <<"job">>]
            ) andalso
            text_ok(maps:get(<<"bucket">>, Input, <<>>), <<"^[a-z0-9._-]+$">>) andalso
            text_ok(maps:get(<<"service_account">>, Input, <<>>), <<"^[a-z0-9._@-]+$">>)
    of
        true -> {ok, Input};
        false -> {error, invalid_cloud_run_connection}
    end;
validate_provider(_, _) ->
    {error, unsupported_provider}.
lengths(Map, Fields) ->
    lists:all(
        fun(K) ->
            V = maps:get(K, Map, null),
            is_binary(V) andalso byte_size(V) >= 2 andalso byte_size(V) =< 240
        end,
        Fields
    ).
text_ok(B, Re) when is_binary(B) ->
    case re:run(B, Re, [{capture, none}]) of
        match -> true;
        _ -> false
    end;
text_ok(_, _) ->
    false.

quote_spec(Spec) when is_map(Spec) ->
    P = maps:get(<<"provider">>, Spec, null),
    Cpu = maps:get(<<"vcpus">>, Spec, 0),
    Mem = maps:get(<<"memory_mb">>, Spec, 0),
    Time = maps:get(<<"max_seconds">>, Spec, 0),
    Attempts = maps:get(<<"max_attempts">>, Spec, 0),
    Keys = [
        <<"provider">>,
        <<"vcpus">>,
        <<"memory_mb">>,
        <<"max_seconds">>,
        <<"max_attempts">>,
        <<"source_job_id">>
    ],
    if
        not is_integer(Cpu); not is_integer(Mem); not is_integer(Time); not is_integer(Attempts) ->
            {error, invalid_resources};
        Cpu < 1;
        Cpu > 16;
        Mem < 512;
        Mem > 65536;
        Time < 30;
        Time > 86400;
        Attempts < 1;
        Attempts > 3 ->
            {error, resource_limit_exceeded};
        P =:= <<"cloud_run">>, Cpu > 8 ->
            {error, cloud_run_cpu_limit_exceeded};
        P =:= <<"cloud_run">>, Mem > 32768 ->
            {error, cloud_run_memory_limit_exceeded};
        true ->
            case
                allowed_keys(Spec, Keys) andalso
                    (P =:= <<"aws_batch">> orelse P =:= <<"cloud_run">>) andalso
                    is_binary(maps:get(<<"source_job_id">>, Spec, null))
            of
                false -> {error, invalid_quote_request};
                true -> compute_quote(P, Cpu, Mem, Time, Attempts)
            end
    end;
quote_spec(_) ->
    {error, invalid_quote_request}.
compute_quote(Provider, Cpu, Mem, Seconds, Attempts) ->
    Rates = application:get_env(ecai, compute_price_upper_bounds, #{}),
    case maps:find(Provider, Rates) of
        {ok,
            #{
                vcpu_micro_usd_sec := Vcpu,
                gib_micro_usd_sec := Ram,
                fixed_micro_usd := Fixed
            } = Rate} when
            is_integer(Vcpu),
            Vcpu >= 0,
            is_integer(Ram),
            Ram >= 0,
            is_integer(Fixed),
            Fixed >= 0
        ->
            Safety = maps:get(safety_basis_points, Rate, 20000),
            case is_integer(Safety) andalso Safety >= 10000 andalso Safety =< 50000 of
                true ->
                    Micro = ((Cpu * Vcpu * 1024 + Mem * Ram) * Seconds + 1023) div 1024,
                    MaxMicro = (Micro + Fixed) * Attempts * Safety,
                    Cents = max(1, (MaxMicro + 99999999) div 100000000),
                    {ok, #{
                        <<"provider">> => Provider,
                        <<"reserve_cents">> => Cents,
                        <<"currency">> => <<"USD">>,
                        <<"pricing">> => <<"operator_ceiling">>,
                        <<"includes_cloud_invoice">> => false
                    }};
                false ->
                    {error, invalid_operator_pricing}
            end;
        _ ->
            {error, operator_price_ceiling_missing}
    end.
checks_for_reserve(P, Amount, Budget, Current) ->
    Monthly = maps:get(<<"monthly_cents">>, Budget),
    Job = maps:get(<<"per_job_cents">>, Budget),
    Status = maps:get(<<"status">>, P, <<>>),
    Used = maps:get(compute, Current),
    Enabled = maps:get(<<"remote_enabled">>, Budget, false),
    if
        Enabled =/= true -> remote_indexing_disabled;
        Status =/= <<"identity_verified">> -> provider_not_verified;
        Amount > Job -> per_job_budget_exceeded;
        Used + Amount > Monthly -> monthly_budget_exceeded;
        true -> ok
    end.
mint_check(Mint, Sha, Recipient, Fee, Budget, Current) ->
    Enabled = maps:get(<<"enabled">>, Mint),
    ExpectedRecipient = maps:get(<<"recipient">>, Mint),
    Used = maps:get(mint, Current),
    Limit = maps:get(<<"mint_monthly_cents">>, Budget),
    case is_binary(Sha) andalso byte_size(Sha) >= 32 of
        false ->
            artifact_not_ready;
        true ->
            if
                Enabled =/= true -> mint_not_enabled;
                not is_integer(Fee) -> invalid_fee_cap;
                Fee < 1; Fee > ?MAX_CENTS -> invalid_fee_cap;
                ExpectedRecipient =/= Recipient -> recipient_mismatch;
                Used + Fee > Limit -> mint_budget_exceeded;
                true -> ok
            end
    end.
