%% Concrete probes; assertions use the existing production policy/session code.
%% Synthetic rehearsals are NOT a statement about production credential revocation,
%% GitHub permissions, real Lightning payment settlement, or available reserves.
-module(damage_verification_checks).
-export([bunker_health/0,bunker_signing/0,session_revocation/0,privilege_boundary/0,
         lightning_connection/0,lightning_policy/2]).
bunker_health() ->
    S=damage_nsecbunker_handoff_checks:snapshot(),
    Checks=damage_nsecbunker_handoff_checks:assess(S),
    #{ok=>all_passed(Checks),fingerprint=>damage_nsecbunker_handoff_checks:fingerprint(S),
      checks=>[maps:with([id,status],C)||C<-Checks]}.
bunker_signing() ->
    %% Use the existing controller lock and bounded, audit-correlated real probe.
    %% No restart, rekey, client provisioning, pending-secret access or publication.
    Before=damage_nsecbunker_handoff:status(),
    OldHash=maps:get(sha256,maps:get(verify,maps:get(evidence,Before,#{}),#{}),undefined),
    Started=erlang:system_time(second),
    case damage_nsecbunker_handoff:start(verify) of
        {ok,_} -> wait_bunker(erlang:monotonic_time(millisecond)+1250000,Started,OldHash);
        {error,_} -> error(bunker_busy_or_unavailable)
    end.
wait_bunker(Deadline,Started,OldHash) ->
    S=damage_nsecbunker_handoff:status(),
    case maps:get(busy,S,true) of
        true ->
            case erlang:monotonic_time(millisecond)<Deadline of
                true -> receive after 250 -> wait_bunker(Deadline,Started,OldHash) end;
                false -> error(bunker_verification_timeout)
            end;
        false ->
            R=maps:get(verify,maps:get(evidence,S,#{}),#{}),
            Fresh=maps:get(action,R,undefined)=:=verify andalso
                maps:get(started_at,R,0)>=Started andalso maps:get(sha256,R,undefined)=/=OldHash,
            NoError=lists:member(maps:get(last_error,S,undefined),[undefined,null]),
            #{ok=>Fresh andalso NoError andalso maps:get(status,R,not_checked)=:=passed,
              report_sha256=>case Fresh of true->maps:get(sha256,R,<<>>);false-><<>> end}
    end.
all_passed(Cs) -> Cs=/=[] andalso lists:all(fun(C)->maps:get(status,C,failed)=:=passed end,Cs).
session_revocation() ->
    %% The real callback implementation, isolated state, positive control first.
    %% Tokens remain local to this call and never enter BDD context or formatters.
    T=crypto:strong_rand_bytes(32),U=crypto:strong_rand_bytes(32),
    Session=#{address=><<"synthetic-fixture">>,mode=>custodial,
              expires_at=>erlang:system_time(second)+60,
              until=>erlang:monotonic_time(millisecond)+60000},
    S=#{sessions=>#{crypto:hash(sha256,T)=>Session,crypto:hash(sha256,U)=>Session},
        challenges=>#{},attempts=>#{}},
    {reply,Before,S1}=damage_browser_auth:handle_call({lookup,T},undefined,S),
    {reply,ok,S2}=damage_browser_auth:handle_call({revoke,T},undefined,S1),
    {reply,After,S3}=damage_browser_auth:handle_call({lookup,T},undefined,S2),
    {reply,Control,_}=damage_browser_auth:handle_call({lookup,U},undefined,S3),
    #{baseline=>is_ok(Before),revoked=>After=:={error,invalid_session},
      unrelated_session_valid=>is_ok(Control),scope=>synthetic_session_store}.
privilege_boundary() ->
    %% Exercise deployed wallet-session policy. This is not a GitHub/CI audit.
    Paths=[<<"/execute">>,<<"/api/admin/bunker">>,<<"/api/verification/run">>,
           <<"/api/nwc/mint">>,<<"/api/nwc/revoke">>,<<"/api/releases/nfts/1/transfer">>],
    Denied=lists:all(fun(P)->not damage_wallet_policy:allowed(<<"POST">>,P,wallet) end,Paths),
    Positive=damage_wallet_policy:allowed(<<"GET">>,<<"/accounts/session">>,wallet),
    Fake= <<"synthetic-",(binary:encode_hex(crypto:strong_rand_bytes(16)))/binary>>,
    NotAdmin=not steps_utils:has_role(#{public_key=>Fake,node_admin=>true},node_admin),
    #{denied=>Denied,positive_control=>Positive,forged_admin_denied=>NotAdmin,
      scope=>wallet_policy_not_ci_publish_permissions}.
lightning_connection() ->
    case damage_cln:getinfo() of
        {ok,M} when is_map(M) -> lightning_info(M);
        M when is_map(M) -> lightning_info(M);
        _ -> error(lightning_unavailable)
    end.
lightning_info(M) ->
    Network=maps:get(<<"network">>,M,maps:get(network,M,undefined)),
    Id=maps:get(<<"id">>,M,maps:get(id,M,undefined)),
    true=is_binary(Id) andalso byte_size(Id)=:=66,
    true=lists:member(Network,[<<"bitcoin">>,<<"testnet">>,<<"regtest">>,<<"signet">>,<<"testnet4">>]),
    #{ok=>true,network=>Network,scope=>connectivity_only}.
lightning_policy(Single0,Total0) ->
    Single=positive(Single0),Total=positive(Total0),true=Total>=Single,
    P=#{max_single_msat=>Single,max_total_msat=>Total,spent_msat=>0,
        revoked=>false,expires_height=>100},
    Check=fun(P0,A,H)->damage_nwc_payment_policy:amount(P0,A,H) end,
    #{within_budget=>Check(P,Single,100)=:=ok,
      single_limit=>code(Check(P,Single+1,100))=:=<<"QUOTA_EXCEEDED">>,
      total_limit=>code(Check(P#{spent_msat=>Total},1,100))=:=<<"QUOTA_EXCEEDED">>,
      revoked=>code(Check(P#{revoked=>true},1,100))=:=<<"REVOKED">>,
      expired=>code(Check(P,1,101))=:=<<"EXPIRED">>,
      invalid_amount=>code(Check(P,0,100))=:=<<"INVALID_AMOUNT">>,
      insufficient_balance=>code(damage_nwc_payment_policy:balance({ok,0},1))=:=<<"INSUFFICIENT_BALANCE">>,
      scope=>synthetic_policy_no_payment}.
positive(B) when is_binary(B) -> positive(binary_to_list(B));
positive(L) when is_list(L) ->
    true=re:run(L,"^[0-9]{1,15}$",[{capture,none}])=:=match,positive(list_to_integer(L));
positive(N) when is_integer(N),N>0,N=<1000000000000000 -> N.
is_ok({ok,_})->true;is_ok(_)->false.
code({error,C,_})->C;code(_)->ok.
