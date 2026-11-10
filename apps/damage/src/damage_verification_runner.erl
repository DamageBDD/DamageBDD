%% Adapter, not a second BDD engine: retain DamageBDD's context freezing,
%% dry-run costing, balance check, execution, settlement and report publication.
-module(damage_verification_runner).
-export([run/5, result/2, ensure_budget/2, ensure_context/2, revision/0, principal/1]).
run(Mode,Spec,Auth,Sink,JobId) ->
    Source=maps:get(source,Spec),
    %% Authentication credentials and private keys never enter job/report context.
    P=principal(Auth),
    Runtime=(maps:get(inputs,Spec,#{}))#{feature=>Source,stream=>nostream,concurrency=>1},
    Fmt={verification,#{sink=>Sink,job_id=>JobId,phase=>Mode}},
    Opts0=[{formatters,[Fmt]}, {verification_source_sha256,maps:get(sha256,Spec)},
           {verification_job_id,JobId},
           {verification_context_fingerprint,maps:get(context_fingerprint,Spec)}],
    Opts=case Mode of
        preview -> [{dry_run,true}|Opts0];
        execute -> [{verification_max_cost,maps:get(cost,Spec)}|Opts0]
    end,
    try damage_http:execute_bdd(Runtime,P,#{},Opts) of
        {Code,Body} when is_integer(Code),is_map(Body) -> result(Mode,{Code,Body});
        _ -> #{state=>error,error=>runner_protocol_error}
    catch
        throw:verification_budget_exceeded -> #{state=>blocked,error=>estimate_changed};
        throw:verification_context_changed -> #{state=>blocked,error=>context_changed};
        _:_ -> #{state=>indeterminate,error=>runner_failed}
    end.
principal(Auth) -> maps:with([public_key,authenticated,auth_mode,node_admin,tax_admin],Auth).
ensure_budget(Cost,Opts) ->
    case proplists:get_value(verification_max_cost,Opts,undefined) of
        undefined -> ok;
        Max when is_number(Max),Max>=0,is_number(Cost),Cost>=0,Cost=<Max -> ok;
        _ -> throw(verification_budget_exceeded)
    end.
ensure_context(Context,Opts) ->
    case proplists:get_value(verification_context_fingerprint,Opts,undefined) of
        undefined -> ok;
        Expected ->
            Actual=damage_verification_catalog:fingerprint(#{proofs=>maps:get(context_proofs,Context,#{})}),
            case Expected=:=Actual of true->ok;false->throw(verification_context_changed) end
    end.
result(Mode,{Code,Body}) ->
    %% Never forward raw result/context, failing-step interpolation, exceptions,
    %% report paths, IPFS URLs or arbitrary diagnostics into this API.
    Public=maps:filter(fun(_,V)->is_binary(V) orelse is_number(V) orelse is_boolean(V) end,
        maps:with([run_id,report_hash,feature_hash,context_ipfs_hash,cost,spend,
                   tx_hash,settlement_status,retry_feature,cost_hits,cost_damage,cost_sats],Body)),
    Status=maps:get(status,Body,undefined),
    Good=Code=:=200 andalso Status=:=<<"ok">>,
    case {Mode,Good,Status,maps:get(cost,Body,undefined)} of
        {preview,true,_,C} when is_number(C),C>=0 -> Public#{state=>ready,cost=>C};
        {preview,_,_,_} -> Public#{state=>blocked,error=>preview_failed};
        {execute,_,<<"pending">>,_} -> Public#{state=>pending,error=>settlement_pending,retry_feature=>false};
        {execute,true,_,_} ->
            case maps:get(report_hash,Public,<<>>) of
                R when is_binary(R),byte_size(R)>0 -> Public#{state=>passed};
                _ -> Public#{state=>indeterminate,error=>report_unavailable,retry_feature=>false}
            end;
        {execute,false,_,_} when Code=:=400 -> Public#{state=>failed,error=>verification_failed};
        _ -> Public#{state=>indeterminate,error=>execution_unconfirmed,retry_feature=>false}
    end.
revision() ->
    %% Bind a quote to the loaded step catalog plus relevant execution/auth code.
    Modules=[damage,damage_http,damage_context,damage_verification_runner,
        damage_verification_catalog,steps_verification,damage_verification_checks,
        damage_node_security,
        damage_nwc_payment_policy,damage_nwc_wallet,damage_browser_auth,
        damage_wallet_policy,damage_auth,steps_utils],
    damage_verification_catalog:sha256(term_to_binary(
        [{M,md5(M)}||M<-Modules],[deterministic])).
md5(M) -> try M:module_info(md5) catch _:_ -> unavailable end.
