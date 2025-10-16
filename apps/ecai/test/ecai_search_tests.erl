%%%-------------------------------------------------------------------
%%% File: test/ecai_search_tests.erl
%%%-------------------------------------------------------------------
-module(ecai_search_tests).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

%% assumes ecai_search.erl and ecai_context_demo.erl are in code path
%% run via: rebar3 eunit -m ecai_search_tests

ecai_index_basic_test() ->
    Ctx = ecai_search:new(),

    %% Add sample businesses
    ok = ecai_search:add_record(Ctx, <<"biz:001">>, #{
        name => <<"Acme Plumbing Co">>,
        category => <<"plumber">>,
        city => <<"Sydney NSW">>,
        tags => [<<"24x7">>, <<"emergency">>],
        phone => <<"+61 2 9123 4567">>
    }),

    ok = ecai_search:add_record(Ctx, <<"biz:002">>, #{
        name => <<"Acme Electrical">>,
        category => <<"electrician">>,
        city => <<"Sydney">>,
        tags => [<<"licensed">>],
        phone => <<"0298761234">>
    }),

    ok = ecai_search:add_record(Ctx, <<"biz:003">>, #{
        name => <<"Baker Bros">>,
        category => <<"bakery">>,
        city => <<"Melbourne">>,
        tags => [<<"artisan">>],
        phone => <<"0398761234">>
    }),

    %% --- Structural checks ---
    Sz = ecai_search:size(Ctx),
    ?assertEqual(3, maps:get(docs, Sz)),

    %% --- Term existence ---
    Info = ecai_search:info_term(Ctx, <<"pfx:name:acm">>),
    ?assert(maps:get(df, Info) > 0),

    %% --- Search (prefix "acm") should yield biz:001 & biz:002 ---
    {Res, _Proofs} = ecai_search:search(Ctx, #{name => <<"acm">>, prefix => true}, 5),
    DocIds = [Doc || {Doc, _} <- Res],
    ?assert(lists:member(<<"biz:001">>, DocIds)),
    ?assert(lists:member(<<"biz:002">>, DocIds)),
    ?assertNot(lists:member(<<"biz:003">>, DocIds)),

    %% --- Deterministic root for term ---
    Root1 = ecai_search:term_root(Ctx, <<"pfx:name:acm">>),
    Root2 = ecai_search:term_root(Ctx, <<"pfx:name:acm">>),
    ?assertEqual(Root1, Root2),

    %% --- Membership proof should exist for (term, doc) pair ---
    Proof = ecai_search:proof_for(Ctx, <<"pfx:name:acm">>, <<"biz:001">>),
    ?assertMatch({ok, _Path, _Dirs}, Proof),

    %% --- Re-add same data should yield same root (deterministic) ---
    C2 = ecai_search:new(),
    [
        ecai_search:add_record(C2, Id, M)
     || {Id, M} <- [
            {<<"biz:001">>, #{
                name => <<"Acme Plumbing Co">>,
                category => <<"plumber">>,
                city => <<"Sydney NSW">>,
                tags => [<<"24x7">>, <<"emergency">>],
                phone => <<"+61 2 9123 4567">>
            }},
            {<<"biz:002">>, #{
                name => <<"Acme Electrical">>,
                category => <<"electrician">>,
                city => <<"Sydney">>,
                tags => [<<"licensed">>],
                phone => <<"0298761234">>
            }},
            {<<"biz:003">>, #{
                name => <<"Baker Bros">>,
                category => <<"bakery">>,
                city => <<"Melbourne">>,
                tags => [<<"artisan">>],
                phone => <<"0398761234">>
            }}
        ]
    ],
    RootAgain = ecai_search:term_root(C2, <<"pfx:name:acm">>),
    ?assertEqual(Root1, RootAgain),

    ok.
