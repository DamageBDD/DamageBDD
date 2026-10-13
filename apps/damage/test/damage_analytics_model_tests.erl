-module(damage_analytics_model_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CID_A, <<"QmdF4hVR9nmJjxkqfr3YpD3Bre2xw9yg1ApnLDk1GLxfQf">>).
-define(CID_B, <<"QmYwAPJzv5CZsnAzt8auVZRnGi9hM52LRoPhS6cH8LQx6a">>).
-define(ACCOUNT, <<"ak_11111111111111111111111111111111111111111111111111">>).
-define(NODE, <<"ak_22222222222222222222222222222222222222222222222222">>).
-define(TOKEN, <<"ct_33333333333333333333333333333333333333333333333333">>).

local_run_normalisation_test() ->
    Run0 = #{
        run_id => <<"run-1">>,
        report_hash => ?CID_A,
        feature_hash => ?CID_B,
        public_key => ?ACCOUNT,
        node_public_key => ?NODE,
        status => <<"passed">>,
        result => <<"success">>,
        feature_title => <<"Checkout API">>,
        tags => [<<"@api">>, <<"@regression">>],
        start_time => 1760000000.125,
        completed_at => 1760000002,
        execution_time => 1.875
    },
    {ok, Run} = damage_analytics_model:normalize_local_run(Run0),
    ?assertEqual(passed, maps:get(status, Run)),
    ?assertEqual(?CID_A, maps:get(report_cid, Run)),
    ?assertEqual(?ACCOUNT, maps:get(account, Run)),
    ?assertEqual(1875, maps:get(duration_ms, Run)),
    ?assertEqual(1760000000125, maps:get(created_ms, Run)),
    ?assertEqual([<<"@api">>, <<"@regression">>], maps:get(tags, Run)).

time_units_test() ->
    ?assertEqual(1760000000000, damage_analytics_model:time_ms(1760000000)),
    ?assertEqual(1760000000123, damage_analytics_model:time_ms(1760000000123)),
    ?assertEqual(1760000000123, damage_analytics_model:time_ms(1760000000123000)).

chain_spend_decoded_arguments_test() ->
    Tx = #{
        <<"hash">> => <<"th_44444444444444444444444444444444444444444444444444">>,
        <<"micro_time">> => 1760000000123000,
        <<"tx">> => #{
            <<"type">> => <<"ContractCallTx">>,
            <<"contract_id">> => ?TOKEN,
            <<"function">> => <<"spend">>,
            <<"caller_id">> => ?ACCOUNT,
            <<"arguments">> => [
                #{<<"value">> => ?NODE},
                #{<<"value">> => <<"1000">>},
                #{<<"value">> => ?CID_B},
                #{<<"value">> => ?CID_A}
            ]
        }
    },
    {ok, Run} = damage_analytics_model:normalize_chain_spend(Tx, ?TOKEN, true),
    ?assertEqual(?CID_A, maps:get(report_cid, Run)),
    ?assertEqual(?CID_B, maps:get(feature_cid, Run)),
    ?assertEqual(?ACCOUNT, maps:get(account, Run)),
    ?assertEqual(?NODE, maps:get(node, Run)),
    ?assertEqual(unknown, maps:get(status, Run)),
    ?assertEqual(chain_confirmed, maps:get(settlement_status, Run)),
    ?assertEqual(1760000000123, maps:get(created_ms, Run)).

meta_enrichment_preserves_chain_identity_test() ->
    Chain = #{
        report_cid => ?CID_A,
        feature_cid => ?CID_B,
        account => ?ACCOUNT,
        node => ?NODE,
        tx_hash => <<"th_44444444444444444444444444444444444444444444444444">>,
        status => unknown,
        created_ms => 1760000000000,
        completed_ms => 1760000000000,
        duration_ms => 0,
        evidence => #{chain_confirmed => true, report_meta => false}
    },
    OtherAccount = <<"ak_55555555555555555555555555555555555555555555555555">>,
    Meta = #{
        <<"status">> => <<"failed">>,
        <<"public_key">> => OtherAccount,
        <<"feature_title">> => <<"Checkout API">>,
        <<"result">> => <<"status mismatch">>,
        <<"completed_at">> => 1760000002,
        <<"execution_time_hires">> => 2.0
    },
    Run = damage_analytics_model:enrich_meta(Chain, Meta),
    ?assertEqual(?ACCOUNT, maps:get(account, Run)),
    ?assertEqual(OtherAccount, maps:get(reported_account, Run)),
    ?assertEqual(true, maps:get(account_mismatch, Run)),
    ?assertEqual(failed, maps:get(status, Run)),
    ?assertEqual(2000, maps:get(duration_ms, Run)).

merge_keeps_known_status_and_adds_chain_evidence_test() ->
    Old = #{
        report_cid => ?CID_A,
        feature_cid => ?CID_B,
        account => ?ACCOUNT,
        status => passed,
        created_ms => 1760000000000,
        completed_ms => 1760000001000,
        duration_ms => 1000,
        tx_hash => <<>>,
        evidence => #{report_meta => true}
    },
    New = #{
        report_cid => ?CID_A,
        feature_cid => ?CID_B,
        account => ?ACCOUNT,
        status => unknown,
        created_ms => 1760000000000,
        completed_ms => 1760000000000,
        duration_ms => 0,
        tx_hash => <<"th_chain">>,
        evidence => #{chain_confirmed => true}
    },
    Run = damage_analytics_model:merge_run(Old, New),
    ?assertEqual(passed, maps:get(status, Run)),
    ?assertEqual(1000, maps:get(duration_ms, Run)),
    ?assertEqual(<<"th_chain">>, maps:get(tx_hash, Run)),
    Evidence = maps:get(evidence, Run),
    ?assertEqual(true, maps:get(report_meta, Evidence)),
    ?assertEqual(true, maps:get(chain_confirmed, Evidence)).

paying_for_keeps_inner_account_separate_from_payer_test() ->
    Payer = <<"ak_66666666666666666666666666666666666666666666666666">>,
    Tx = #{
        <<"hash">> => <<"th_payfor">>,
        <<"tx">> => #{
            <<"type">> => <<"PayingForTx">>,
            <<"payer_id">> => Payer,
            <<"tx">> => #{
                <<"tx">> => #{
                    <<"type">> => <<"ContractCallTx">>,
                    <<"contract_id">> => ?TOKEN,
                    <<"function">> => <<"spend">>,
                    <<"caller_id">> => ?ACCOUNT,
                    <<"arguments">> => [
                        #{<<"value">> => ?NODE},
                        #{<<"value">> => <<"1000">>},
                        #{<<"value">> => ?CID_B},
                        #{<<"value">> => ?CID_A}
                    ]
                }
            }
        }
    },
    {ok, Run} = damage_analytics_model:normalize_chain_spend(Tx, ?TOKEN, false),
    ?assertEqual(?ACCOUNT, maps:get(account, Run)),
    ?assertEqual(Payer, maps:get(payer, Run)),
    ?assertEqual(true, maps:get(paying_for, Run)).

failure_signature_is_stable_test() ->
    Run = #{
        status => failed,
        feature_cid => ?CID_B,
        feature_title => <<"Checkout API">>,
        result_summary => <<"HTTP 500">>
    },
    A = damage_analytics_model:failure_signature(Run),
    B = damage_analytics_model:failure_signature(Run),
    ?assertEqual(A, B),
    ?assertEqual(16, byte_size(A)).

legacy_report_evidence_is_publicly_visible_test() ->
    Run = #{
        report_cid => ?CID_A,
        feature_cid => ?CID_B,
        account => ?ACCOUNT,
        status => passed,
        created_ms => 1760000000000,
        completed_ms => 1760000001000,
        duration_ms => 0,
        evidence => #{legacy_report => true}
    },
    Public = damage_analytics_model:public_run(Run),
    ?assertEqual(true, maps:get(evidence_loaded, Public)).
