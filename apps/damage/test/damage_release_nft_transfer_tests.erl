-module(damage_release_nft_transfer_tests).
-include_lib("eunit/include/eunit.hrl").

tracked_outcomes_preserved_test() ->
    lists:foreach(fun(Status) ->
        Outcome = #{status => Status, tx_hash => <<"th_known">>},
        ?assertEqual({ok, Outcome}, damage_release_nft:transfer_call_result({ok, Outcome}))
    end, [confirmed, submitted, submission_unknown]).

rejection_preserved_with_hash_test() ->
    R = #{status => rejected, stage => execution, reason => contract_reverted, tx_hash => <<"th_known">>},
    ?assertEqual({error, {release_transfer_rejected, R}},
        damage_release_nft:transfer_call_result({error, R})).

unknown_process_outcome_preserved_test() ->
    ?assertEqual({error, {release_transfer_failed, transfer_outcome_unknown}},
        damage_release_nft:transfer_call_result({error, transfer_outcome_unknown})).

operator_bad_keypair_error_compatibility_test() ->
    ?assertEqual({error, invalid_release_operator_keypair},
        damage_release_nft:operator_transfer(#{}, 42, <<"ak_unused">>)),
    ?assertEqual({error, invalid_release_signing_keypair},
        damage_release_nft:transfer(#{}, 42, <<"ak_unused">>)).

invalid_token_rejected_before_key_or_chain_access_test() ->
    ?assertEqual({error, invalid_release_token},
        damage_release_nft:transfer(#{}, 0, <<"ak_unused">>)),
    ?assertEqual({error, invalid_release_token},
        damage_release_nft:prepare_transfer(<<"ak_unused">>, -1, <<"ak_unused">>)).

invalid_ae_signing_key_maps_to_stable_release_error_test() ->
    ?assertEqual({error, invalid_release_signing_keypair},
        damage_release_nft:transfer_call_result({error, invalid_signing_keypair})).

short_signing_key_is_rejected_before_chain_access_test() ->
    KP = #{public_key => <<"ak_unused">>, private_key => <<0:256>>},
    ?assertEqual({error, invalid_release_signing_keypair},
        damage_release_nft:transfer(KP, 42, <<"ak_unused">>)),
    ?assertEqual({error, invalid_release_operator_keypair},
        damage_release_nft:operator_transfer(KP, 42, <<"ak_unused">>)).

submission_diagnostics_survive_nft_adapter_test() ->
    O = #{status => submission_unknown, tx_hash => <<"th_local">>,
          submission => #{stage => submission, status => node_rejected,
                          error_code => <<"nonce_too_low">>, http_status => 400}},
    ?assertEqual({ok, O}, damage_release_nft:transfer_call_result({ok, O})).
