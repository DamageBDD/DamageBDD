-module(damage_tax_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TENANT, <<"ak_test_account">>).
-define(HOUR, 1759320000).
-define(BTC_MSAT, 100000000000).

unpaid_invoice_ignored_test() ->
    ?assertEqual(skip, damage_tax_event:from_cln_invoice(?TENANT,
        #{status => unpaid, amount_msat => 1000, payment_hash => <<"hash">>})).

paid_invoice_not_auto_income_test() ->
    Raw = #{status => paid, amount_received_msat => ?BTC_MSAT,
            payment_hash => <<"paid-hash">>, paid_at => ?HOUR + 20,
            label => <<"customer-1">>},
    {ok, [E]} = damage_tax_event:from_cln_invoice(?TENANT, Raw),
    ?assertEqual(<<"review">>, maps:get(<<"default_classification">>, E)),
    ?assertEqual(?BTC_MSAT, maps:get(<<"amount_atomic">>, E)),
    ?assertEqual(<<"in">>, maps:get(<<"direction">>, E)).

cln_outgoing_fee_not_double_counted_test() ->
    Raw = #{status => complete, payment_hash => <<"pay-hash">>,
            amount_msat => 100000, amount_sent_msat => 102500,
            completed_at => ?HOUR + 10, groupid => 1},
    {ok, [Pay, Fee]} = damage_tax_event:from_cln_payment(?TENANT, Raw),
    ?assertEqual(100000, maps:get(<<"amount_atomic">>, Pay)),
    ?assertEqual(2500, maps:get(<<"amount_atomic">>, Fee)),
    ?assertEqual(<<"routing_fee">>, maps:get(<<"kind">>, Fee)),
    ?assertNotEqual(maps:get(<<"id">>, Pay), maps:get(<<"id">>, Fee)).

incomplete_settled_invoice_fails_closed_test() ->
    ?assertMatch({error, {incomplete_paid_invoice, _}},
        damage_tax_event:from_cln_invoice(?TENANT,
            #{status => paid, amount_received_msat => 1000, payment_hash => <<"h">>})).

cln_witness_rejects_preimage_in_report_test() ->
    Raw = #{status => complete, payment_hash => <<"h">>,
            amount_msat => 100, amount_sent_msat => 105,
            completed_at => ?HOUR, payment_preimage => <<"SECRET_MUST_NOT_EXPORT">>,
            bolt11 => <<"SECRET_INVOICE">>},
    {ok, [{_E, Witness}, {_Fee, _}]} =
        damage_tax_cln:collect_from(?TENANT, [], [Raw]),
    ?assertEqual(nomatch, binary:match(Witness, <<"SECRET_MUST_NOT_EXPORT">>)),
    ?assertEqual(nomatch, binary:match(Witness, <<"SECRET_INVOICE">>)).

quote_price_one_btc_test() ->
    Body = quote_fixture(),
    {ok, Q} = damage_tax_prices:parse_cryptocompare(Body, <<"BTC">>, ?HOUR + 23),
    {ok, [E]} = damage_tax_event:from_cln_invoice(?TENANT,
        #{status => paid, amount_received_msat => ?BTC_MSAT,
          payment_hash => <<"pay1">>, paid_at => ?HOUR + 23}),
    ?assertEqual(ok, damage_tax_prices:valid_quote(E, Q)),
    ?assertEqual({ok, 10000000}, damage_tax_prices:aud_cents(E, Q)),
    ?assertEqual(?HOUR, maps:get(<<"at">>, Q)).

quote_cannot_use_wrong_hour_test() ->
    {ok, Q} = damage_tax_prices:parse_cryptocompare(quote_fixture(),
                                                    <<"BTC">>, ?HOUR),
    {ok, [E]} = damage_tax_event:from_cln_invoice(?TENANT,
        #{status => paid, amount_received_msat => ?BTC_MSAT,
          payment_hash => <<"pay1">>, paid_at => ?HOUR + 3601}),
    ?assertMatch({error, _}, damage_tax_prices:valid_quote(E, Q)).

fy_standard_time_boundary_test() ->
    {Start, End} = damage_tax_report:fy_bounds(2026, 600),
    ?assertEqual(1751292000, Start),
    ?assertEqual(1782828000, End).

canonical_key_order_stable_test() ->
    A = #{<<"a">> => 1, <<"b">> => 2},
    B = #{<<"b">> => 2, <<"a">> => 1},
    ?assertEqual(damage_tax_canonical:commitment(A),
                 damage_tax_canonical:commitment(B)).

chain_requires_confirmation_evidence_test() ->
    Base = #{chain => <<"bitcoin">>, tx_hash => <<"tx-test">>,
             confirmed_at => ?HOUR, asset => <<"BTC">>,
             amount_atomic => 1000, scale => ?BTC_MSAT,
             direction => in},
    ?assertEqual({error, incomplete_chain_event},
                 damage_tax_event:from_chain(?TENANT, Base)),
    Confirmed = Base#{block_hash => <<"block-test">>, block_height => 900001,
                      confirmations => 6},
    {ok, [E]} = damage_tax_event:from_chain(?TENANT, Confirmed),
    ?assertEqual(6, maps:get(<<"confirmations">>,
                              maps:get(<<"metadata">>, E))).

cln_group_part_ids_are_distinct_test() ->
    Base = #{status => complete, payment_hash => <<"pay-hash">>,
             amount_msat => 1000, amount_sent_msat => 1001,
             completed_at => ?HOUR + 10, groupid => 1},
    {ok, [A, _]} = damage_tax_event:from_cln_payment(?TENANT,
                                                     Base#{partid => 1}),
    {ok, [B, _]} = damage_tax_event:from_cln_payment(?TENANT,
                                                     Base#{partid => 2}),
    ?assertNotEqual(maps:get(<<"id">>, A), maps:get(<<"id">>, B)).

report_rejects_mixed_tenants_test() ->
    E = witness_event(),
    Other = E#{<<"tenant">> => <<"ak_other_business">>},
    ?assertEqual({error, mixed_tax_tenants},
                 damage_tax_report:build(2026, 600, [E, Other], #{}, #{})).

cln_ingestion_requires_explicit_owner_test() ->
    Previous = application:get_env(damage, tax_cln_owner),
    try
        ok = application:set_env(damage, tax_cln_owner, <<"ak_another">>),
        ?assertEqual({error, tax_cln_owner_not_configured_or_mismatched},
                     damage_tax:ingest_cln(?TENANT))
    after
        case Previous of
            {ok, Original} -> application:set_env(damage, tax_cln_owner, Original);
            undefined -> application:unset_env(damage, tax_cln_owner)
        end
    end.

nwc_allocation_is_non_tax_default_test() ->
    {ok, [E]} = damage_tax_event:from_nwc(?TENANT,
        #{ledger_ct => <<"ct_test">>, ref => <<"alloc1">>,
          at => ?HOUR, amount_msat => 1000, direction => in}),
    ?assertEqual(<<"non_tax_event">>, maps:get(<<"default_classification">>, E)).

report_requires_classification_test() ->
    E = witness_event(),
    {ok, R} = damage_tax_report:build(2026, 600, [E], #{}, #{}),
    ?assertEqual(false, maps:get(<<"attestable">>, R)),
    [Reason] = maps:get(<<"review_required">>, maps:get(<<"manifest">>, R)),
    ?assert(lists:member(<<"unclassified_tax_treatment">>,
                         maps:get(<<"reasons">>, Reason))).

report_reviewed_and_archived_quote_test() ->
    E = witness_event(),
    {ok, Q0} = damage_tax_prices:parse_cryptocompare(
                 quote_fixture(), <<"BTC">>, ?HOUR),
    Sha = maps:get(<<"body_sha256">>, Q0),
    Q = Q0#{<<"archive_sha256">> => Sha},
    Id = maps:get(<<"id">>, E),
    Decision = #{<<"category">> => <<"ordinary_income">>,
                 <<"approved">> => true, <<"reviewer">> => <<"CPA-01">>},
    {ok, R} = damage_tax_report:build(2026, 600, [E],
                     #{damage_tax_prices:quote_key(E) => Q},
                     #{Id => Decision}),
    ?assertEqual(true, maps:get(<<"attestable">>, R)),
    Manifest = maps:get(<<"manifest">>, R),
    ?assertEqual(10000000,
       maps:get(<<"ordinary_income_cents">>, maps:get(<<"summary">>, Manifest))),
    ?assertEqual(damage_tax_canonical:commitment(Manifest),
                 maps:get(<<"manifest_sha256">>, R)).

income_direction_conflict_blocks_attestation_test() ->
    {ok, [E0, _Fee]} = damage_tax_event:from_cln_payment(?TENANT,
        #{status => complete, payment_hash => <<"out-1">>,
          amount_msat => ?BTC_MSAT, amount_sent_msat => ?BTC_MSAT + 1000,
          completed_at => ?HOUR + 10}),
    E = E0#{<<"snapshot_sha256">> =>
        damage_tax_canonical:sha256_hex(<<"outgoing-snapshot">>)},
    Id = maps:get(<<"id">>, E),
    {ok, Q0} = damage_tax_prices:parse_cryptocompare(
        quote_fixture(), <<"BTC">>, ?HOUR),
    Sha = maps:get(<<"body_sha256">>, Q0),
    {ok, R} = damage_tax_report:build(2026, 600, [E],
        #{Id => Q0#{<<"archive_sha256">> => Sha}},
        #{Id => #{<<"category">> => <<"ordinary_income">>,
                  <<"approved">> => true, <<"reviewer">> => <<"CPA-01">>}}),
    ?assertEqual(false, maps:get(<<"attestable">>, R)),
    [Row] = maps:get(<<"entries">>, maps:get(<<"manifest">>, R)),
    ?assert(lists:member(<<"income_direction_conflict_requires_adjustment">>,
                         maps:get(<<"review_reasons">>, Row))).

report_disallow_unreviewed_cgt_lot_test() ->
    E = witness_event(),
    {ok, Q0} = damage_tax_prices:parse_cryptocompare(
                 quote_fixture(), <<"BTC">>, ?HOUR),
    Sha = maps:get(<<"body_sha256">>, Q0),
    Q = Q0#{<<"archive_sha256">> => Sha},
    Id = maps:get(<<"id">>, E),
    {ok, R} = damage_tax_report:build(2026, 600, [E], #{Id => Q},
        #{Id => #{<<"category">> => <<"cgt_disposal">>,
                  <<"approved">> => true, <<"reviewer">> => <<"CPA-01">>}}),
    ?assertEqual(false, maps:get(<<"attestable">>, R)),
    [Row] = maps:get(<<"entries">>, maps:get(<<"manifest">>, R)),
    ?assertEqual(null, maps:get(<<"cgt_raw_gain_loss_cents">>, Row)).


indirect_historical_price_requires_review_test() ->
    Raw = binary:replace(quote_fixture(), <<"direct">>, <<"multiply">>),
    {ok, Q} = damage_tax_prices:parse_cryptocompare(Raw, <<"BTC">>, ?HOUR),
    ?assertEqual(true, maps:get(<<"review_required">>, Q)),
    E = witness_event(),
    Id = maps:get(<<"id">>, E),
    Sha = maps:get(<<"body_sha256">>, Q),
    {ok, R} = damage_tax_report:build(2026, 600, [E],
        #{Id => Q#{<<"archive_sha256">> => Sha}},
        #{Id => #{<<"category">> => <<"ordinary_income">>,
                  <<"reviewer">> => <<"CPA-01">>, <<"approved">> => true}}),
    ?assertEqual(false, maps:get(<<"attestable">>, R)).

nwc_cannot_be_reclassified_as_new_business_income_test() ->
    {ok, [E]} = damage_tax_event:from_nwc(?TENANT,
        #{ledger_ct => <<"ct_test">>, ref => <<"alloc2">>,
          at => ?HOUR, amount_msat => 1000, direction => in}),
    E2 = E#{<<"snapshot_sha256">> =>
        damage_tax_canonical:sha256_hex(<<"allocation-snapshot">>)},
    Id = maps:get(<<"id">>, E2),
    {ok, R} = damage_tax_report:build(2026, 600, [E2], #{},
        #{Id => #{<<"category">> => <<"ordinary_income">>,
                  <<"reviewer">> => <<"CPA-01">>, <<"approved">> => true}}),
    ?assertEqual(false, maps:get(<<"attestable">>, R)).

journal_idempotent_and_replay_test_() ->
    {setup,
     fun() ->
         Dir = filename:join("/tmp", "damage_tax_" ++
                             integer_to_list(erlang:unique_integer([positive]))),
         Path = filename:join(Dir, "journal.jsonl"),
         {ok, Pid} = damage_tax_store:start_link(Path),
         {Path, Pid}
     end,
     fun({Path, Pid}) ->
         unlink(Pid),
         ok = gen_server:stop(Pid),
         _ = file:delete(Path),
         _ = file:del_dir(filename:dirname(Path))
     end,
     fun({_Path, _Pid}) ->
         ?_test(begin
             E = witness_event(),
             {ok, _} = damage_tax_store:append(E),
             ?assertEqual({ok, duplicate}, damage_tax_store:append(E)),
             ?assertEqual(ok, damage_tax_store:verify()),
             {ok, Rows} = damage_tax_store:entries(),
             ?assertEqual(1, length(Rows))
         end)
     end}.

witness_event() ->
    {ok, [E]} = damage_tax_event:from_cln_invoice(?TENANT,
        #{status => paid, amount_received_msat => ?BTC_MSAT,
          payment_hash => <<"receipt-hash">>, paid_at => ?HOUR + 10}),
    E#{<<"snapshot_sha256">> =>
       damage_tax_canonical:sha256_hex(<<"sample-original-cln-evidence">>)}.

quote_fixture() ->
    jsx:encode(#{<<"Response">> => <<"Success">>,
       <<"Data">> => #{<<"Data">> => [
         #{<<"time">> => ?HOUR, <<"open">> => 100000.0,
           <<"close">> => 100010.0, <<"conversionType">> => <<"direct">>}]}}).

%% Additional node-admin/reporting integration regressions.
tax_http_scope_validation_test() ->
    ?assertEqual({ok, all},
        damage_tax_http:parse_scope(<<"{\"scope\":\"all\"}">>)),
    ?assertEqual({ok, 2026},
        damage_tax_http:parse_scope(<<"{\"year\":2026}">>)),
    ?assertEqual({ok, {existing, all}},
        damage_tax_http:parse_scope(<<"{\"scope\":\"all\",\"source\":\"journal\"}">>)),
    ?assertMatch({error, _},
        damage_tax_http:parse_scope(<<"{\"year\":\"../../secret\"}">>)),
    ?assertMatch({error, _},
        damage_tax_http:parse_scope(<<"{\"year\":99999}">>)).

tax_http_download_digest_must_be_hex_test() ->
    ?assertEqual(true, damage_tax_http:valid_hash(
        damage_tax_canonical:sha256_hex(<<"known">>))),
    ?assertEqual(false, damage_tax_http:valid_hash(
        <<"../etc/passwd">>)),
    ?assertEqual(false, damage_tax_http:valid_hash(binary:copy(<<"g">>, 64))).

backfill_financial_years_test() ->
    %% Australian local standard offset; June 30 / July 1 boundary.
    {Start, _End} = damage_tax_report:fy_bounds(2026, 600),
    E1 = witness_event(),
    E2 = E1#{<<"occurred_at">> => Start - 1},
    E3 = E1#{<<"occurred_at">> => Start},
    ?assertEqual([2025, 2026], damage_tax_jobs:years([E2, E3], 600)).

non_allocation_non_tax_movement_still_needs_price_test() ->
    E0 = witness_event(),
    E = E0#{<<"default_classification">> => <<"non_tax_event">>},
    ?assertEqual([damage_tax_prices:quote_key(E)],
        damage_tax_report:required_prices([E], 2026, 600)).

private_immutable_report_catalog_test_() ->
    {setup,
     fun() ->
         Dir = filename:join("/tmp", "damage_tax_catalog_" ++
                    integer_to_list(erlang:unique_integer([positive]))),
         Previous = application:get_env(damage, tax_data_dir),
         ok = application:set_env(damage, tax_data_dir, Dir),
         {Dir, Previous}
     end,
     fun({Dir, Previous}) ->
         case Previous of
             {ok, V} -> application:set_env(damage, tax_data_dir, V);
             undefined -> application:unset_env(damage, tax_data_dir)
         end,
         _ = file:del_dir_r(Dir),
         ok
     end,
     fun({_Dir, _Previous}) ->
         ?_test(begin
             E = witness_event(),
             {ok, Report} = damage_tax_report:build(2026, 600, [E], #{}, #{}),
             Digest = maps:get(<<"manifest_sha256">>, Report),
             {ok, Meta} = damage_tax_catalog:save_report(?TENANT, Report),
             ?assertEqual(Digest, maps:get(<<"manifest_sha256">>, Meta)),
             {ok, _Again} = damage_tax_catalog:save_report(?TENANT, Report),
             {ok, Rows} = damage_tax_catalog:list_reports(?TENANT),
             ?assertEqual(1, length(Rows)),
             {ok, ManifestJson, _, _} = damage_tax_catalog:download(
                 ?TENANT, 2026, Digest, json),
             Manifest = jsx:decode(ManifestJson, [return_maps]),
             ?assertEqual(Digest, damage_tax_canonical:commitment(Manifest)),
             {ok, Csv, _, _} = damage_tax_catalog:download(
                 ?TENANT, 2026, Digest, csv),
             ?assert(binary:match(Csv, <<"event_id">>) =/= nomatch),
             ?assertMatch({error, _}, damage_tax_catalog:download(
                 ?TENANT, 2026, <<"../etc/passwd">>, json)),
             {ok, Others} = damage_tax_catalog:list_reports(<<"ak_not_owner">>),
             ?assertEqual([], Others)
         end)
     end}.

%% Regional reporting is a private, accountant-review workpaper workflow.
%% These tests must not depend on a live rate provider or a tax authority API.
regional_profiles_and_fiat_units_test() ->
    Profiles = damage_tax_regions:all(),
    ?assertEqual(13, length(Profiles)),
    ?assertEqual(13, length(lists:usort([maps:get(<<"code">>, P) || P <- Profiles]))),
    ?assertEqual(<<"AUD">>, damage_tax_regions:currency(<<"AU">>)),
    ?assertEqual(<<"USD">>, damage_tax_regions:currency(<<"US">>)),
    ?assertEqual(<<"INR">>, damage_tax_regions:currency(<<"IN">>)),
    ?assertEqual(<<"AED">>, damage_tax_regions:currency(<<"AE">>)),
    ?assertEqual(<<"SGD">>, damage_tax_regions:currency(<<"SG">>)),
    ?assertEqual(0, damage_tax_regions:minor_digits(<<"JP">>)),
    ?assertEqual(6, damage_tax_regions:start_day(<<"GB">>, 4)),
    ?assertEqual(1, damage_tax_regions:start_day(<<"GB">>, 5)),
    ?assertEqual(false, damage_tax_regions:valid(<<"ZZ">>)),
    ?assertMatch({error, _}, damage_tax_regions:lookup(<<"../../etc">>)).

country_fiscal_year_boundaries_test() ->
    {ok, Au} = damage_tax_regions:bounds(<<"AU">>, 2026, 600, 7),
    ?assertEqual(damage_tax_report:fy_bounds(2026, 600), Au),
    {ok, {USStart, USEnd}} = damage_tax_regions:bounds(<<"US">>, 2026, 0, 1),
    ?assertEqual(tax_unix({{2026, 1, 1}, {0, 0, 0}}), USStart),
    ?assertEqual(tax_unix({{2027, 1, 1}, {0, 0, 0}}), USEnd),
    {ok, {UKStart, UKEnd}} = damage_tax_regions:bounds(<<"GB">>, 2026, 0, 4),
    ?assertEqual(tax_unix({{2025, 4, 6}, {0, 0, 0}}), UKStart),
    ?assertEqual(tax_unix({{2026, 4, 6}, {0, 0, 0}}), UKEnd),
    ?assertEqual(2026, damage_tax_regions:year(<<"GB">>, UKEnd - 1, 0, 4)),
    ?assertEqual(2027, damage_tax_regions:year(<<"GB">>, UKEnd, 0, 4)),
    {ok, {NZStart, _}} = damage_tax_regions:bounds(<<"NZ">>, 2026, 720, 4),
    ?assertEqual(tax_unix({{2025, 4, 1}, {0, 0, 0}}) - 720 * 60, NZStart),
    ?assertEqual({error, custom_tax_period_not_supported},
                 damage_tax_regions:bounds(<<"IN">>, 2026, 330, 5)),
    ?assertMatch({ok, {_Start, _End}},
                 damage_tax_regions:bounds(<<"AE">>, 2026, 240, 4)),
    ?assertEqual({error, invalid_tax_period},
                 damage_tax_regions:bounds(<<"US">>, 2026, -721, 1)).

currency_specific_quote_evidence_test() ->
    E = witness_event(),
    {ok, USD} = damage_tax_prices:parse_cryptocompare(
        quote_fixture(), <<"BTC">>, ?HOUR, <<"USD">>),
    {ok, AUD} = damage_tax_prices:parse_cryptocompare(
        quote_fixture(), <<"BTC">>, ?HOUR, <<"AUD">>),
    ?assertEqual(<<"USD">>, maps:get(<<"currency">>, USD)),
    ?assertEqual(ok, damage_tax_prices:valid_quote(E, USD, <<"USD">>)),
    ?assertMatch({error, _}, damage_tax_prices:valid_quote(E, AUD, <<"USD">>)),
    ?assertEqual({ok, 10000000}, damage_tax_prices:fiat_minor(E, USD, <<"USD">>)),
    ?assertMatch({error, _}, damage_tax_prices:aud_cents(E, USD)),
    ?assertEqual({<<"BTC">>, ?HOUR, <<"USD">>}, damage_tax_prices:quote_key(E, <<"USD">>)),
    ?assertEqual({<<"BTC">>, ?HOUR}, damage_tax_prices:quote_key(E, <<"AUD">>)),
    {ok, {_Host, USDPath}} = damage_tax_prices:provider_url(
        cryptocompare, <<"BTC">>, ?HOUR, <<"USD">>),
    ?assert(binary:match(USDPath, <<"tsym=USD">>) =/= nomatch),
    ?assertMatch({error, _}, damage_tax_prices:provider_url(
        cryptocompare, <<"BTC">>, ?HOUR, <<"XYZ">>)).

country_specific_report_is_reviewable_and_currency_safe_test() ->
    E = witness_event(),
    Id = maps:get(<<"id">>, E),
    {ok, USD0} = damage_tax_prices:parse_cryptocompare(
        quote_fixture(), <<"BTC">>, ?HOUR, <<"USD">>),
    USD = USD0#{<<"archive_sha256">> => maps:get(<<"body_sha256">>, USD0)},
    Decision = #{Id => #{<<"category">> => <<"ordinary_income">>,
                         <<"approved">> => true, <<"reviewer">> => <<"CPA-01">>}},
    {ok, USReport} = damage_tax_report:build(
        <<"US">>, 2025, 0, [E], #{damage_tax_prices:quote_key(E, <<"USD">>) => USD}, Decision),
    USManifest = maps:get(<<"manifest">>, USReport),
    ?assertEqual(<<"US">>, maps:get(<<"jurisdiction">>, USManifest)),
    ?assertEqual(<<"USD">>, maps:get(<<"currency">>, USManifest)),
    ?assertEqual(2, maps:get(<<"schema_version">>, USManifest)),
    [Row] = maps:get(<<"entries">>, USManifest),
    ?assertEqual(10000000, maps:get(<<"fiat_minor_units">>, Row)),
    ?assertEqual(null, maps:get(<<"aud_cents">>, Row)),
    ?assertEqual(true, maps:get(<<"attestable">>, USReport)),
    ?assert(binary:match(damage_tax_workpapers:to_csv(USReport),
                         <<"gross_proceeds_usd_minor">>) =/= nomatch),
    ?assert(binary:match(damage_tax_workpapers:to_csv(USReport),
                         <<"DRAFT_REVIEW_REQUIRED">>) =/= nomatch),
    ?assertEqual(<<"tax-US-workpaper.csv">>, damage_tax_workpapers:filename(<<"US">>)),
    {ok, Wrong} = damage_tax_report:build(
        <<"US">>, 2025, 0, [E], #{damage_tax_prices:quote_key(E, <<"USD">>) =>
                                   USD#{<<"currency">> => <<"AUD">>}}, Decision),
    ?assertEqual(false, maps:get(<<"attestable">>, Wrong)),
    [WrongRow] = maps:get(<<"entries">>, maps:get(<<"manifest">>, Wrong)),
    ?assertEqual(null, maps:get(<<"fiat_minor_units">>, WrongRow)),
    ?assert(lists:member(<<"missing_or_invalid_historical_fiat_price">>,
                         maps:get(<<"review_reasons">>, WrongRow))),
    {ok, AUReport} = damage_tax_report:build(2026, 600, [E], #{}, #{}),
    ?assertNotEqual(maps:get(<<"manifest_sha256">>, AUReport),
                    maps:get(<<"manifest_sha256">>, USReport)).

zero_decimal_jpy_report_test() ->
    E = witness_event(),
    {ok, JPY0} = damage_tax_prices:parse_cryptocompare(
        quote_fixture(), <<"BTC">>, ?HOUR, <<"JPY">>),
    Q = JPY0#{<<"archive_sha256">> => maps:get(<<"body_sha256">>, JPY0)},
    {ok, Report} = damage_tax_report:build(
        <<"JP">>, 2025, 540, [E], #{damage_tax_prices:quote_key(E, <<"JPY">>) => Q}, #{}),
    Manifest = maps:get(<<"manifest">>, Report),
    [Row] = maps:get(<<"entries">>, Manifest),
    ?assertEqual(0, maps:get(<<"minor_digits">>, Manifest)),
    ?assertEqual(100000, maps:get(<<"fiat_minor_units">>, Row)),
    ?assertEqual(null, maps:get(<<"aud_cents">>, Row)).

regional_scope_validation_test() ->
    ?assertEqual({ok, {region, <<"US">>, -300, 1, all}},
        damage_tax_http:parse_scope(
          <<"{\"scope\":\"all\",\"jurisdiction\":\"US\",\"standard_utc_offset_minutes\":-300,\"period_start_month\":1}">>)),
    ?assertEqual({ok, {region, <<"IN">>, 330, 4, {existing, 2026}}},
        damage_tax_http:parse_scope(
          <<"{\"year\":2026,\"source\":\"journal\",\"jurisdiction\":\"IN\"}">>)),
    ?assertMatch({error, _}, damage_tax_http:parse_scope(
        <<"{\"year\":2026,\"jurisdiction\":\"XX\"}">>)),
    ?assertMatch({error, _}, damage_tax_http:parse_scope(
        <<"{\"year\":2026,\"jurisdiction\":\"IN\",\"period_start_month\":5}">>)),
    ?assertMatch({error, _}, damage_tax_http:parse_scope(
        <<"{\"scope\":\"all\",\"jurisdiction\":\"AU\",\"admin\":true}">>)),
    ?assertMatch({error, _}, damage_tax_http:parse_scope(
        <<"{\"year\":2026,\"scope\":\"all\",\"jurisdiction\":\"AU\"}">>)).

tax_unix(DateTime) ->
    calendar:datetime_to_gregorian_seconds(DateTime) -
        calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).

regional_immutable_report_catalog_test_() ->
    {setup,
     fun() ->
         Dir = filename:join("/tmp", "damage_tax_region_catalog_" ++
                             integer_to_list(erlang:unique_integer([positive]))),
         Previous = application:get_env(damage, tax_data_dir),
         ok = application:set_env(damage, tax_data_dir, Dir),
         {Dir, Previous}
     end,
     fun({Dir, Previous}) ->
         case Previous of
             {ok, V} -> application:set_env(damage, tax_data_dir, V);
             undefined -> application:unset_env(damage, tax_data_dir)
         end,
         _ = file:del_dir_r(Dir),
         ok
     end,
     fun({_Dir, _Previous}) ->
         ?_test(begin
             E = witness_event(),
             {ok, AU} = damage_tax_report:build(2026, 600, [E], #{}, #{}),
             {ok, US} = damage_tax_report:build(<<"US">>, 2025, 0, [E], #{}, #{}),
             {ok, AUMeta} = damage_tax_catalog:save_report(?TENANT, AU),
             {ok, USMeta} = damage_tax_catalog:save_report(?TENANT, US),
             ?assertEqual(<<"AU">>, maps:get(<<"jurisdiction">>, AUMeta)),
             ?assertEqual(<<"USD">>, maps:get(<<"currency">>, USMeta)),
             ?assertNotEqual(maps:get(<<"manifest_sha256">>, AUMeta),
                             maps:get(<<"manifest_sha256">>, USMeta)),
             {ok, Rows} = damage_tax_catalog:list_reports(?TENANT),
             ?assertEqual(2, length(Rows)),
             Digest = maps:get(<<"manifest_sha256">>, US),
             {ok, CSV, <<"text/csv; charset=utf-8">>, <<"tax-US-workpaper.csv">>} =
                 damage_tax_catalog:download(?TENANT, 2025, Digest, worksheet),
             ?assert(binary:match(CSV, <<"jurisdiction">>) =/= nomatch),
             ?assert(binary:match(CSV, <<"gross_proceeds_usd_minor">>) =/= nomatch),
             ?assert(binary:match(CSV, <<"DRAFT_REVIEW_REQUIRED">>) =/= nomatch),
             ?assertMatch({error, _}, damage_tax_catalog:download(
                 <<"ak_other_tenant">>, 2025, Digest, worksheet)),
             ?assertMatch({error, invalid_price_quote}, damage_tax_catalog:save_quote(
                 {<<"BTC">>, 1, <<"../../etc">>}, #{}))
         end)
     end}.

workpaper_csv_does_not_execute_formula_cells_test() ->
    Suspicious = <<" \t=HYPERLINK(\"\"https://bad.invalid\"\",\"\"click\"\")">>,
    R = #{<<"manifest">> => #{<<"jurisdiction">> => <<"US">>,
                               <<"currency">> => <<"USD">>,
                               <<"entries">> => [#{<<"source_ref">> => Suspicious}] }},
    Csv = damage_tax_workpapers:to_csv(R),
    ?assert(binary:match(Csv, <<"' \t=HYPERLINK">>) =/= nomatch),
    TxCsv = damage_tax_report:to_csv(R),
    ?assert(binary:match(TxCsv, <<"' \t=HYPERLINK">>) =/= nomatch).
