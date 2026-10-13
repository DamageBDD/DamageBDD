%%%-------------------------------------------------------------------
%%% File: test/ecai_search_tests.erl
%%%-------------------------------------------------------------------
-module(ecai_search_tests).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").

%% Run with one selector at a time, for example:
%%   rebar3 eunit --module=ecai_search_tests

ecai_index_basic_test() ->
    %% Two contexts are intentional: deterministic rebuilds must coexist in
    %% one VM without globally named ETS tables colliding.
    Ctx1 = ecai_search:new(),
    Ctx2 = ecai_search:new(),
    try
        Records = sample_records(),
        ok = add_records(Ctx1, Records),

        %% --- Structural checks ---
        Sz = ecai_search:size(Ctx1),
        ?assertEqual(3, maps:get(docs, Sz)),

        %% --- Term existence ---
        Info = ecai_search:info_term(Ctx1, <<"pfx:name:acm">>),
        ?assert(maps:get(df, Info) > 0),

        %% --- Search (prefix "acm") should yield biz:001 & biz:002 ---
        {Results, _Proofs} = ecai_search:search(
            Ctx1,
            #{name => <<"acm">>, prefix => true},
            5
        ),
        DocIds = [maps:get(doc_id, Result) || Result <- Results],
        ?assert(lists:member(<<"biz:001">>, DocIds)),
        ?assert(lists:member(<<"biz:002">>, DocIds)),
        ?assertNot(lists:member(<<"biz:003">>, DocIds)),

        %% Search results use the public enriched-map shape.
        [First | _] = Results,
        ?assert(maps:is_key(score, First)),
        ?assert(maps:is_key(record, First)),
        ?assert(maps:is_key(preview, First)),

        %% --- Deterministic root for term ---
        Root1 = ecai_search:term_root(Ctx1, <<"pfx:name:acm">>),
        Root2 = ecai_search:term_root(Ctx1, <<"pfx:name:acm">>),
        ?assertEqual(Root1, Root2),

        %% --- Membership proof should exist for (term, doc) pair ---
        Proof = ecai_search:proof_for(
            Ctx1,
            <<"pfx:name:acm">>,
            <<"biz:001">>
        ),
        ?assertMatch({ok, _Path, _Dirs}, Proof),

        %% --- Rebuild in a second live context; root must match ---
        ok = add_records(Ctx2, Records),
        RootAgain = ecai_search:term_root(Ctx2, <<"pfx:name:acm">>),
        ?assertEqual(Root1, RootAgain)
    after
        ok = ecai_search:wipe(Ctx1),
        ok = ecai_search:wipe(Ctx2)
    end.

add_records(Ctx, Records) ->
    lists:foreach(
        fun({DocId, Record}) ->
            ok = ecai_search:add_record(Ctx, DocId, Record)
        end,
        Records
    ).

sample_records() ->
    [
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
    ].
