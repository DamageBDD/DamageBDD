-module(ecai_index_job_codec_wikimedia_tests).

-include_lib("eunit/include/eunit.hrl").

normalize_wikimedia_job_test() ->
    Spec = spec(),
    {ok, Normalized} = ecai_index_job_codec:normalize_spec(Spec),
    ?assertEqual(wikimedia_visibility, maps:get(kind, Normalized)),
    ?assertEqual(live_search, maps:get(mode, maps:get(target, Normalized))),
    Source = maps:get(source, Normalized),
    ?assertEqual(<<"enwiki">>, maps:get(project, Source)),
    ?assertEqual([<<"2026-05">>, <<"2026-06">>], maps:get(pageview_months, Source)),
    Options = maps:get(options, Normalized),
    ?assertEqual(1000, maps:get(limit, Options)),
    ?assertEqual(16, maps:get(selection_shards, Options)),
    ?assertEqual(16384, maps:get(abstract_max_bytes, Options)),
    ?assertEqual(false, maps:get(keep_intermediates, Options)),
    {ok, Hash1} = ecai_index_job_codec:spec_hash(Spec),
    {ok, Hash2} = ecai_index_job_codec:spec_hash(Spec),
    ?assertEqual(Hash1, Hash2).

keep_intermediates_override_test() ->
    Base = spec(),
    Options0 = maps:get(<<"options">>, Base),
    Requested = Base#{
        <<"options">> => Options0#{
            <<"keep_intermediates">> => true,
            <<"abstract_max_bytes">> => 32768
        }
    },
    {ok, Normalized} = ecai_index_job_codec:normalize_spec(Requested),
    Options = maps:get(options, Normalized),
    ?assertEqual(true, maps:get(keep_intermediates, Options)),
    ?assertEqual(32768, maps:get(abstract_max_bytes, Options)).

too_many_months_rejected_test() ->
    Months = [
        iolist_to_binary(io_lib:format("2020-~2..0B", [((N - 1) rem 12) + 1]))
     || N <- lists:seq(1, 65)
    ],
    Base = spec(),
    Source0 = maps:get(<<"source">>, Base),
    Invalid = Base#{<<"source">> => Source0#{<<"pageview_months">> => Months}},
    ?assertEqual(
        {error, {too_many_pageview_months, 65, 64}},
        ecai_index_job_codec:normalize_spec(Invalid)
    ).

minimum_active_months_must_fit_window_test() ->
    Base = spec(),
    Options0 = maps:get(<<"options">>, Base),
    Invalid = Base#{
        <<"options">> => Options0#{<<"minimum_active_months">> => 3}
    },
    ?assertEqual(
        {error, {minimum_active_months_exceeds_window, 3, 2}},
        ecai_index_job_codec:normalize_spec(Invalid)
    ).

invalid_project_token_rejected_test() ->
    Base = spec(),
    Source0 = maps:get(<<"source">>, Base),
    Invalid = Base#{<<"source">> => Source0#{<<"project">> => <<"enwiki/../../">>}},
    ?assertEqual(
        {error, {invalid_field, project}},
        ecai_index_job_codec:normalize_spec(Invalid)
    ).

auto_mint_is_rejected_until_step4b_test() ->
    Base = spec(),
    Finalize0 = maps:get(<<"finalize">>, Base),
    Invalid = Base#{
        <<"finalize">> => Finalize0#{<<"auto_mint">> => true}
    },
    ?assertEqual(
        {error, {unsupported_option, auto_mint, step4b_required}},
        ecai_index_job_codec:normalize_spec(Invalid)
    ).

catalog_path_is_preserved_as_a_pinned_source_test() ->
    Base = spec(),
    Source0 = maps:get(<<"source">>, Base),
    Requested = Base#{
        <<"source">> => Source0#{
            <<"catalog_path">> => <<"/var/lib/damage/ecai/catalog.json">>
        }
    },
    {ok, Normalized} = ecai_index_job_codec:normalize_spec(Requested),
    Source = maps:get(source, Normalized),
    ?assertEqual(
        <<"/var/lib/damage/ecai/catalog.json">>,
        maps:get(catalog_path, Source)
    ).

spec() ->
    #{
        <<"schema">> => <<"ecai-index-job/v1">>,
        <<"kind">> => <<"wikimedia_visibility">>,
        <<"owner">> => <<"operator">>,
        <<"source">> => #{
            <<"project">> => <<"enwiki">>,
            <<"pageview_project">> => <<"en.wikipedia">>,
            <<"content_release">> => <<"20260720">>,
            <<"pageview_months">> => [<<"2026-05">>, <<"2026-06">>]
        },
        <<"target">> => #{
            <<"index_id">> => <<"test-wikimedia">>,
            <<"namespace">> => <<"org.damagebdd.test.wikimedia">>,
            <<"base_dir">> => <<"/tmp/ecai-wikimedia-test">>,
            <<"mode">> => <<"live_search">>
        },
        <<"options">> => #{
            <<"limit">> => 1000,
            <<"minimum_active_months">> => 1,
            <<"selection_shards">> => 16,
            <<"publish_activity_ipfs">> => false
        },
        <<"finalize">> => #{
            <<"build_nft_manifest">> => true,
            <<"publish_ipfs">> => false,
            <<"auto_mint">> => false
        }
    }.
