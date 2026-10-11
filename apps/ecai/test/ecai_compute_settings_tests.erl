-module(ecai_compute_settings_tests).
-include_lib("eunit/include/eunit.hrl").

settings_and_reservations_test_() ->
    {setup,
     fun setup/0,
     fun cleanup/1,
     fun({_Pid, Path}) ->
         Owner = <<"ak_test_account">>,
         P = #{<<"project_id">> => <<"ecai-test-project">>,
               <<"region">> => <<"australia-southeast1">>,
               <<"job">> => <<"ecai-shard">>,
               <<"bucket">> => <<"ecai-test-bucket">>,
               <<"service_account">> => <<"ecai-index@ecai-test-project.iam.gserviceaccount.com">>},
         Spec = #{<<"provider">> => <<"cloud_run">>, <<"source_job_id">> => <<"source1">>,
                  <<"vcpus">> => 1, <<"memory_mb">> => 2048,
                  <<"max_seconds">> => 600, <<"max_attempts">> => 1},
         {ok, Account0} = ecai_compute_settings:snapshot(Owner),
         ?assertEqual(0, maps:get(<<"monthly_cents">>, maps:get(<<"budget">>, Account0))),
         {ok, #{<<"reserve_cents">> := Cents}} = ecai_compute_settings:quote(Spec),
         %% 1 vCPU * 600 sec + 2 GiB, fixed allowance and a 1.5x buffer.
         %% Prices use integer micro-USD and a cent is 10,000 micro-USD.
         ?assertEqual(3, Cents),
         {ok, Provider} = ecai_compute_settings:put_provider(Owner, <<"cloud_run">>, P),
         ?assertEqual(<<"unverified">>, maps:get(<<"status">>, Provider)),
         %% Spending requires an independent explicit opt-in; zero budgets deny.
         {ok, _} = ecai_compute_settings:put_policy(Owner,
             (policy(Cents, Cents))#{<<"budget">> =>
                 (maps:get(<<"budget">>, policy(Cents, Cents)))#{<<"remote_enabled">> => false}}),
         ?assertEqual({error, remote_indexing_disabled},
              ecai_compute_settings:reserve(Owner, <<"reservation-disabled">>, Spec)),
         {ok, _} = ecai_compute_settings:put_policy(Owner, policy(Cents, Cents)),
         ?assertEqual({error, provider_not_verified},
              ecai_compute_settings:reserve(Owner, <<"reservation-0001">>, Spec)),
         Digest = crypto:hash(sha256, term_to_binary(Provider)),
         {ok, Verified} = ecai_compute_settings:mark_verified(Owner, <<"cloud_run">>, Digest),
         ?assertEqual(<<"identity_verified">>, maps:get(<<"status">>, Verified)),
         ?assertEqual({error, provider_changed_during_verification},
              ecai_compute_settings:mark_verified(Owner, <<"cloud_run">>, Digest)),
         {ok, R1} = ecai_compute_settings:reserve(Owner, <<"reservation-0001">>, Spec),
         {ok, Same} = ecai_compute_settings:reserve(Owner, <<"reservation-0001">>, Spec),
         ?assertEqual(maps:get(<<"id">>, R1), maps:get(<<"id">>, Same)),
         ?assertEqual({error, idempotency_conflict},
              ecai_compute_settings:reserve(Owner, <<"reservation-0001">>,
                  Spec#{<<"max_seconds">> => 1000})),
         ?assertEqual({error, monthly_budget_exceeded},
              ecai_compute_settings:reserve(Owner, <<"reservation-0002">>, Spec)),
         {ok, _} = ecai_compute_settings:cancel_reservation(Owner, maps:get(<<"id">>, R1)),
         {ok, _} = ecai_compute_settings:reserve(Owner, <<"reservation-0002">>, Spec),
         {ok, Account1} = ecai_compute_settings:snapshot(Owner),
         ?assertEqual(Cents, maps:get(<<"reserved_compute_cents">>, Account1)),
         ?assertEqual({error, below_reserved_compute_budget},
              ecai_compute_settings:put_policy(Owner, policy(0, 0))),
         ?assertEqual(0, maps:get(<<"reserved_compute_cents">>,
              element(2, ecai_compute_settings:snapshot(<<"another_owner">>)))),
         Metadata = #{<<"manifest_sha256">> => binary:copy(<<"f">>, 64),
                      <<"schema">> => <<"ecai-index-nft/v2">>},
         Recipient = <<"ak_12345678901234567890123456789012345">>,
         {ok, M1} = ecai_compute_settings:request_mint(Owner, <<"ready_job">>, Metadata,
                                                       Recipient, 2),
         ?assertEqual(<<"awaiting_wallet_signature">>, maps:get(<<"status">>, M1)),
         ?assertEqual({error, mint_request_conflict},
             ecai_compute_settings:request_mint(Owner, <<"ready_job">>, Metadata, Recipient, 1)),
         ?assertEqual({error, mint_budget_exceeded},
             ecai_compute_settings:request_mint(Owner, <<"other_job">>, Metadata, Recipient, 2)),
         %% Restart tests that budgets, reservations and mint intents survive.
         ok = gen_server:stop(whereis(ecai_compute_settings)),
         {ok, _RecoveredPid} = ecai_compute_settings:start_link(#{path => Path}),
         {ok, Recovered} = ecai_compute_settings:snapshot(Owner),
         ?assertEqual(Cents, maps:get(<<"reserved_compute_cents">>, Recovered)),
         ?assertEqual(2, maps:get(<<"reserved_mint_cents">>, Recovered)),
         ?assertEqual({error, monthly_budget_exceeded},
             ecai_compute_settings:reserve(Owner, <<"after-restart-key">>, Spec))
     end}.

policy(Compute, Job) ->
    #{<<"budget">> => #{<<"remote_enabled">> => true,
                        <<"monthly_cents">> => Compute, <<"per_job_cents">> => Job,
                        <<"mint_monthly_cents">> => 2},
      <<"mint">> => #{<<"enabled">> => true, <<"recipient">> =>
                            <<"ak_12345678901234567890123456789012345">>,
                       <<"chain">> => <<"aeternity">>}}.

setup() ->
    Path = filename:join("/tmp", "ecai-compute-test-" ++
        integer_to_list(erlang:unique_integer([monotonic, positive])) ++ ".dets"),
    application:set_env(ecai, compute_price_upper_bounds,
        #{<<"cloud_run">> => #{vcpu_micro_usd_sec => 18,
                               gib_micro_usd_sec => 2, fixed_micro_usd => 1000,
                               safety_basis_points => 15000}}),
    {ok, Pid} = ecai_compute_settings:start_link(#{path => Path}),
    {Pid, Path}.
cleanup({_Pid, Path}) ->
    case whereis(ecai_compute_settings) of
        undefined -> ok;
        Current -> gen_server:stop(Current)
    end,
    file:delete(Path),
    application:unset_env(ecai, compute_price_upper_bounds).
