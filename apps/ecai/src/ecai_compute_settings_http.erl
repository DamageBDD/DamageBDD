%% Session-bound account settings and bearer-bound spend/mint mutations.
%% Never accepts API keys or wallet private keys.
-module(ecai_compute_settings_http).
-export([trails/0, init/2]).

trails() ->
    [
        trail("/ecai/compute/settings", settings, get),
        trail("/ecai/compute/eligible-sources", sources, get),
        trail("/ecai/compute/policy", policy, post),
        trail("/ecai/compute/providers/:provider", provider, post),
        trail("/ecai/compute/providers/:provider/prepare", prepare, post),
        trail("/ecai/compute/providers/:provider/verify", verify, post),
        trail("/ecai/compute/quote", quote, post),
        trail("/ecai/compute/reservations", reserve, post),
        trail("/ecai/compute/reservations/:id/cancel", cancel, post),
        trail("/ecai/compute/mintable", mintable, get),
        trail("/ecai/compute/mint-requests", mint, post)
    ].
trail(Path, Action, Method) ->
    trails:trail(
        Path,
        ?MODULE,
        #{action => Action, method => Method},
        #{Method => #{tags => ["ECAI Compute and NFTs"], produces => ["application/json"]}}
    ).

init(Req0, #{action := Action, method := Method} = State) ->
    try
        Expected =
            case Method of
                get -> <<"GET">>;
                post -> <<"POST">>
            end,
        case cowboy_req:method(Req0) =:= Expected of
            false ->
                respond(Req0, State, 405, #{ok => false, error => method_not_allowed});
            true ->
                case authenticate(Req0, Method) of
                    {error, Why} ->
                        respond(Req0, State, 401, #{ok => false, error => Why});
                    {ok, Owner} ->
                        case read_body(Req0, Method) of
                            {ok, Body, Req} ->
                                handle(Action, Owner, Body, Req, State);
                            {error, Code, Why, Req} ->
                                respond(Req, State, Code, #{ok => false, error => Why})
                        end
                end
        end
    catch
        exit:{noproc, _} ->
            respond(Req0, State, 503, #{ok => false, error => compute_settings_disabled});
        _:_ ->
            respond(Req0, State, 503, #{ok => false, error => compute_settings_unavailable})
    end.

authenticate(Req, Method) ->
    %% Both reads and writes use a validated explicit bearer when present.
    %% Ambient cookies never authorize writes. Wallet-only sessions cannot
    %% access spending policy, provider connection or mint intents.
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Token/binary>> when
            byte_size(Token) >= 10,
            byte_size(Token) =< 8192
        ->
            actor(damage_auth:resolve_oauth(Token, #{}));
        _ when Method =:= get -> actor(damage_auth:authenticate(Req, #{}));
        _ ->
            {error, explicit_bearer_required}
    end.
actor({ok, #{auth_mode := custodial} = Auth}) ->
    case damage_auth:authenticated_account(Auth) of
        {ok, Owner} when is_binary(Owner), byte_size(Owner) > 0 -> {ok, Owner};
        _ -> {error, authenticated_account_required}
    end;
actor(_) ->
    {error, managed_account_required}.
read_body(Req, get) ->
    {ok, #{}, Req};
read_body(Req0, post) ->
    case cowboy_req:header(<<"content-type">>, Req0, <<>>) of
        <<"application/json", _/binary>> ->
            case cowboy_req:read_body(Req0, #{length => 16384, period => 5000}) of
                {ok, Bytes, Req} when byte_size(Bytes) =< 16384 ->
                    try jsx:decode(Bytes, [return_maps]) of
                        M when is_map(M) -> {ok, M, Req};
                        _ -> {error, 400, json_object_required, Req}
                    catch
                        _:_ -> {error, 400, invalid_json, Req}
                    end;
                {_, _, Req} ->
                    {error, 413, request_too_large, Req}
            end;
        _ ->
            {error, 415, json_required, Req0}
    end.

handle(settings, Owner, _B, Req, State) ->
    result(ecai_compute_settings:snapshot(Owner), Req, State);
handle(sources, Owner, _B, Req, State) ->
    case ecai_index_jobs_srv:list(#{owner => Owner, limit => 100}) of
        {ok, Jobs} ->
            Sources = [
                #{
                    id => maps:get(<<"id">>, J),
                    kind => maps:get(<<"kind">>, maps:get(<<"spec">>, J, #{}), <<>>),
                    state => maps:get(<<"state">>, J, <<>>)
                }
             || J <- Jobs, eligible_source(J, Owner)
            ],
            respond(Req, State, 200, #{ok => true, data => Sources});
        _ ->
            result({error, index_jobs_unavailable}, Req, State)
    end;
handle(policy, Owner, Body, Req, State) ->
    result(ecai_compute_settings:put_policy(Owner, Body), Req, State);
handle(provider, Owner, Body, Req, State) ->
    Name = cowboy_req:binding(provider, Req),
    result(ecai_compute_settings:put_provider(Owner, Name, Body), Req, State);
handle(prepare, Owner, Body, Req, State) ->
    %% Requires an explicit bearer token; no cookie-only mutation allowed.
    %% No key material, IAM privilege or cloud deployment is created here.
    case map_size(Body) of
        0 -> result(ecai_compute_settings:prepare_provider(
                 Owner, cowboy_req:binding(provider, Req)), Req, State);
        _ -> respond(Req, State, 400, #{ok => false, error => unexpected_fields})
    end;
handle(verify, Owner, Body, Req, State) ->
    case map_size(Body) of
        0 -> verify_provider(Owner, cowboy_req:binding(provider, Req), Req, State);
        _ -> respond(Req, State, 400, #{ok => false, error => unexpected_fields})
    end;
handle(quote, Owner, Body, Req, State) ->
    %% Quotes are deterministic upper-bound estimates configured by the node,
    %% not prices claimed by the browser.
    case eligible_source_job(Owner, maps:get(<<"source_job_id">>, Body, <<>>)) of
        ok -> result(ecai_compute_settings:quote(Body), Req, State);
        {error, Error} -> result({error, Error}, Req, State)
    end;
handle(reserve, Owner, Body, Req, State) ->
    Key = cowboy_req:header(<<"idempotency-key">>, Req, undefined),
    %% Only the exact quote the user confirmed may consume their allowance.
    %% Strip the confirmation field before computing / persisting the spec.
    Spec = maps:remove(<<"expected_reserve_cents">>, Body),
    Expected = maps:get(<<"expected_reserve_cents">>, Body, undefined),
    case eligible_source_job(Owner, maps:get(<<"source_job_id">>, Spec, <<>>)) of
        ok ->
            case ecai_compute_settings:quote(Spec) of
                {ok, #{<<"reserve_cents">> := Expected}} when is_integer(Expected) ->
                    result(ecai_compute_settings:reserve(Owner, Key, Spec), Req, State);
                {ok, _} ->
                    result({error, quote_changed_or_missing}, Req, State);
                {error, Error} ->
                    result({error, Error}, Req, State)
            end;
        {error, Error} ->
            result({error, Error}, Req, State)
    end;
handle(cancel, Owner, Body, Req, State) ->
    case map_size(Body) of
        0 ->
            result(
                ecai_compute_settings:cancel_reservation(
                    Owner,
                    cowboy_req:binding(id, Req)
                ),
                Req,
                State
            );
        _ ->
            result({error, unexpected_fields}, Req, State)
    end;
handle(mintable, Owner, _Body, Req, State) ->
    case ecai_index_jobs_srv:list(#{owner => Owner, limit => 100}) of
        {ok, Jobs} ->
            Eligible = [
                #{
                    id => maps:get(<<"id">>, J),
                    label => maps:get(<<"kind">>, maps:get(<<"spec">>, J, #{}), <<>>)
                }
             || J <- Jobs, mintable_job(J, Owner)
            ],
            respond(Req, State, 200, #{ok => true, data => Eligible});
        _ ->
            result({error, index_jobs_unavailable}, Req, State)
    end;
handle(mint, Owner, Body, Req, State) ->
    JobId = maps:get(<<"job_id">>, Body, undefined),
    Recipient = maps:get(<<"recipient">>, Body, undefined),
    Fee = maps:get(<<"fee_cap_cents">>, Body, undefined),
    case maps:keys(Body) of
        _ ->
            case
                allowed_keys(Body, [
                    <<"job_id">>, <<"recipient">>, <<"fee_cap_cents">>, <<"confirm">>
                ]) andalso
                    maps:get(<<"confirm">>, Body, <<>>) =:= <<"queue mint review">> andalso
                    is_binary(JobId) andalso is_binary(Recipient)
            of
                false ->
                    result({error, explicit_mint_confirmation_required}, Req, State);
                true ->
                    case ecai_index_jobs_srv:get(JobId) of
                        {ok, Job} ->
                            case mintable_job(Job, Owner) of
                                false ->
                                    result({error, job_not_owned_or_not_ready}, Req, State);
                                true ->
                                    case ecai_index_jobs_srv:nft_metadata(JobId) of
                                        {ok, Metadata} ->
                                            result(
                                                ecai_compute_settings:request_mint(
                                                    Owner, JobId, Metadata, Recipient, Fee
                                                ),
                                                Req,
                                                State
                                            );
                                        _ ->
                                            result(
                                                {error, artifact_metadata_unavailable}, Req, State
                                            )
                                    end
                            end;
                        _ ->
                            result({error, job_not_found}, Req, State)
                    end
            end
    end.

eligible_source_job(Owner, JobId) when is_binary(JobId), byte_size(JobId) > 0 ->
    case ecai_index_jobs_srv:get(JobId) of
        {ok, Job} ->
            case eligible_source(Job, Owner) of
                true -> ok;
                false -> {error, no_supported_owned_shard_job}
            end;
        _ ->
            {error, source_job_not_found}
    end;
eligible_source_job(_, _) ->
    {error, source_job_not_found}.

eligible_source(Job, Owner) ->
    Spec = maps:get(<<"spec">>, Job, #{}),
    Target = maps:get(<<"target">>, Spec, #{}),
    Kind = maps:get(<<"kind">>, Spec, <<>>),
    %% Remote worker starter supports the isolated shard search adapter only.
    maps:get(<<"owner">>, Spec, undefined) =:= Owner andalso
        maps:get(<<"mode">>, Target, <<>>) =:= <<"shard_search">> andalso
        lists:member(Kind, [<<"wikipedia_jsonl">>, <<"yelp_ndjson">>]).

mintable_job(J, Owner) ->
    Spec = maps:get(<<"spec">>, J, #{}),
    Artifact = maps:get(<<"artifact">>, J, #{}),
    maps:get(<<"owner">>, Spec, undefined) =:= Owner andalso
        maps:get(<<"state">>, J, <<>>) =:= <<"ready_to_mint">> andalso
        is_map(Artifact) andalso maps:get(<<"ready_to_mint">>, Artifact, false) =:= true.
allowed_keys(Map, Allowed) ->
    lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(Map)).

verify_provider(Owner, Name, Req, State) ->
    case ecai_compute_settings:provider(Owner, Name) of
        {ok, P} ->
            Digest = crypto:hash(sha256, term_to_binary(P)),
            case provider_check(Name, P) of
                ok -> result(ecai_compute_settings:mark_verified(Owner, Name, Digest), Req, State);
                {error, Error} -> result({error, Error}, Req, State)
            end;
        Error ->
            result(Error, Req, State)
    end.
provider_check(<<"aws_batch">>, #{<<"role_arn">> := Arn, <<"external_id">> := External}) ->
    %% AssumeRole test: AWS CLI output is discarded, not returned/logged.
    run_probe("aws", [
        "sts",
        "assume-role",
        "--role-arn",
        binary_to_list(Arn),
        "--external-id",
        binary_to_list(External),
        "--role-session-name",
        "ecai-compute-check",
        "--duration-seconds",
        "900",
        "--query",
        "AssumedRoleUser.Arn",
        "--output",
        "text"
    ]);
provider_check(<<"cloud_run">>, #{
    <<"project_id">> := Project,
    <<"region">> := Region,
    <<"job">> := Job
}) ->
    %% Read test only; execution permissions must still be granted by admin.
    run_probe("gcloud", [
        "run",
        "jobs",
        "describe",
        binary_to_list(Job),
        "--project",
        binary_to_list(Project),
        "--region",
        binary_to_list(Region),
        "--format=value(metadata.name)"
    ]);
provider_check(_, _) ->
    {error, invalid_provider}.
run_probe(Executable, Args) ->
    case os:find_executable(Executable) of
        false ->
            {error, provider_cli_not_installed};
        Path ->
            Port = open_port(
                {spawn_executable, Path},
                [binary, exit_status, use_stdio, stderr_to_stdout, {args, Args}]
            ),
            WaitUntil = erlang:monotonic_time(millisecond) + 20000,
            await_probe(Port, WaitUntil)
    end.
await_probe(Port, Deadline) ->
    Remain = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, _Discarded}} -> await_probe(Port, Deadline);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, _}} -> {error, cloud_identity_check_failed}
    after Remain ->
        catch erlang:port_close(Port),
        {error, cloud_identity_check_timeout}
    end.

result({ok, Value}, Req, State) -> respond(Req, State, 200, #{ok => true, data => Value});
result({error, Why}, Req, State) -> respond(Req, State, 409, #{ok => false, error => Why});
result(_, Req, State) -> respond(Req, State, 503, #{ok => false, error => unexpected_result}).
respond(Req0, State, Code, Value) ->
    Req = cowboy_req:reply(
        Code,
        #{
            <<"content-type">> => <<"application/json; charset=utf-8">>,
            <<"cache-control">> => <<"no-store">>,
            <<"x-content-type-options">> => <<"nosniff">>
        },
        jsx:encode(ecai_index_job_codec:externalize(Value)),
        Req0
    ),
    {ok, Req, State}.
