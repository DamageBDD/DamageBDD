%% Narrow, same-origin node-admin API. Mutation identity comes from validating
%% the EXPLICIT bearer token itself, never from a body actor or ambient cookie.
-module(ecai_index_pool_http).
-import(ecai_index_pool_util, [need/1, ensure/2, guarded/1]).
-export([trails/0, init/2]).
trails() -> [
    trail("/ecai/admin/index-pool/status", status, get),
    trail("/ecai/admin/index-pool/nodes", join, post),
    trail("/ecai/admin/index-pool/prepare", prepare, post),
    trail("/ecai/admin/index-pool/channels", channels, post),
    trail("/ecai/admin/index-pool/quote", quote, post),
    trail("/ecai/admin/index-pool/jobs", create, post),
    trail("/ecai/admin/index-pool/jobs/:id/start", start, post),
    trail("/ecai/admin/index-pool/jobs/:id/pause", pause, post),
    trail("/ecai/admin/index-pool/jobs/:id/reconcile", reconcile, post),
    trail("/ecai/admin/index-pool/jobs/:id/refund", refund, post),
    trail("/ecai/admin/index-pool/jobs/:id/refund-pay", refund_pay, post),
    trail("/ecai/admin/index-pool/jobs/:id/search", search, post),
    trail("/ecai/admin/index-pool/jobs/:id/contract", contract, get)
].
trail(Path, Action, Method) -> trails:trail(Path, ?MODULE, #{action => Action, method => Method},
    #{Method => #{tags => ["ECAI funded indexing"], produces => ["application/json"]}}).
init(Req0, #{action := Action, method := Allowed} = State) ->
    try
        Method = cowboy_req:method(Req0),
        Expected = case Allowed of get -> <<"GET">>; post -> <<"POST">> end,
        case Method =:= Expected of
            false -> response(Req0, 405, #{ok => false, error => method_not_allowed}, State);
            true ->
                case authenticate(Req0, Method) of
                    {ok, Actor} ->
                        case read_body(Req0, Method) of
                            {ok, Body, Req} ->
                                Result = guarded(fun() ->
                                    ensure(Action =:= status orelse application:get_env(ecai, index_pool_enabled, false) =:= true, indexing_pool_disabled),
                                    execute(Action, Actor, Body, Req)
                                end),
                                finish(Result, Req, State);
                            {error, Code, Error, Req} -> response(Req, Code, #{ok => false, error => Error}, State)
                        end;
                    {error, Reason} -> response(Req0, 403, #{ok => false, error => Reason}, State)
                end
        end
    catch _:_ -> response(Req0, 503, #{ok => false, error => index_pool_unavailable}, State) end.

authenticate(Req, <<"POST">>) ->
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Token/binary>> when byte_size(Token) >= 10, byte_size(Token) =< 8192 ->
            %% resolve_oauth verifies this token and binds the principal. A fake
            %% header cannot piggyback on a valid cookie session.
            actor(damage_auth:resolve_oauth(Token, #{}));
        _ -> {error, bearer_required}
    end;
authenticate(Req, _) -> actor(damage_auth:authenticate(Req, #{})).
actor({ok, Auth}) ->
    case damage_auth:authenticated_account(Auth) of
        {ok, A} -> case ecai_node_admin:is_node_admin(A) of true -> {ok, A}; false -> {error, node_admin_required} end;
        _ -> {error, authenticated_admin_required}
    end;
actor(_) -> {error, authenticated_admin_required}.
read_body(Req, <<"GET">>) -> {ok, #{}, Req};
read_body(Req0, _) ->
    case cowboy_req:header(<<"content-type">>, Req0, <<>>) of
        <<"application/json", _/binary>> ->
            case cowboy_req:read_body(Req0, #{length => 16384, period => 5000}) of
                {ok, Raw, Req} when byte_size(Raw) =< 16384 ->
                    try jsx:decode(Raw, [return_maps]) of
                        M when is_map(M) -> {ok, M, Req};
                        _ -> {error, 400, json_object_required, Req}
                    catch _:_ -> {error, 400, invalid_json, Req} end;
                {_, _, Req} -> {error, 413, request_too_large, Req}
            end;
        _ -> {error, 415, json_required, Req0}
    end.

execute(status, A, _B, _Req) ->
    Enabled = application:get_env(ecai, index_pool_enabled, false) =:= true,
    Config = application:get_env(ecai, index_rewards_config, #{}),
    Base = #{enabled => Enabled, actor => A, participant_enabled => application:get_env(ecai, index_pool_participant_enabled, false),
        network => maps:get(network, Config, <<"regtest">>), payments_enabled => maps:get(payments_enabled, Config, false),
        refund_node => maps:get(A, maps:get(participants, Config, #{}), null),
        max_budget_sats => maps:get(max_budget_msat, Config, 10000000) div 1000,
        max_fee_sats => maps:get(max_fee_msat, Config, 1000) div 1000},
    case Enabled of
        false -> Base;
        true ->
            D = ecai_index_pool:snapshot(),
            Rewards = ecai_index_rewards:status(),
            Cs = maps:from_list([{maps:get(id, C), C} || C <- maps:get(campaigns, Rewards)]),
            Jobs = [(J#{accounting => maps:get(maps:get(id, J), Cs, null)}) || J <- maps:get(jobs, D)],
            Sources = case ecai_index_jobs_srv:list(#{limit => 100}) of
                {ok, L} -> [source_summary(J) || J <- L, eligible_source(J)];
                _ -> []
            end,
            maps:merge(Base, D#{jobs => Jobs, source_jobs => Sources,
                quarantined => maps:get(quarantined, Rewards, false),
                payment_operation_in_flight => maps:get(cln_operation_in_flight, Rewards, false)})
    end;
execute(quote, A, B, _Req) -> keys(B, quote_keys()), need(ecai_index_pool:quote(A, B));
execute(create, A, B, Req) ->
    keys(B, [<<"quote_hash">>, <<"confirm">> | quote_keys()]),
    Key = cowboy_req:header(<<"idempotency-key">>, Req, <<>>), need(ecai_index_pool:create(A, Key, B));
execute(join, A, B, _) -> keys(B, [<<"node">>]), need(ecai_index_pool:operation(A, join, B));
execute(prepare, A, B, _) -> keys(B, [<<"job_id">>]), need(ecai_index_pool:operation(A, prepare, B));
execute(channels, A, B, _) -> keys(B, []), need(ecai_index_pool:operation(A, channels, B));
execute(Action, A, B, Req) when Action =:= start; Action =:= pause ->
    keys(B, [<<"quote_hash">>, <<"auto_pay">>, <<"confirm">>]),
    need(ecai_index_pool:control(A, cowboy_req:binding(id, Req), Action, B));
execute(Action, A, B, Req) when Action =:= reconcile; Action =:= refund ->
    keys(B, [<<"confirm">>]), need(ecai_index_pool:operation(A, Action, B#{<<"id">> => cowboy_req:binding(id, Req)}));
execute(contract, _A, _B, Req) ->
    D = ecai_index_pool:snapshot(), J = find_job(cowboy_req:binding(id, Req), D),
    C = case ecai_index_rewards:campaign(maps:get(id, J)) of {ok, V} -> V; _ -> null end,
    #{job => J, accounting => C, node_consents => maps:get(peers, D), channel_observations => maps:get(channels, D)};
execute(search, _A, B, Req) ->
    keys(B, [<<"q">>]), J = find_job(cowboy_req:binding(id, Req), ecai_index_pool:snapshot()),
    Q = maps:get(<<"q">>, B), ensure(is_binary(Q) andalso byte_size(Q) > 0 andalso byte_size(Q) =< 2048, invalid_query),
    M = maps:get(manifest, J), need(ecai_index_shards:search(maps:get(path, M), #{name => Q}, 10));
execute(refund_pay, A, B, Req) ->
    keys(B, [<<"payout_id">>, <<"invoice">>, <<"confirm">>]),
    ensure(maps:get(<<"confirm">>, B, <<>>) =:= <<"pay indexing refund">>, confirmation_required),
    Id = cowboy_req:binding(id, Req), J = find_job(Id, ecai_index_pool:snapshot()),
    ensure(maps:get(owner, J) =:= A, job_owner_required),
    C = need(ecai_index_rewards:campaign(Id)), Pid = maps:get(<<"payout_id">>, B),
    Ps = [P || P <- maps:get(payouts, C), maps:get(id, P) =:= Pid, maps:get(role, P) =:= refund],
    ensure(length(Ps) =:= 1, refund_payout_not_found),
    _ = need(ecai_index_rewards:submit_invoice(A, Id, Pid, maps:get(<<"invoice">>, B))),
    need(ecai_index_rewards:pay(A, Id, Pid, <<"pay indexing reward">>)).
quote_keys() -> [<<"plan_id">>, <<"budget_sats">>, <<"nodes">>, <<"verifier_percent">>, <<"fee_sats">>, <<"refund_node">>].
keys(B, Allowed) -> ensure(lists:all(fun(K) -> lists:member(K, Allowed) end, maps:keys(B)), unexpected_fields).
find_job(Id, D) ->
    case [J || J <- maps:get(jobs, D), maps:get(id, J) =:= Id] of [J] -> J; _ -> throw({pool, job_not_found}) end.
eligible_source(J) ->
    Kind = maps:get(<<"kind">>, maps:get(<<"spec">>, J)), State = maps:get(<<"state">>, J),
    lists:member(Kind, [<<"wikipedia_jsonl">>, <<"yelp_ndjson">>, <<"wikimedia_visibility">>]) andalso
    lists:member(State, [<<"paused">>, <<"canceled">>, <<"failed">>, <<"completed">>, <<"ready_to_mint">>, <<"minted">>]).
source_summary(J) -> #{id => maps:get(<<"id">>, J), kind => maps:get(<<"kind">>, maps:get(<<"spec">>, J)), state => maps:get(<<"state">>, J)}.
finish({ok, Data}, Req, #{action := Action} = State) ->
    Code = case lists:member(Action, [join, prepare, create, channels, reconcile, refund]) of true -> 202; false -> 200 end,
    response(Req, Code, #{ok => true, data => Data}, State);
finish({error, R}, Req, State) ->
    Code = case R of node_admin_required -> 403; job_owner_required -> 403;
        job_not_found -> 404; indexing_pool_disabled -> 503; _ -> 409 end,
    response(Req, Code, #{ok => false, error => R}, State).
response(Req, Code, Data, State) ->
    R = cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json; charset=utf-8">>,
        <<"cache-control">> => <<"no-store">>, <<"x-content-type-options">> => <<"nosniff">>},
        jsx:encode(ecai_index_job_codec:externalize(Data)), Req),
    {ok, R, State}.
