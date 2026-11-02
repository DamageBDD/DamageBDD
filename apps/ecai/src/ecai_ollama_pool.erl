-module(ecai_ollama_pool).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    status/0,
    inference_receipt/1,
    approve_inference_retry/3,
    evaluation_configurations/0,
    refresh/0,
    reconfigure/4,
    validate_nodes/1,
    inherited_nodes/0,
    chat_messages/3,
    capacity/1,
    inference_available/4,
    generate_json/2,
    generate_json/3,
    generate_text/2,
    generate_text/3,
    native_chat/2,
    native_chat/3,
    native_generate/2,
    native_generate/3
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-ifdef(TEST).
-export([output_options/1, inference_request_id/5]).
-endif.

-define(SERVER, ?MODULE).
-define(DEFAULT_HEALTH_INTERVAL_MS, 30000).
-define(DEFAULT_HEALTH_TIMEOUT_MS, 5000).
-define(DEFAULT_FAILURE_THRESHOLD, 2).
-define(DEFAULT_QUEUE_TIMEOUT_MS, 300000).
-define(DEFAULT_CLUSTER_ATTEMPTS, 3).
-define(RECEIPT_TABLE, ecai_inference_receipts_dets).
-define(RECEIPT_FILE, "inference_receipts.dets").
-define(ROLES, [learning, synthesis, audit, patch, chat, bdd]).

-record(state, {
    nodes = #{},
    leases = #{},
    seq = 0,
    health_interval_ms = ?DEFAULT_HEALTH_INTERVAL_MS,
    health_timeout_ms = ?DEFAULT_HEALTH_TIMEOUT_MS,
    failure_threshold = ?DEFAULT_FAILURE_THRESHOLD,
    last_probe_at = undefined,
    receipt_tab = undefined,
    receipt_file = undefined,
    probe_timer = undefined,
    config_revision = 0,
    receipt_counts = #{},
    lease_started = #{},
    probes = #{}
}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

%% Pure configuration resolution shared with the pinned evaluation adapter.
%% This internal API returns credential REFERENCES; it is not exposed over HTTP.
evaluation_configurations() ->
    normalize_nodes(configured_nodes(#{})).

%% Trusted BEAM-only transaction: validation and disk commit precede activation.
%% Active leases retain their endpoint/options; stale probes cannot mark a new
%% configuration healthy. No arbitrary function is accepted by the HTTP layer.
reconfigure(Nodes, Runtime, Revision, Commit) when is_function(Commit, 0) ->
    gen_server:call(?SERVER, {reconfigure, Nodes, Runtime, Revision, Commit}, infinity).
validate_nodes(Nodes) -> normalize_nodes(Nodes).
inherited_nodes() -> legacy_configured_nodes(#{}).
chat_messages(Role, Messages, Opts) when is_list(Messages), is_map(Opts) ->
    run_native_request(messages, Role, #{messages => Messages}, Opts).

status() -> gen_server:call(?SERVER, status).

%% Trusted BEAM/operator API only. No HTTP route exposes these operations.
%% Reading never releases a receipt. Approval enables one subsequent claim,
%% and explicitly accepts that a previous remote execution may have completed.
-spec inference_receipt(binary()) -> {ok, map()} | {error, term()}.
inference_receipt(RequestId) ->
    gen_server:call(?SERVER, {inference_receipt, RequestId}, 30000).

-spec approve_inference_retry(binary(), pos_integer(), atom()) ->
    {ok, map()} | {error, term()}.
approve_inference_retry(RequestId, ExpectedAttempt, Acknowledgement) ->
    gen_server:call(?SERVER,
        {approve_inference_retry, RequestId, ExpectedAttempt, Acknowledgement}, 30000).
refresh() -> gen_server:cast(?SERVER, refresh).
capacity(Role) when is_atom(Role) -> gen_server:call(?SERVER, {capacity, Role}).
inference_available(Role, Provider, Model, Digest) ->
    gen_server:call(?SERVER, {inference_available, Role, Provider, Model, Digest}).

generate_json(Role, Prompt) -> generate_json(Role, Prompt, #{}).
generate_json(Role, Prompt, Opts) -> run_request(json, Role, Prompt, Opts).

generate_text(Role, Prompt) -> generate_text(Role, Prompt, #{}).
generate_text(Role, Prompt, Opts) -> run_request(text, Role, Prompt, Opts).

native_chat(Role, Request) -> native_chat(Role, Request, #{}).
native_chat(Role, Request, Opts) when is_map(Request), is_map(Opts) ->
    run_native_request(native_chat, Role, Request, Opts).

native_generate(Role, Request) -> native_generate(Role, Request, #{}).
native_generate(Role, Request, Opts) when is_map(Request), is_map(Opts) ->
    run_native_request(native_generate, Role, Request, Opts).

init(Opts) ->
    case normalize_nodes(configured_nodes(Opts)) of
        {error, Reason} ->
            {stop, Reason};
        {ok, Nodes} ->
            case open_receipt_store(Opts) of
                {error, ReceiptReason} ->
                    {stop, {cannot_open_inference_receipts, ReceiptReason}};
                {ok, ReceiptTab, ReceiptFile} ->
                    State = #state{
                        nodes = Nodes,
                        health_interval_ms = opt(
                            health_interval_ms,
                            Opts,
                            application:get_env(
                                ecai,
                                code_model_health_interval_ms,
                                application:get_env(
                                    ecai,
                                    code_ollama_health_interval_ms,
                                    ?DEFAULT_HEALTH_INTERVAL_MS
                                )
                            )
                        ),
                        health_timeout_ms = opt(
                            health_timeout_ms,
                            Opts,
                            application:get_env(
                                ecai,
                                code_model_health_timeout_ms,
                                application:get_env(
                                    ecai,
                                    code_ollama_health_timeout_ms,
                                    ?DEFAULT_HEALTH_TIMEOUT_MS
                                )
                            )
                        ),
                        failure_threshold = opt(
                            failure_threshold,
                            Opts,
                            application:get_env(
                                ecai,
                                code_model_failure_threshold,
                                application:get_env(
                                    ecai,
                                    code_ollama_failure_threshold,
                                    ?DEFAULT_FAILURE_THRESHOLD
                                )
                            )
                        ),
                        receipt_tab = ReceiptTab,
                        receipt_counts = load_receipt_counts(ReceiptTab),
                        config_revision = ecai_llm_settings:revision(),
                        receipt_file = ReceiptFile
                    },
                    self() ! probe_all,
                    {ok, State}
            end
    end.

handle_call({reconfigure, RawNodes, Runtime, Revision, Commit}, _From, State) ->
    case normalize_nodes(RawNodes) of
        {error, _} = Error -> {reply, Error, State};
        {ok, Candidate} ->
            case Commit() of
                ok ->
                    Nodes = maps:map(fun(Id, N) ->
                        Active = length([ok || {LeaseId, _, _} <- maps:values(State#state.leases),
                                               LeaseId =:= Id]),
                        N#{inflight => Active}
                    end, Candidate),
                    maps:foreach(fun(_, P) -> stop_probe(P) end, State#state.probes),
                    New = State#state{nodes = Nodes, config_revision = Revision, probes = #{},
                        health_interval_ms = maps:get(<<"health_interval_ms">>, Runtime),
                        health_timeout_ms = maps:get(<<"health_timeout_ms">>, Runtime),
                        failure_threshold = maps:get(<<"failure_threshold">>, Runtime)},
                    self() ! probe_all,
                    {reply, ok, New};
                {error, _} = Error -> {reply, Error, State}
            end
    end;
handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call({capacity, Role}, _From, State) ->
    {reply, role_capacity(Role, State#state.nodes), State};
handle_call({inference_available, Role, Provider0, Model0, Digest0}, _From, State) ->
    Provider = normalize_requested_provider(Provider0),
    Model = optional_binary(Model0),
    Digest = optional_binary(Digest0),
    Reply = lists:any(
        fun(Node) -> inference_matches(Node, Role, Provider, Model, Digest) end,
        maps:values(State#state.nodes)
    ),
    {reply, Reply, State};
handle_call({checkout, Role, Provider, Model, Exclude}, {Owner, _}, State0) ->
    case select_node(Role, Provider, Model, Exclude, State0) of
        {error, _} = Error ->
            {reply, Error, State0};
        {ok, Node0} ->
            Seq = State0#state.seq + 1,
            Id = maps:get(id, Node0),
            LeaseRef = make_ref(),
            Node = Node0#{
                inflight => maps:get(inflight, Node0, 0) + 1,
                selections => maps:get(selections, Node0, 0) + 1,
                last_selected => Seq
            },
            Nodes = (State0#state.nodes)#{Id => Node},
            Lease = lease_map(LeaseRef, Role, Model, Node),
            Monitor = erlang:monitor(process, Owner),
            Leases = (State0#state.leases)#{LeaseRef => {Id, maps:get(config_token, Node), Monitor}},
            Started = (State0#state.lease_started)#{LeaseRef => erlang:monotonic_time(millisecond)},
            {reply, {ok, Lease}, State0#state{nodes = Nodes, leases = Leases,
                                             lease_started = Started, seq = Seq}}
    end;
handle_call({inference_receipt, RequestId}, _From, State) ->
    {reply, inspect_inference_receipt(RequestId, State), State};
handle_call({approve_inference_retry, RequestId, ExpectedAttempt, Acknowledgement},
            {Caller, _}, State) ->
    case valid_receipt_id(RequestId) of
        true ->
            receipt_reply(RequestId, fun() ->
                approve_uncertain_receipt(RequestId, ExpectedAttempt,
                    Acknowledgement, Caller, State)
            end, State);
        false -> {reply, {error, invalid_receipt_id}, State}
    end;
handle_call({receipt_claim, RequestId, Meta}, _From, State) ->
    receipt_reply(RequestId, fun() -> receipt_claim(RequestId, Meta, State) end, State);
handle_call({receipt_sent, RequestId, Meta}, _From, State) ->
    receipt_reply(RequestId, fun() -> receipt_sent(RequestId, Meta, State) end, State);
handle_call({receipt_complete, RequestId, Value, ClientMeta}, _From, State) ->
    receipt_reply(RequestId, fun() -> receipt_complete(RequestId, Value, ClientMeta, State) end, State);
handle_call({receipt_uncertain, RequestId, Reason}, _From, State) ->
    receipt_reply(RequestId, fun() -> receipt_uncertain(RequestId, Reason, State) end, State);
handle_call({receipt_release, RequestId}, _From, State) ->
    receipt_reply(RequestId, fun() -> receipt_release(RequestId, State) end, State);
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(refresh, State) ->
    self() ! probe_now,
    {noreply, State};
handle_cast({checkin, LeaseRef, Outcome}, State) ->
    {noreply, checkin_lease(LeaseRef, Outcome, State)};
handle_cast({release, LeaseRef}, State) ->
    {noreply, release_lease(LeaseRef, State)};
handle_cast({probe_result, Id, Token, Ref, Result, DurationMs}, State) ->
    case maps:find(Id, State#state.probes) of
        {ok, #{ref := Ref, monitor := Monitor}} ->
            erlang:demonitor(Monitor, [flush]),
            S = State#state{probes = maps:remove(Id, State#state.probes)},
            handle_cast({probe_result, Id, Token, Result, DurationMs}, S);
        _ -> {noreply, State}
    end;
handle_cast({probe_result, Id, Token, Result, DurationMs}, State) ->
    case maps:find(Id, State#state.nodes) of
        {ok, #{config_token := Token}} ->
            {noreply, apply_probe(Id, Result, DurationMs, State)};
        _ -> {noreply, State}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(probe_all, State0) ->
    case State0#state.probe_timer of undefined -> ok; T -> erlang:cancel_timer(T) end,
    Timer = erlang:send_after(State0#state.health_interval_ms, self(), probe_all),
    handle_info(probe_now, State0#state{probe_timer = Timer});
handle_info(probe_now, State0) ->
    %% Deduplicate refresh/timer probes for each live configuration.
    State = maps:fold(fun(_, Node, S) -> launch_probe(Node, S) end,
                      State0, State0#state.nodes),
    {noreply, State#state{last_probe_at = now_iso8601()}};
handle_info({'DOWN', Monitor, process, _Pid, _Reason}, State) ->
    case [Ref || {Ref, {_, _, M}} <- maps:to_list(State#state.leases), M =:= Monitor] of
        [Ref] -> {noreply, release_lease(Ref, State)};
        _ -> {noreply, probe_down(Monitor, State)}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(fun(_, P) -> stop_probe(P) end, State#state.probes),
    case State#state.receipt_tab of
        undefined -> ok;
        Tab -> dets:close(Tab)
    end,
    ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

run_request(Kind, Role, Prompt, Opts0) when is_atom(Role), is_map(Opts0) ->
    %% Pin once, before checkout/retries; policy changes apply to new requests.
    Opts = ecai_model_internals:prepare(Kind, Role, Opts0),
    Result = run_prepared_request(Kind, Role, Prompt, Opts),
    case Result of
        {ok, _, Meta} -> ecai_model_internals:observe(Meta);
        _ -> ok
    end,
    Result.

run_prepared_request(Kind, Role, Prompt, Opts0) ->
    RequestedModel = optional_binary(maps:get(model, Opts0, undefined)),
    RequestedProvider = normalize_requested_provider(maps:get(provider, Opts0, any)),
    Attempts = positive_int(
        maps:get(
            cluster_attempts,
            Opts0,
            application:get_env(
                ecai,
                code_model_cluster_attempts,
                application:get_env(ecai, code_ollama_cluster_attempts, ?DEFAULT_CLUSTER_ATTEMPTS)
            )
        ),
        ?DEFAULT_CLUSTER_ATTEMPTS
    ),
    QueueTimeout = positive_int(
        maps:get(
            queue_timeout_ms,
            Opts0,
            application:get_env(
                ecai,
                code_model_queue_timeout_ms,
                application:get_env(ecai, code_ollama_queue_timeout_ms, ?DEFAULT_QUEUE_TIMEOUT_MS)
            )
        ),
        ?DEFAULT_QUEUE_TIMEOUT_MS
    ),
    Deadline = erlang:monotonic_time(millisecond) + QueueTimeout,
    request_attempt(
        Kind,
        Role,
        Prompt,
        Opts0,
        RequestedProvider,
        RequestedModel,
        Attempts,
        Deadline,
        [],
        []
    ).

run_native_request(Kind, Role, Request, Opts0) ->
    Fingerprint = term_to_binary(Request, [deterministic]),
    run_request(Kind, Role, Fingerprint, Opts0#{native_request => Request}).

request_attempt(_Kind, Role, _Prompt, _Opts, _Provider, _Model, 0, _Deadline, _Exclude, Errors) ->
    {error, {inference_cluster_failed, Role, lists:reverse(Errors)}};
request_attempt(Kind, Role, Prompt, Opts, Provider, Model, Attempts, Deadline, Exclude, Errors) ->
    case checkout_wait(Role, Provider, Model, Exclude, Deadline) of
        {error, _} = Error ->
            case Errors of
                [] -> Error;
                _ -> {error, {inference_cluster_failed, Role, lists:reverse([Error | Errors])}}
            end;
        {ok, Lease} ->
            case maps:get(billing_sensitive, Lease, false) of
                true ->
                    request_billing_sensitive(
                        Kind,
                        Role,
                        Prompt,
                        Opts,
                        Provider,
                        Model,
                        Attempts,
                        Deadline,
                        Exclude,
                        Errors,
                        Lease
                    );
                false ->
                    request_standard(
                        Kind,
                        Role,
                        Prompt,
                        Opts,
                        Provider,
                        Model,
                        Attempts,
                        Deadline,
                        Exclude,
                        Errors,
                        Lease
                    )
            end
    end.

request_standard(
    Kind,
    Role,
    Prompt,
    Opts,
    Provider,
    Model,
    Attempts,
    Deadline,
    Exclude,
    Errors,
    Lease
) ->
    Started = erlang:monotonic_time(millisecond),
    Result = invoke_client(Kind, Prompt, client_opts(Lease, Opts)),
    Duration = max(0, erlang:monotonic_time(millisecond) - Started),
    LeaseRef = maps:get(ref, Lease),
    NodeId = maps:get(node_id, Lease),
    case Result of
        {ok, Value, ClientMeta} ->
            gen_server:cast(
                ?SERVER,
                {checkin, LeaseRef, #{ok => true, duration_ms => Duration}}
            ),
            {ok, Value, enrich_meta(Role, Lease, ClientMeta)};
        {error, Reason} ->
            gen_server:cast(
                ?SERVER,
                {checkin, LeaseRef, #{
                    ok => false,
                    duration_ms => Duration,
                    error => Reason
                }}
            ),
            request_attempt(
                Kind,
                Role,
                Prompt,
                Opts,
                Provider,
                Model,
                Attempts - 1,
                Deadline,
                lists:usort([NodeId | Exclude]),
                [{NodeId, Reason} | Errors]
            )
    end.

request_billing_sensitive(
    Kind,
    Role,
    Prompt,
    Opts,
    Provider,
    Model,
    Attempts,
    Deadline,
    Exclude,
    Errors,
    Lease
) ->
    LeaseRef = maps:get(ref, Lease),
    NodeId = maps:get(node_id, Lease),
    RequestId = inference_request_id(Kind, Role, Prompt, Lease, Opts),
    ReceiptMeta = receipt_meta(RequestId, Kind, Role, Prompt, Lease, Opts),
    case gen_server:call(?SERVER, {receipt_claim, RequestId, ReceiptMeta}, infinity) of
        {completed, Value, CachedClientMeta} ->
            gen_server:cast(?SERVER, {release, LeaseRef}),
            CacheMeta = CachedClientMeta#{
                cache_hit => true,
                inference_receipt_id => RequestId
            },
            {ok, Value, enrich_meta(Role, Lease, CacheMeta)};
        {blocked, PublicReceipt} ->
            gen_server:cast(?SERVER, {release, LeaseRef}),
            {error, {
                inference_uncertain,
                Role,
                NodeId,
                RequestId,
                maps:get(status, PublicReceipt, uncertain)
            }};
        {error, ReceiptReason} ->
            gen_server:cast(?SERVER, {release, LeaseRef}),
            {error, {inference_receipt_failed, RequestId, ReceiptReason}};
        {ok, claimed} ->
            case
                gen_server:call(
                    ?SERVER,
                    {receipt_sent, RequestId, ReceiptMeta},
                    infinity
                )
            of
                ok ->
                    Started = erlang:monotonic_time(millisecond),
                    Result = invoke_client(Kind, Prompt, client_opts(Lease, Opts)),
                    Duration = max(0, erlang:monotonic_time(millisecond) - Started),
                    handle_billing_result(
                        Result,
                        Kind,
                        Role,
                        Prompt,
                        Opts,
                        Provider,
                        Model,
                        Attempts,
                        Deadline,
                        Exclude,
                        Errors,
                        Lease,
                        RequestId,
                        Duration
                    );
                {error, SentPersistReason} ->
                    _ = gen_server:call(
                        ?SERVER,
                        {receipt_release, RequestId},
                        infinity
                    ),
                    gen_server:cast(?SERVER, {release, LeaseRef}),
                    {error, {
                        inference_receipt_failed,
                        RequestId,
                        SentPersistReason
                    }}
            end
    end.

handle_billing_result(
    {ok, Value, ClientMeta},
    _Kind,
    Role,
    _Prompt,
    _Opts,
    _Provider,
    _Model,
    _Attempts,
    _Deadline,
    _Exclude,
    _Errors,
    Lease,
    RequestId,
    Duration
) ->
    PersistResult = gen_server:call(
        ?SERVER,
        {receipt_complete, RequestId, Value, ClientMeta},
        infinity
    ),
    LeaseRef = maps:get(ref, Lease),
    gen_server:cast(
        ?SERVER,
        {checkin, LeaseRef, #{ok => true, duration_ms => Duration}}
    ),
    Meta0 = enrich_meta(Role, Lease, ClientMeta#{
        cache_hit => false,
        inference_receipt_id => RequestId
    }),
    Meta =
        case PersistResult of
            ok -> Meta0;
            {error, Reason} -> Meta0#{receipt_persist_error => receipt_error_tag(Reason)}
        end,
    {ok, Value, Meta};
handle_billing_result(
    {error, Reason},
    Kind,
    Role,
    Prompt,
    Opts,
    Provider,
    Model,
    Attempts,
    Deadline,
    Exclude,
    Errors,
    Lease,
    RequestId,
    Duration
) ->
    LeaseRef = maps:get(ref, Lease),
    NodeId = maps:get(node_id, Lease),
    gen_server:cast(
        ?SERVER,
        {checkin, LeaseRef, #{
            ok => false,
            duration_ms => Duration,
            error => Reason
        }}
    ),
    case definitely_not_sent(Reason) of
        true ->
            _ = gen_server:call(?SERVER, {receipt_release, RequestId}, infinity),
            request_attempt(
                Kind,
                Role,
                Prompt,
                Opts,
                Provider,
                Model,
                Attempts - 1,
                Deadline,
                lists:usort([NodeId | Exclude]),
                [{NodeId, Reason} | Errors]
            );
        false ->
            _ = gen_server:call(
                ?SERVER,
                {receipt_uncertain, RequestId, Reason},
                infinity
            ),
            {error, {
                inference_uncertain,
                Role,
                NodeId,
                RequestId,
                receipt_error_tag(Reason)
            }}
    end.

invoke_client(Kind, Prompt, ClientOpts) ->
    try
        Result = case Kind of
            messages ->
                ecai_ollama_client:evaluation_chat_with_meta(
                    maps:get(messages, maps:get(native_request, ClientOpts)), ClientOpts);
            json ->
                ecai_ollama_client:generate_json_with_meta(Prompt, ClientOpts);
            text ->
                ecai_ollama_client:generate_text_with_meta(Prompt, ClientOpts);
            native_chat ->
                ecai_ollama_client:native_chat_with_meta(
                    maps:get(native_request, ClientOpts), ClientOpts
                );
            native_generate ->
                ecai_ollama_client:native_generate_with_meta(
                    maps:get(native_request, ClientOpts), ClientOpts
                )
        end,
        case Result of
            {ok, Value, Meta} ->
                {ok, Value, maps:merge(Meta, ecai_model_internals:metadata(ClientOpts))};
            _ -> Result
        end
    catch
        Class:Reason ->
            {error, {inference_client_exception, Class, Reason}}
    end.

checkout_wait(Role, Provider, Model, Exclude, Deadline) ->
    case gen_server:call(?SERVER, {checkout, Role, Provider, Model, Exclude}) of
        {ok, _} = Ok ->
            Ok;
        {error, no_capacity} ->
            Now = erlang:monotonic_time(millisecond),
            case Now >= Deadline of
                true ->
                    {error, {inference_queue_timeout, Role, Provider, Model}};
                false ->
                    timer:sleep(min(100, max(1, Deadline - Now))),
                    checkout_wait(Role, Provider, Model, Exclude, Deadline)
            end;
        {error, _} = Error ->
            Error
    end.

client_opts(Lease, Opts) ->
    NodeOpts = maps:get(client_opts, Lease, #{}),
    Merged0 = bounded_client_opts(maps:merge(NodeOpts, Opts), NodeOpts, Opts),
    Merged1 = Merged0#{
        provider => maps:get(provider, Lease),
        host => maps:get(host, Lease),
        port => maps:get(port, Lease),
        transport => maps:get(transport, Lease, tcp),
        proxy => maps:get(proxy, Lease, direct),
        model => maps:get(model, Lease)
    },
    Resolved = case maps:find(auth, NodeOpts) of
        {ok, Auth} -> Merged1#{auth => Auth};
        error -> Merged1
    end,
    ecai_model_internals:apply_policy(Resolved).

enrich_meta(Role, Lease, ClientMeta) ->
    ClientMeta#{
        role => Role,
        provider => maps:get(provider, Lease),
        node_id => maps:get(node_id, Lease),
        host => to_binary(maps:get(host, Lease)),
        port => maps:get(port, Lease),
        model => maps:get(model, Lease),
        model_digest => maps:get(model_digest, Lease, <<>>),
        model_revision => maps:get(model_revision, Lease, undefined)
    }.

configured_nodes(#{nodes := Nodes}) -> legacy_configured_nodes(#{nodes => Nodes});
configured_nodes(Opts) ->
    case ecai_llm_settings:nodes() of
        {ok, Nodes} -> Nodes; %% An explicitly empty registry MUST NOT enable fallback.
        inherited -> legacy_configured_nodes(Opts)
    end.

legacy_configured_nodes(Opts) ->
    Nodes0 = maps:get(
        nodes,
        Opts,
        application:get_env(
            ecai,
            code_model_nodes,
            application:get_env(ecai, code_ollama_nodes, [])
        )
    ),
    case Nodes0 of
        [] -> [fallback_local_node()];
        Nodes when is_list(Nodes) -> Nodes;
        Other -> [{invalid_nodes, Other}]
    end.

fallback_local_node() ->
    Defaults = ecai_ollama_client:defaults(),
    #{
        id => local,
        provider => ollama,
        host => maps:get(host, Defaults),
        port => maps:get(port, Defaults),
        roles => ?ROLES,
        max_inflight => 1,
        weight => 1,
        default_model => maps:get(model, Defaults),
        models => [maps:get(model, Defaults)]
    }.

normalize_nodes(Nodes0) ->
    try
        NodesList = [normalize_node(N) || N <- Nodes0],
        Ids = [maps:get(id, N) || N <- NodesList],
        case length(lists:usort(Ids)) =:= length(Ids) of
            true -> {ok, maps:from_list([{maps:get(id, N), N} || N <- NodesList])};
            false -> {error, duplicate_inference_node_id}
        end
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, {invalid_inference_nodes, Reason}}
    end.

normalize_node({invalid_nodes, Other}) ->
    throw({invalid_inference_nodes, Other});
normalize_node(Node0) when is_list(Node0) ->
    normalize_node(maps:from_list(Node0));
normalize_node(Node0) when is_map(Node0) ->
    Provider = normalize_provider(maps:get(provider, Node0, ollama)),
    Defaults = provider_node_defaults(Provider),
    Host = maps:get(host, Node0, maps:get(host, Defaults)),
    Port = maps:get(port, Node0, maps:get(port, Defaults)),
    Id = normalize_id(maps:get(id, Node0, default_node_id(Provider, Host, Port))),
    Roles = normalize_roles(maps:get(roles, Node0, ?ROLES)),
    MaxInflight = positive_int(maps:get(max_inflight, Node0, 1), 1),
    Weight = positive_int(maps:get(weight, Node0, 1), 1),
    Models = normalize_models(maps:get(models, Node0, all)),
    DefaultModel = node_default_model(Node0, Provider, Models),
    Digests = normalize_digest_map(maps:get(model_digests, Node0, #{})),
    ClientOpts = node_client_opts(Node0, Defaults, Provider),
    BillingSensitive = billing_sensitive(
        maps:get(billing_sensitive, Node0, default_billing_sensitive(Provider, Host))
    ),
    #{
        id => Id,
        enabled => maps:get(enabled, Node0, true),
        config_token => erlang:unique_integer([positive, monotonic]),
        provider => Provider,
        host => Host,
        port => Port,
        transport => maps:get(transport, Node0, maps:get(transport, Defaults)),
        proxy => maps:get(proxy, Node0, maps:get(proxy, Defaults)),
        billing_sensitive => BillingSensitive,
        roles => Roles,
        max_inflight => MaxInflight,
        weight => Weight,
        default_model => DefaultModel,
        configured_models => Models,
        configured_digests => Digests,
        client_opts => ClientOpts,
        discovered_models => #{},
        health => unknown,
        inflight => 0,
        failures => 0,
        last_error => undefined,
        last_request_error => undefined,
        last_request_at => undefined,
        probe_verified => false,
        probe_latency_ms => undefined,
        selections => 0,
        last_selected => 0,
        latency_ema_ms => undefined,
        last_checked_at => undefined
    };
normalize_node(Other) ->
    throw({invalid_inference_node, Other}).

provider_node_defaults(ollama) ->
    Defaults = ecai_ollama_client:defaults(),
    #{
        host => maps:get(host, Defaults),
        port => maps:get(port, Defaults),
        transport => tcp,
        proxy => direct
    };
provider_node_defaults(anthropic) ->
    #{host => "api.anthropic.com", port => 443, transport => tls, proxy => direct,
      base_path => "/v1", auth => #{type => bearer_env, env => "ANTHROPIC_API_KEY"},
      max_output_tokens => 4096, max_response_bytes => 8388608, response_decode => json_binary};
provider_node_defaults(openai) ->
    #{
        host => "api.openai.com",
        port => 443,
        transport => tls,
        proxy => auto,
        base_path => "/v1",
        auth => #{type => bearer_env, env => "OPENAI_API_KEY"},
        store => false
    };
provider_node_defaults(Other) ->
    throw({unsupported_inference_provider, Other}).

node_default_model(Node, Provider, Models) ->
    Explicit = maps:get(default_model, Node, maps:get(model, Node, undefined)),
    case Explicit of
        undefined ->
            case Models of
                [M | _] -> M;
                all -> provider_default_model(Provider);
                [] -> provider_default_model(Provider)
            end;
        M ->
            to_binary(M)
    end.

provider_default_model(ollama) ->
    to_binary(application:get_env(ecai, code_ollama_model, "qwen3-coder:30b"));
provider_default_model(anthropic) -> <<>>;
provider_default_model(openai) ->
    to_binary(application:get_env(ecai, code_openai_model, "gpt-5.6-sol")).

node_client_opts(Node, Defaults, Provider) ->
    Keys = [
        auth,
        base_path,
        organization,
        organization_env,
        project,
        project_env,
        store,
        timeout,
        connect_timeout,
        max_response_bytes,
        response_decode,
        tls_opts,
        reasoning_effort,
        max_output_tokens,
        temperature
    ],
    Base = maps:with(Keys, Defaults),
    Explicit = maps:with(Keys, Node),
    Auth = node_auth(Node, Provider, maps:get(auth, Base, undefined)),
    ok = validate_pool_auth(Auth),
    (maps:merge(Base, Explicit))#{auth => Auth}.

node_auth(Node, _Provider, _Default) when is_map_key(auth, Node) ->
    maps:get(auth, Node);
node_auth(Node, _Provider, _Default) when is_map_key(api_key_env, Node) ->
    #{type => bearer_env, env => maps:get(api_key_env, Node)};
node_auth(Node, _Provider, _Default) when is_map_key(api_key_file, Node) ->
    #{type => bearer_file, path => maps:get(api_key_file, Node)};
node_auth(Node, _Provider, _Default) when is_map_key(api_key_secret, Node) ->
    #{
        type => bearer_secret,
        scope => node,
        name => maps:get(api_key_secret, Node)
    };
node_auth(_Node, anthropic, undefined) ->
    #{type => bearer_env, env => "ANTHROPIC_API_KEY"};
node_auth(_Node, openai, undefined) ->
    #{type => bearer_env, env => "OPENAI_API_KEY"};
node_auth(_Node, _Provider, Default) ->
    Default.

validate_pool_auth(none) ->
    ok;
validate_pool_auth(undefined) ->
    ok;
validate_pool_auth(#{type := bearer_env, env := _}) ->
    ok;
validate_pool_auth(#{type := bearer_file, path := _}) ->
    ok;
validate_pool_auth({bearer_env, _}) ->
    ok;
validate_pool_auth({bearer_file, _}) ->
    ok;
validate_pool_auth(#{type := bearer_secret, scope := node, name := Name}) when
    is_binary(Name); is_list(Name); is_atom(Name)
->
    ok;
validate_pool_auth(#{type := bearer}) ->
    throw(direct_bearer_secret_not_allowed_in_pool_config);
validate_pool_auth({bearer, _}) ->
    throw(direct_bearer_secret_not_allowed_in_pool_config);
validate_pool_auth(Other) ->
    throw({unsupported_pool_auth, Other}).

normalize_roles(Roles) when is_list(Roles) ->
    case [R || R <- Roles, not lists:member(R, ?ROLES)] of
        [] -> lists:usort(Roles);
        Bad -> throw({invalid_inference_roles, Bad})
    end;
normalize_roles(Other) ->
    throw({invalid_inference_roles, Other}).

normalize_models(all) -> all;
normalize_models(Models) when is_list(Models) -> lists:usort([to_binary(M) || M <- Models]);
normalize_models(Other) -> throw({invalid_inference_models, Other}).

normalize_digest_map(Map) when is_map(Map) ->
    maps:from_list([{to_binary(K), to_binary(V)} || {K, V} <- maps:to_list(Map)]);
normalize_digest_map(Other) ->
    throw({invalid_model_digests, Other}).

default_node_id(Provider, Host, Port) ->
    <<
        (to_binary(Provider))/binary,
        ":",
        (to_binary(Host))/binary,
        ":",
        (integer_to_binary(Port))/binary
    >>.

normalize_id(B) when is_binary(B) -> B;
normalize_id(A) when is_atom(A) -> atom_to_binary(A, utf8);
normalize_id(L) when is_list(L) -> unicode:characters_to_binary(L);
normalize_id(V) -> iolist_to_binary(io_lib:format("~p", [V])).

select_node(Role, Provider, Model, Exclude, State) ->
    Nodes = [
        N
     || N <- maps:values(State#state.nodes),
        eligible(N, Role, Provider, Model, Exclude)
    ],
    case Nodes of
        [] ->
            case any_role_model_candidate(State#state.nodes, Role, Provider, Model, Exclude) of
                true -> {error, no_capacity};
                false -> {error, {no_eligible_inference_node, Role, Provider, Model}}
            end;
        _ ->
            [Best | _] = lists:sort(fun better_node/2, Nodes),
            {ok, Best}
    end.

eligible(Node, Role, Provider, Model, Exclude) ->
    maps:get(enabled, Node, true) andalso
    not lists:member(maps:get(id, Node), Exclude) andalso
        health_ready(Node) andalso
        provider_matches(Node, Provider) andalso
        lists:member(Role, maps:get(roles, Node, [])) andalso
        supports_model(Node, Model) andalso
        maps:get(inflight, Node, 0) < maps:get(max_inflight, Node, 1).

any_role_model_candidate(Nodes, Role, Provider, Model, Exclude) ->
    lists:any(
        fun(Node) ->
            maps:get(enabled, Node, true) andalso
            not lists:member(maps:get(id, Node), Exclude) andalso
                maps:get(health, Node, unknown) =/= down andalso
                provider_matches(Node, Provider) andalso
                lists:member(Role, maps:get(roles, Node, [])) andalso
                supports_model(Node, Model)
        end,
        maps:values(Nodes)
    ).

health_ready(Node) ->
    Health = maps:get(health, Node, unknown),
    Health =:= healthy orelse
        (Health =:= degraded andalso maps:get(probe_verified, Node, false)).

provider_matches(_Node, any) -> true;
provider_matches(Node, Provider) -> maps:get(provider, Node, ollama) =:= Provider.

supports_model(Node, undefined) ->
    supports_model(Node, maps:get(default_model, Node));
supports_model(Node, Model) ->
    Configured = maps:get(configured_models, Node, all),
    ConfiguredOk = Configured =:= all orelse lists:member(Model, Configured),
    Discovered = maps:get(discovered_models, Node, #{}),
    DiscoveredOk = maps:size(Discovered) =:= 0 orelse maps:is_key(Model, Discovered),
    ConfiguredOk andalso DiscoveredOk andalso digest_matches(Node, Model).

inference_matches(Node, Role, Provider, Model, Digest) ->
    maps:get(enabled, Node, true) andalso
    health_ready(Node) andalso
        provider_matches(Node, Provider) andalso
        lists:member(Role, maps:get(roles, Node, [])) andalso
        supports_model(Node, Model) andalso
        inference_digest_matches(Node, Model, Digest).

inference_digest_matches(_Node, _Model, undefined) ->
    true;
inference_digest_matches(Node, undefined, Digest) ->
    inference_digest_matches(Node, maps:get(default_model, Node), Digest);
inference_digest_matches(Node, Model, Digest) ->
    case {maps:get(provider, Node, ollama), Digest} of
        {openai, _} -> true;
        {anthropic, _} -> true;
        {ollama, <<>>} -> true;
        {ollama, _} -> model_digest(Node, Model) =:= Digest
    end.

digest_matches(Node, Model) ->
    Expected = maps:get(Model, maps:get(configured_digests, Node, #{}), undefined),
    Discovered = maps:get(Model, maps:get(discovered_models, Node, #{}), #{}),
    Actual = maps:get(digest, Discovered, undefined),
    case {Expected, Actual} of
        {undefined, _} -> true;
        {_, undefined} -> true;
        {E, A} -> E =:= A
    end.

better_node(A, B) ->
    ScoreA = node_score(A),
    ScoreB = node_score(B),
    ScoreA =< ScoreB.

node_score(Node) ->
    Inflight = maps:get(inflight, Node, 0),
    Selections = maps:get(selections, Node, 0),
    Weight = max(1, maps:get(weight, Node, 1)),
    Latency = maps:get(latency_ema_ms, Node, undefined),
    LatencyScore =
        case Latency of
            undefined -> 0.0;
            L -> L / 1000000.0
        end,
    {
        ((Selections + Inflight) / Weight) + LatencyScore,
        maps:get(failures, Node, 0),
        maps:get(last_selected, Node, 0)
    }.

lease_map(LeaseRef, Role, RequestedModel, Node) ->
    Model =
        case RequestedModel of
            undefined -> maps:get(default_model, Node);
            _ -> RequestedModel
        end,
    ModelInfo = maps:get(Model, maps:get(discovered_models, Node, #{}), #{}),
    #{
        ref => LeaseRef,
        role => Role,
        provider => maps:get(provider, Node, ollama),
        node_id => maps:get(id, Node),
        host => maps:get(host, Node),
        port => maps:get(port, Node),
        transport => maps:get(transport, Node, tcp),
        proxy => maps:get(proxy, Node, direct),
        billing_sensitive => maps:get(billing_sensitive, Node, false),
        model => Model,
        model_digest => model_digest(Node, Model),
        model_revision => maps:get(created, ModelInfo, undefined),
        client_opts => maps:get(client_opts, Node, #{})
    }.

model_digest(Node, Model) ->
    Discovered = maps:get(Model, maps:get(discovered_models, Node, #{}), #{}),
    case maps:get(digest, Discovered, undefined) of
        undefined -> maps:get(Model, maps:get(configured_digests, Node, #{}), <<>>);
        Digest -> Digest
    end.

release_lease(LeaseRef, State0) ->
    case maps:take(LeaseRef, State0#state.leases) of
        error ->
            State0;
        {{Id, _Token, Monitor}, Leases} ->
            erlang:demonitor(Monitor, [flush]),
            Started = maps:remove(LeaseRef, State0#state.lease_started),
            case maps:find(Id, State0#state.nodes) of
                error ->
                    State0#state{leases = Leases, lease_started = Started};
                {ok, Node0} ->
                    Inflight = max(0, maps:get(inflight, Node0, 0) - 1),
                    Node = Node0#{inflight => Inflight},
                    State0#state{
                        nodes = (State0#state.nodes)#{Id => Node},
                        leases = Leases,
                        lease_started = Started
                    }
            end
    end.

checkin_lease(LeaseRef, Outcome, State0) ->
    case maps:find(LeaseRef, State0#state.leases) of
        error -> State0;
        {ok, {Id, Token, _Monitor}} ->
            Released = release_lease(LeaseRef, State0),
            case maps:find(Id, Released#state.nodes) of
                {ok, #{config_token := Token} = N0} ->
                    N1 = (update_latency(N0, maps:get(duration_ms, Outcome, undefined)))#{
                        last_request_at => now_iso8601()},
                    N = case maps:get(ok, Outcome, false) of
                        true -> N1#{health => healthy, failures => 0, last_error => undefined,
                                    last_request_error => undefined, probe_verified => true};
                        false ->
                            F = maps:get(failures, N1, 0) + 1,
                            H = case F >= Released#state.failure_threshold of
                                true -> down; false -> degraded end,
                            Error = maps:get(error, Outcome, request_failed),
                            N1#{health => H, failures => F, last_error => Error,
                                last_request_error => ecai_inference_diagnostics:public_error(Error)}
                    end,
                    Released#state{nodes = (Released#state.nodes)#{Id => N}};
                _ -> Released %% Old endpoint's outcome cannot alter new health.
            end
    end.

update_latency(Node, undefined) ->
    Node;
update_latency(Node, Duration) when is_integer(Duration), Duration >= 0 ->
    Prev = maps:get(latency_ema_ms, Node, undefined),
    Ema =
        case Prev of
            undefined -> Duration * 1.0;
            P -> (P * 0.8) + (Duration * 0.2)
        end,
    Node#{latency_ema_ms => Ema};
update_latency(Node, _) ->
    Node.

launch_probe(#{enabled := false}, State) -> State;
launch_probe(Node, State) ->
    Id = maps:get(id, Node), Token = maps:get(config_token, Node),
    case maps:find(Id, State#state.probes) of
        {ok, #{token := Token}} -> State;
        Existing ->
            case Existing of {ok, Old} -> stop_probe(Old); error -> ok end,
            Parent = self(), Ref = make_ref(),
            ProbeOpts = maps:merge(maps:get(client_opts, Node, #{}),
                                  maps:with([provider, host, port, transport, proxy], Node)),
            Timeout = State#state.health_timeout_ms,
            {Pid, Monitor} = spawn_monitor(fun() ->
                Started = erlang:monotonic_time(millisecond),
                Result = try ecai_ollama_client:probe(ProbeOpts#{health_timeout => Timeout})
                         catch _:_ -> {error, probe_failed} end,
                Duration = max(0, erlang:monotonic_time(millisecond) - Started),
                gen_server:cast(Parent, {probe_result, Id, Token, Ref, Result, Duration})
            end),
            State#state{probes = (State#state.probes)#{Id => #{pid => Pid,
                monitor => Monitor, ref => Ref, token => Token}}}
    end.
stop_probe(#{pid := Pid, monitor := Monitor}) ->
    exit(Pid, kill), erlang:demonitor(Monitor, [flush]), ok.
probe_down(Monitor, State) ->
    lists:foldl(fun({Id, P}, S) ->
        case maps:get(monitor, P) =:= Monitor of
            false -> S;
            true ->
                S1 = S#state{probes = maps:remove(Id, S#state.probes)},
                Token = maps:get(token, P),
                case maps:find(Id, S1#state.nodes) of
                    {ok, #{config_token := Token}} -> apply_probe(Id, {error, probe_failed}, 0, S1);
                    _ -> S1
                end
        end
    end, State, maps:to_list(State#state.probes)).

apply_probe(Id, Result, DurationMs, State0) ->
    case maps:find(Id, State0#state.nodes) of
        error ->
            State0;
        {ok, Node0} ->
            %% Catalog latency is not generation latency; do not mix the EMAs.
            Node1 = Node0#{probe_latency_ms => DurationMs},
            Node =
                case Result of
                    {ok, #{models := Models0}} ->
                        Models = filter_discovered_models(Node1, Models0),
                        Node2 = Node1#{
                            discovered_models => Models,
                            last_checked_at => now_iso8601(),
                            failures => 0
                        },
                        case validate_probe_models(Node2) of
                            ok ->
                                Node2#{health => healthy, last_error => undefined, probe_verified => true};
                            {error, ProbeReason} ->
                                Node2#{health => down, last_error => ProbeReason, probe_verified => false}
                        end;
                    {error, Reason} ->
                        Failures = maps:get(failures, Node1, 0) + 1,
                        Health =
                            case Failures >= State0#state.failure_threshold of
                                true -> down;
                                false -> degraded
                            end,
                        Node1#{
                            health => Health,
                            failures => Failures,
                            last_error => Reason,
                            last_checked_at => now_iso8601()
                        }
                end,
            State0#state{nodes = (State0#state.nodes)#{Id => Node}}
    end.

filter_discovered_models(Node, Models) ->
    case maps:get(configured_models, Node, all) of
        all -> Models;
        Configured when is_list(Configured) -> maps:with(Configured, Models)
    end.

validate_probe_models(Node) ->
    DefaultModel = maps:get(default_model, Node),
    Models = maps:get(discovered_models, Node, #{}),
    case maps:is_key(DefaultModel, Models) of
        false ->
            {error, {default_model_unavailable, DefaultModel}};
        true ->
            case configured_digest_mismatch(Node) of
                none -> ok;
                Mismatch -> {error, Mismatch}
            end
    end.

configured_digest_mismatch(Node) ->
    Expected = maps:get(configured_digests, Node, #{}),
    Actual = maps:get(discovered_models, Node, #{}),
    Mismatches = [
        {Model, Digest, maps:get(digest, maps:get(Model, Actual, #{}), undefined)}
     || {Model, Digest} <- maps:to_list(Expected),
        maps:is_key(Model, Actual),
        maps:get(digest, maps:get(Model, Actual), undefined) =/= Digest
    ],
    case Mismatches of
        [] -> none;
        _ -> {model_digest_mismatch, Mismatches}
    end.

status_map(State) ->
    Nodes = lists:sort(
        fun(A, B) -> maps:get(id, A) =< maps:get(id, B) end,
        [public_node(N, State) || N <- maps:values(State#state.nodes)]
    ),
    #{
        nodes => Nodes,
        config_revision => State#state.config_revision,
        node_count => length(Nodes),
        healthy => length([N || N <- Nodes, maps:get(health, N) =:= healthy]),
        degraded => length([N || N <- Nodes, maps:get(health, N) =:= degraded]),
        down => length([N || N <- Nodes, maps:get(health, N) =:= down]),
        capacity => maps:from_list([
            {Role, role_capacity(Role, State#state.nodes)}
         || Role <- ?ROLES
        ]),
        available_capacity => maps:from_list([
            {Role, lists:sum([maps:get(available_slots, N) || N <- Nodes,
                             lists:member(Role, maps:get(roles, N))])} || Role <- ?ROLES]),
        runtime => #{health_interval_ms => State#state.health_interval_ms,
                     health_timeout_ms => State#state.health_timeout_ms,
                     failure_threshold => State#state.failure_threshold,
                     queue_timeout_ms => runtime_default(code_model_queue_timeout_ms,
                         code_ollama_queue_timeout_ms, ?DEFAULT_QUEUE_TIMEOUT_MS),
                     cluster_attempts => runtime_default(code_model_cluster_attempts,
                         code_ollama_cluster_attempts, ?DEFAULT_CLUSTER_ATTEMPTS)},
        active_probes => map_size(State#state.probes),
        active_leases => maps:size(State#state.leases),
        inference_receipts => receipt_status(State),
        last_probe_at => State#state.last_probe_at
    }.

public_node(Node, State) ->
    Public = maps:with(
        [
            id,
            enabled,
            provider,
            host,
            port,
            billing_sensitive,
            roles,
            max_inflight,
            weight,
            default_model,
            configured_models,
            configured_digests,
            discovered_models,
            health,
            inflight,
            failures,
            last_error,
            last_request_error,
            last_request_at,
            probe_latency_ms,
            selections,
            latency_ema_ms,
            last_checked_at
        ],
        Node
    ),
    ClientOpts0 = maps:get(client_opts, Node, #{}),
    ClientOpts =
        case maps:find(auth, ClientOpts0) of
            {ok, Auth} -> ClientOpts0#{auth => ecai_ollama_client:public_auth(Auth)};
            error -> ClientOpts0
        end,
    Id = maps:get(id, Node),
    Now = erlang:monotonic_time(millisecond),
    Ages = [max(0, Now - maps:get(Ref, State#state.lease_started, Now)) ||
        {Ref, {LeaseId, _, _}} <- maps:to_list(State#state.leases), LeaseId =:= Id],
    Slots = case maps:get(enabled, Node, true) andalso health_ready(Node) of
        true -> max(0, maps:get(max_inflight, Node) - maps:get(inflight, Node));
        false -> 0
    end,
    Public#{
        last_error => ecai_inference_diagnostics:public_error(maps:get(last_error, Node, undefined)),
        available_slots => Slots,
        saturated => maps:get(enabled, Node, true) andalso health_ready(Node) andalso Slots =:= 0,
        oldest_inflight_ms => case Ages of [] -> 0; _ -> lists:max(Ages) end,
        host => to_binary(maps:get(host, Node)),
        client_options => maps:without([tls_opts], ClientOpts)
    }.

role_capacity(Role, Nodes) ->
    lists:sum([
        maps:get(max_inflight, N, 1)
     || N <- maps:values(Nodes),
        maps:get(enabled, N, true),
        maps:get(health, N, unknown) =/= down,
        lists:member(Role, maps:get(roles, N, []))
    ]).

open_receipt_store(Opts) ->
    case ecai_code_paths:state_root(Opts) of
        {error, _} = Error ->
            Error;
        {ok, Root} ->
            File = ecai_code_paths:dets_file(Root, ?RECEIPT_FILE),
            case
                dets:open_file(?RECEIPT_TABLE, [
                    {file, File},
                    {type, set},
                    {auto_save, 5000}
                ])
            of
                {ok, ?RECEIPT_TABLE} ->
                    {ok, ?RECEIPT_TABLE, File};
                {error, Reason} ->
                    {error, {receipt_store_open_failed, File, Reason}}
            end
    end.

receipt_claim(RequestId, Meta, State) ->
    Tab = State#state.receipt_tab,
    Key = {inference_receipt, RequestId},
    case dets:lookup(Tab, Key) of
        [{Key, #{status := completed, value := Value} = Receipt}] ->
            {completed, Value, maps:get(client_meta, Receipt, #{})};
        [{Key, #{status := Status} = Receipt}] when
            Status =:= claimed; Status =:= sent; Status =:= uncertain
        ->
            %% Claim reservation is exclusive too: two callers must not both
            %% leave receipt_claim/3 before either marks the request sent.
            {blocked, public_receipt(Receipt)};
        [{Key, #{status := retry_approved} = Receipt}] ->
            claim_receipt(Tab, Key, Meta, Receipt);
        [] ->
            claim_receipt(Tab, Key, Meta, #{});
        {error, Why} ->
            {error, {receipt_lookup_failed, receipt_error_tag(Why)}};
        _ ->
            {error, invalid_inference_receipt_state}
    end.

claim_receipt(Tab, Key, Meta, Previous) ->
    Receipt = Meta#{
        status => claimed,
        attempt => maps:get(attempt, Previous, 1),
        retry_history => maps:get(retry_history, Previous, []),
        claimed_at => now_iso8601()
    },
    case put_receipt(Tab, Key, Receipt) of
        ok -> {ok, claimed};
        {error, _} = Error -> Error
    end.

inspect_inference_receipt(RequestId, State) ->
    case valid_receipt_id(RequestId) of
        false -> {error, invalid_receipt_id};
        true ->
            case dets:lookup(State#state.receipt_tab, {inference_receipt, RequestId}) of
                [{_, Receipt}] when is_map(Receipt) ->
                    {ok, public_receipt(Receipt#{request_id => RequestId})};
                [] -> {error, not_found};
                {error, Why} -> {error, {receipt_lookup_failed, receipt_error_tag(Why)}};
                _ -> {error, invalid_inference_receipt_state}
            end
    end.

valid_receipt_id(Id) when is_binary(Id), byte_size(Id) =:= 64 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                       (C >= $a andalso C =< $f) end, binary_to_list(Id));
valid_receipt_id(_) -> false.

approve_uncertain_receipt(_Id, _Attempt, Ack, _Caller, _State)
  when Ack =/= accept_duplicate_inference_cost ->
    {error, duplicate_inference_cost_acknowledgement_required};
approve_uncertain_receipt(_Id, Attempt, _Ack, _Caller, _State)
  when not is_integer(Attempt); Attempt < 1 ->
    {error, invalid_expected_attempt};
approve_uncertain_receipt(Id, ExpectedAttempt, _Ack, Caller, State) ->
    Tab = State#state.receipt_tab,
    Key = {inference_receipt, Id},
    case dets:lookup(Tab, Key) of
        [{Key, #{status := uncertain} = Receipt}] ->
            case maps:get(attempt, Receipt, 1) =:= ExpectedAttempt of
                false -> {error, stale_receipt_attempt};
                true -> persist_retry_approval(Tab, Key, Receipt, ExpectedAttempt, Caller)
            end;
        [{Key, #{status := Status}}] -> {error, {receipt_not_uncertain, Status}};
        [] -> {error, not_found};
        {error, Why} -> {error, {receipt_lookup_failed, receipt_error_tag(Why)}};
        _ -> {error, invalid_inference_receipt_state}
    end.

persist_retry_approval(Tab, Key, Receipt, Attempt, Caller) ->
    History = maps:get(retry_history, Receipt, []),
    case is_list(History) of
        false -> {error, invalid_receipt_history};
        true ->
            Approval = (public_receipt_attempt(Receipt))#{
                attempt => Attempt,
                retry_approved_at => now_iso8601(),
                approved_from_node => atom_to_binary(node(Caller), utf8),
                approved_from_pid => list_to_binary(pid_to_list(Caller)),
                duplicate_inference_cost_accepted => true
            },
            Approved = Receipt#{status => retry_approved, attempt => Attempt + 1,
                retry_history => History ++ [Approval]},
            case put_receipt(Tab, Key, Approved) of
                ok -> {ok, public_receipt(Approved)};
                {error, Why} ->
                    %% Do not leave a RAM-visible approval after a failed sync.
                    %% On storage failure, callers must re-inspect, not assume
                    %% that retrying the approval command is harmless.
                    ok = dets:insert(Tab, {Key, Receipt}),
                    _ = dets:sync(Tab),
                    {error, {retry_approval_not_persisted, receipt_error_tag(Why)}}
            end
    end.

receipt_sent(RequestId, Meta, State) ->
    Tab = State#state.receipt_tab,
    Key = {inference_receipt, RequestId},
    Existing = receipt_value(Tab, Key, #{}),
    Receipt = (maps:merge(Existing, Meta))#{
        status => sent,
        sent_at => now_iso8601()
    },
    put_receipt(Tab, Key, Receipt).

receipt_complete(RequestId, Value, ClientMeta, State) ->
    Tab = State#state.receipt_tab,
    Key = {inference_receipt, RequestId},
    Existing = receipt_value(Tab, Key, #{}),
    Receipt = Existing#{
        status => completed,
        value => Value,
        client_meta => safe_client_meta(ClientMeta),
        completed_at => now_iso8601()
    },
    put_receipt(Tab, Key, Receipt).

receipt_uncertain(RequestId, Reason, State) ->
    Tab = State#state.receipt_tab,
    Key = {inference_receipt, RequestId},
    Existing = receipt_value(Tab, Key, #{}),
    Receipt = Existing#{
        status => uncertain,
        error => receipt_error_tag(Reason),
        error_detail => ecai_inference_diagnostics:public_error(Reason),
        uncertain_at => now_iso8601()
    },
    put_receipt(Tab, Key, Receipt).

receipt_release(RequestId, State) ->
    Tab = State#state.receipt_tab,
    Key = {inference_receipt, RequestId},
    case dets:lookup(Tab, Key) of
        [{Key, #{retry_history := [_ | _], status := Status} = Receipt}] when
            Status =:= claimed; Status =:= sent; Status =:= retry_approved ->
            %% A definitely-not-sent failure may try another endpoint, but
            %% must not erase the prior uncertain attempt/operator approval.
            put_receipt(Tab, Key, Receipt#{status => retry_approved});
        [{Key, #{retry_history := [_ | _]}}] ->
            {error, receipt_history_must_be_preserved};
        {error, Why} ->
            {error, {receipt_lookup_failed, receipt_error_tag(Why)}};
        _ ->
            case dets:delete(Tab, Key) of
                ok -> dets:sync(Tab);
                {error, _} = Error -> Error
            end
    end.

receipt_value(Tab, Key, Default) ->
    case dets:lookup(Tab, Key) of
        [{Key, Value}] when is_map(Value) -> Value;
        _ -> Default
    end.

put_receipt(Tab, Key, Receipt) ->
    case dets:insert(Tab, {Key, Receipt}) of
        ok -> dets:sync(Tab);
        {error, _} = Error -> Error
    end.

receipt_status(State) ->
    case State#state.receipt_tab of
        undefined ->
            #{enabled => false};
        _Tab ->
            #{
                enabled => true,
                file => to_binary(State#state.receipt_file),
                statuses => State#state.receipt_counts
            }
    end.

public_receipt(Receipt) ->
    Base = public_receipt_attempt(Receipt),
    History = case maps:get(retry_history, Receipt, []) of
        H when is_list(H) -> H;
        _ -> []
    end,
    Base#{attempt => maps:get(attempt, Receipt, 1),
        retry_history => [public_receipt_attempt(R) || R <- History, is_map(R)]}.

public_receipt_attempt(Receipt) ->
    %% Explicit allowlist: never expose cached output, prompts, credentials,
    %% headers, or raw provider error bodies through the operator API.
    Base0 = maps:with([request_id, schema, kind, role, provider, node_id, model,
        prompt_sha256, options_sha256, created_at, claimed_at, sent_at,
        uncertain_at, completed_at, status, attempt, retry_approved_at,
        approved_from_node, approved_from_pid, duplicate_inference_cost_accepted], Receipt),
    Base = case maps:find(error, Receipt) of
        {ok, E} when is_atom(E) -> Base0#{error => E};
        _ -> Base0
    end,
    case maps:get(error_detail, Receipt, undefined) of
        D when is_map(D) ->
            Detail = maps:filter(fun(K, V) ->
                (lists:member(K, [code, phase, reason]) andalso is_atom(V)) orelse
                (K =:= http_status andalso is_integer(V) andalso V >= 100 andalso V =< 599)
            end, D),
            Base#{error_detail => Detail};
        _ -> Base
    end.

safe_client_meta(Meta) when is_map(Meta) ->
    maps:without([auth, headers, request_headers], Meta);
safe_client_meta(_) ->
    #{}.

receipt_meta(RequestId, Kind, Role, Prompt0, Lease, Opts) ->
    #{
        request_id => RequestId,
        schema => 1,
        kind => Kind,
        role => Role,
        provider => maps:get(provider, Lease),
        node_id => maps:get(node_id, Lease),
        model => maps:get(model, Lease),
        prompt_sha256 => sha256_hex(to_binary(Prompt0)),
        options_sha256 => sha256_hex(
            term_to_binary(output_options(client_opts(Lease, Opts)), [deterministic])
        ),
        created_at => now_iso8601()
    }.

inference_request_id(Kind, Role, Prompt0, Lease, Opts) ->
    Prompt = to_binary(Prompt0),
    Fingerprint = {
        inference_receipt_v1,
        Kind,
        Role,
        maps:get(provider, Lease),
        maps:get(model, Lease),
        Prompt,
        output_options(client_opts(Lease, Opts))
    },
    sha256_hex(term_to_binary(Fingerprint, [deterministic])).

output_options(Opts) ->
    maps:with(
        [
            temperature, top_p, top_k, min_p, seed, repeat_penalty, num_ctx,
            system, format, model_internals,
            reasoning_effort,
            max_output_tokens
        ],
        Opts
    ).

definitely_not_sent({ollama_request_failed, Reason}) ->
    pre_send_transport_error(Reason);
definitely_not_sent({anthropic_request_failed, Reason}) ->
    pre_send_transport_error(Reason);
definitely_not_sent({openai_request_failed, Reason}) ->
    pre_send_transport_error(Reason);
definitely_not_sent({missing_auth_environment_variable, _}) ->
    true;
definitely_not_sent({empty_auth_environment_variable, _}) ->
    true;
definitely_not_sent({empty_auth_file, _}) ->
    true;
definitely_not_sent({cannot_read_auth_file, _, _}) ->
    true;
definitely_not_sent({auth_secret_not_found, _, _}) ->
    true;
definitely_not_sent({auth_secret_lookup_failed, _, _, _}) ->
    true;
definitely_not_sent({auth_secret_lookup_exception, _, _, _, _}) ->
    true;
definitely_not_sent({unsupported_auth_configuration, _}) ->
    true;
definitely_not_sent({unsupported_native_option, _, _}) ->
    true;
definitely_not_sent(invalid_native_chat_messages) ->
    true;
definitely_not_sent(invalid_native_generate_prompt) ->
    true;
definitely_not_sent(invalid_bearer_token) -> true;
definitely_not_sent(anthropic_api_key_required) -> true;
definitely_not_sent(invalid_anthropic_request) -> true;
definitely_not_sent(invalid_anthropic_temperature) -> true;
definitely_not_sent(anthropic_tools_not_supported) -> true;
definitely_not_sent(empty_bearer_token) ->
    true;
definitely_not_sent(_) ->
    false.

pre_send_transport_error({gun_not_started, _}) -> true;
pre_send_transport_error({gun_open_exit, _}) -> true;
pre_send_transport_error({await_up_failed, _}) -> true;
pre_send_transport_error({await_up_exit, _}) -> true;
pre_send_transport_error(econnrefused) -> true;
pre_send_transport_error(nxdomain) -> true;
pre_send_transport_error(enetunreach) -> true;
pre_send_transport_error(ehostunreach) -> true;
pre_send_transport_error(_) -> false.

receipt_error_tag(Reason) when is_atom(Reason) ->
    Reason;
receipt_error_tag({Tag, _}) when is_atom(Tag) ->
    Tag;
receipt_error_tag({Tag, _, _}) when is_atom(Tag) ->
    Tag;
receipt_error_tag({Tag, _, _, _}) when is_atom(Tag) ->
    Tag;
receipt_error_tag(_) ->
    inference_error.

default_billing_sensitive(anthropic, _Host) -> true;
default_billing_sensitive(openai, _Host) ->
    true;
default_billing_sensitive(ollama, Host) ->
    string:lowercase(binary_to_list(to_binary(Host))) =:= "ollama.com";
default_billing_sensitive(_, _) ->
    false.

billing_sensitive(true) -> true;
billing_sensitive(false) -> false;
billing_sensitive(Other) -> throw({invalid_billing_sensitive, Other}).

sha256_hex(Bin) when is_binary(Bin) ->
    iolist_to_binary([
        io_lib:format("~2.16.0b", [B])
     || <<B>> <= crypto:hash(sha256, Bin)
    ]).

normalize_provider(anthropic) -> anthropic;
normalize_provider(<<"anthropic">>) -> anthropic;
normalize_provider("anthropic") -> anthropic;
normalize_provider(ollama) -> ollama;
normalize_provider(openai) -> openai;
normalize_provider(<<"ollama">>) -> ollama;
normalize_provider(<<"openai">>) -> openai;
normalize_provider("ollama") -> ollama;
normalize_provider("openai") -> openai;
normalize_provider(Other) -> throw({unsupported_inference_provider, Other}).

normalize_requested_provider(any) -> any;
normalize_requested_provider(undefined) -> any;
normalize_requested_provider(Provider) -> normalize_provider(Provider).

optional_binary(undefined) -> undefined;
optional_binary(<<>>) -> undefined;
optional_binary(Value) -> to_binary(Value).

opt(Key, Opts, Default) -> maps:get(Key, Opts, Default).

positive_int(V, _Default) when is_integer(V), V > 0 -> V;
positive_int(_, Default) -> Default.

now_iso8601() ->
    unicode:characters_to_binary(
        calendar:system_time_to_rfc3339(
            erlang:system_time(second), [{unit, second}, {offset, "Z"}]
        )
    ).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%% Authoring clients can tighten node limits but cannot raise operator caps.
%% Other existing workloads retain their established merge semantics.
bounded_client_opts(Merged, NodeOpts, #{enforce_node_limits := true}) ->
    lists:foldl(fun(Key, Acc) ->
        case {maps:get(Key, NodeOpts, undefined), maps:get(Key, Acc, undefined)} of
            {N, R} when is_integer(N), N > 0, is_integer(R), R > 0 -> Acc#{Key => min(N,R)};
            _ -> Acc
        end
    end, Merged, [timeout, connect_timeout, max_output_tokens, max_response_bytes]);
bounded_client_opts(Merged, _, _) -> Merged.

%% Status never scans receipt payloads. Count once on startup and adjust only
%% the changed receipt, including in-memory DETS changes when sync fails.
load_receipt_counts(Tab) ->
    ok = dets:safe_fixtable(Tab, true),
    try
        receipt_count_page(dets:select(Tab, [{{{inference_receipt, '_'}, '$1'},
            [{'is_map', '$1'}, {'is_map_key', status, '$1'}], [{map_get, status, '$1'}]}], 256), #{})
    after dets:safe_fixtable(Tab, false) end.
receipt_count_page('$end_of_table', Counts) -> Counts;
receipt_count_page({Statuses, Continuation}, Counts) when is_list(Statuses) ->
    Next = lists:foldl(fun(Status, Acc) -> bump_count(receipt_state(Status), 1, Acc) end,
                      Counts, Statuses),
    receipt_count_page(dets:select(Continuation), Next);
receipt_count_page({error, Reason}, _) -> error({receipt_count_failed, Reason}).
receipt_key_status(Tab, Key) ->
    case dets:select(Tab, [{{Key, '$1'},
        [{'is_map', '$1'}, {'is_map_key', status, '$1'}], [{map_get, status, '$1'}]}]) of
        [Status] -> receipt_state(Status);
        [] -> absent
    end.
receipt_reply(RequestId, Fun, State) ->
    Key = {inference_receipt, RequestId}, Tab = State#state.receipt_tab,
    Before = receipt_key_status(Tab, Key),
    Reply = Fun(),
    After = receipt_key_status(Tab, Key),
    Counts = case Before =:= After of
        true -> State#state.receipt_counts;
        false -> bump_count(After, 1, bump_count(Before, -1, State#state.receipt_counts))
    end,
    {reply, Reply, State#state{receipt_counts = Counts}}.
receipt_state(S) when S =:= claimed; S =:= sent; S =:= uncertain;
                      S =:= completed; S =:= retry_approved -> S;
receipt_state(_) -> unknown.
bump_count(absent, _, Counts) -> Counts;
bump_count(Status, Delta, Counts) ->
    case max(0, maps:get(Status, Counts, 0) + Delta) of
        0 -> maps:remove(Status, Counts);
        N -> Counts#{Status => N}
    end.
runtime_default(Key, Legacy, Default) ->
    application:get_env(ecai, Key, application:get_env(ecai, Legacy, Default)).
