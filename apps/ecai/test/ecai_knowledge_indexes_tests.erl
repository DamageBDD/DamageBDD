%% Selection dispatch tests use real query/index code. Named accessors below
%% supply contexts and the production pool owner's manifest callback only.
-module(ecai_knowledge_indexes_tests).
-include_lib("eunit/include/eunit.hrl").

selection_shape_test() ->
    ?assertEqual({ok,all},ecai_knowledge:validate_indexes(all)),
    ?assertEqual({ok,[]},ecai_knowledge:validate_indexes([])),
    ?assertEqual({ok,[<<"shared">>,<<"wikimedia">>]},
        ecai_knowledge:validate_indexes([<<"wikimedia">>,<<"shared">>,<<"shared">>])),
    lists:foreach(fun(Bad) ->
        ?assertEqual({error,invalid_index_selection},ecai_knowledge:validate_indexes(Bad))
    end,[null,false,<<"shared">>,#{},[shared],[12],[<<>>],[binary:copy(<<"a">>,129)],
        lists:duplicate(129,<<"shared">>)]).

empty_selection_has_no_backend_work_test() ->
    %% No lookup of even the operator's disk config should occur for [].
    with_env(knowledge_disk_indexes,deliberately_invalid,fun() ->
        {ok,R} = ecai_knowledge:search(<<"test">>,#{indexes => []}),
        ?assertEqual([],maps:get(results,R)),
        ?assertEqual([],maps:get(backends,R)),
        ?assertEqual(false,maps:get(partial,R)),
        ?assertEqual(#{mode => selected,indexes => []},maps:get(selection,R))
    end).

shared_only_skips_unselected_services_test() ->
    with_shared(fun(_Ctx,Tag) ->
        %% This principal would require funded discovery for an all-index query;
        %% selecting shared must not contact the unavailable funded coordinator.
        ?assertEqual(undefined,whereis(ecai_index_pool)),
        {ok,R} = ecai_knowledge:search(<<"redire">>,
            #{principal => <<"alice">>,indexes => [<<"shared">>,<<"shared">>]}),
        ?assertEqual([<<"shared">>],backend_ids(R)),
        ?assertEqual(false,maps:get(partial,R)),
        ?assertEqual([<<"redirect-test">>],doc_ids(R)),
        receive {Tag,called} -> ok after 1000 -> error(shared_not_queried) end,
        receive {Tag,called} -> error(queried_twice) after 0 -> ok end,
        [H] = maps:get(results,R),
        {ok,S} = ecai_knowledge:source(maps:get(source_ref,H),<<"alice">>),
        ?assertEqual(<<"Redirect test source">>,maps:get(text,S))
    end).

unknown_id_rejects_before_dispatch_test() ->
    with_shared(fun(_Ctx,Tag) ->
        lists:foreach(fun(Id) ->
            ?assertEqual({error,invalid_index_selection},ecai_knowledge:search(<<"redire">>,
                #{indexes => [<<"shared">>,Id]}))
        end,[<<"missing">>,<<"/tmp/private">>,<<"https://example.invalid/index">>,<<"pool:bob">>]),
        receive {Tag,called} -> error(unknown_selection_queried_shared) after 0 -> ok end
    end).

unselected_outage_does_not_mark_partial_test() ->
    with_shared(fun(_Ctx,_Tag) ->
        ?assertEqual(undefined,whereis(ecai_wikimedia_search_server)),
        {ok,Only} = ecai_knowledge:search(<<"redire">>,#{indexes => [<<"shared">>]}),
        ?assertEqual(false,maps:get(partial,Only)),
        {ok,All} = ecai_knowledge:search(<<"redire">>),
        ?assertEqual(all,maps:get(mode,maps:get(selection,All))),
        ?assertEqual([<<"shared">>,<<"wikimedia">>],backend_ids(All)),
        ?assertEqual(true,maps:get(partial,All)),
        {ok,Wiki} = ecai_knowledge:search(<<"redire">>,#{indexes => [<<"wikimedia">>]}),
        ?assertEqual([<<"wikimedia">>],backend_ids(Wiki)),
        ?assertEqual([],maps:get(results,Wiki))
    end).

funded_owner_catalog_and_selection_test() ->
    with_env(knowledge_disk_indexes,[],fun() ->
        Parent = self(), Tag = make_ref(),
        State = {st,undefined,#{jobs => #{
            <<"alice-job">> => #{id => <<"alice-job">>,owner => <<"alice">>,
                manifest => #{path => <<"/not-present/alice.etf">>,private_note => <<"must-not-leak">>}},
            <<"bob-job">> => #{id => <<"bob-job">>,owner => <<"bob">>,
                manifest => #{path => <<"/not-present/bob.etf">>}}
        }},undefined,undefined,undefined},
        with_named(ecai_index_pool,fun() -> pool_accessor(Parent,Tag,State) end,fun() ->
            Guest = ecai_knowledge:index_catalog(undefined),
            ?assertEqual([<<"shared">>,<<"wikimedia">>],catalog_ids(Guest)),
            receive {Tag,_} -> error(guest_queried_pool) after 0 -> ok end,
            Alice = ecai_knowledge:index_catalog(<<"alice">>),
            ?assertEqual([<<"shared">>,<<"wikimedia">>,<<"pool:alice-job">>],catalog_ids(Alice)),
            [Owned] = [I || I <- maps:get(indexes,Alice),maps:get(scope,I) =:= owner],
            ?assertEqual(false,maps:is_key(path,Owned)),
            ?assertEqual(false,maps:is_key(manifest,Owned)),
            ?assertEqual(false,maps:is_key(private_note,Owned)),
            ?assertEqual({error,invalid_index_selection},ecai_knowledge:search(<<"redire">>,
                #{principal => <<"alice">>,indexes => [<<"pool:bob-job">>]})),
            ?assertEqual({error,invalid_index_selection},ecai_knowledge:search(<<"redire">>,
                #{principal => <<"alice">>,indexes => [<<"pool:unknown">>]})),
            {ok,Selected} = ecai_knowledge:search(<<"redire">>,
                #{principal => <<"alice">>,indexes => [<<"pool:alice-job">>]}),
            ?assertEqual([<<"pool:alice-job">>],backend_ids(Selected)),
            %% Fixture's file is absent: report only this selected backend's failure.
            ?assertEqual(true,maps:get(partial,Selected))
        end)
    end).

funded_discovery_failure_fails_closed_test() ->
    with_env(knowledge_disk_indexes,[],fun() ->
        ?assertEqual(undefined,whereis(ecai_index_pool)),
        ?assertEqual({error,funded_indexes_unavailable},ecai_knowledge:search(<<"redire">>,
            #{principal => <<"alice">>,indexes => [<<"pool:alice-job">>]})),
        C = ecai_knowledge:index_catalog(<<"alice">>),
        ?assertEqual(true,maps:get(partial,C)),
        ?assertMatch([#{phase := discovery}],maps:get(backends,C))
    end).

disk_selection_preserves_prefix_and_source_test() ->
    with_dir(fun(Dir) -> with_shared(fun(_Ctx,Tag) ->
        Text = <<"Redirect disk source">>,
        {ok,Ref} = ecai_source_retrieval:retain(Dir,Text,<<"test">>,<<"v1">>),
        S0 = ecai_disk_indexer:new(Dir,#{max_docs => 1}),
        S1 = ecai_disk_indexer:add_records(S0,[#{title => <<"Redirect disk">>,source_blob => Ref}]),
        ok = ecai_disk_indexer:close(S1),
        with_env(knowledge_disk_indexes,[#{id => <<"disk-test">>,dir => Dir}],fun() ->
            {ok,R} = ecai_knowledge:search(<<"redire">>,#{indexes => [<<"disk-test">>]}),
            ?assertEqual([<<"disk-test">>],backend_ids(R)),
            [H] = maps:get(results,R),
            ?assertEqual(<<"disk-test">>,maps:get(index,H)),
            ?assertEqual(#{mode => selected,indexes => [<<"disk-test">>]},maps:get(selection,R)),
            receive {Tag,called} -> error(disk_selection_queried_shared) after 0 -> ok end,
            {ok,Source} = ecai_knowledge:source(maps:get(source_ref,H),undefined),
            ?assertEqual(Text,maps:get(text,Source)),
            ?assertEqual(verified_sha256,maps:get(integrity,Source)),
            [Entry] = [I || I <- maps:get(indexes,ecai_knowledge:index_catalog(undefined)),
                           maps:get(id,I) =:= <<"disk-test">>],
            ?assertEqual(false,maps:is_key(dir,Entry)),
            ?assertEqual(ready,maps:get(state,Entry)),
            {ok,Exact} = ecai_knowledge:search(<<"redire">>,#{indexes => [<<"disk-test">>],matching => exact}),
            ?assertEqual([],maps:get(results,Exact))
        end)
    end) end).

http_selection_contract_test_() ->
    {timeout,30,fun() -> with_shared(fun(_Ctx,_Tag) ->
        {ok,_} = application:ensure_all_started(cowboy),
        {ok,_} = application:ensure_all_started(inets),
        Listener = ecai_knowledge_indexes_test_listener,
        Routes = [{"/ecai/knowledge/" ++ atom_to_list(A),ecai_knowledge_http,#{action => A}}
            || A <- [search,indexes,source]],
        Dispatch = cowboy_router:compile([{'_',Routes}]),
        {ok,_} = cowboy:start_clear(Listener,[{ip,{127,0,0,1}},{port,0}],#{env => #{dispatch => Dispatch}}),
        try
            Port = ranch:get_port(Listener),
            {200,Catalog} = get(Port,"indexes",[],[]),
            ?assertEqual([<<"shared">>,<<"wikimedia">>],[maps:get(<<"id">>,I) || I <- maps:get(<<"indexes">>,Catalog)]),
            {200,R} = post(Port,#{<<"q">> => <<"redire">>,<<"indexes">> => [<<"shared">>]},[]),
            ?assertEqual(1,maps:get(<<"count">>,R)),
            ?assertEqual(false,maps:get(<<"partial">>,R)),
            ?assertEqual(#{<<"mode">> => <<"selected">>,<<"indexes">> => [<<"shared">>]},maps:get(<<"selection">>,R)),
            {200,Empty} = post(Port,#{<<"q">> => <<"redire">>,<<"indexes">> => []},[]),
            ?assertEqual([],maps:get(<<"backends">>,Empty)),
            lists:foreach(fun(Bad) ->
                {400,B} = post(Port,#{<<"q">> => <<"redire">>,<<"indexes">> => Bad},[]),
                ?assertEqual(<<"invalid_index_selection">>,maps:get(<<"error">>,B))
            end,[null,<<"shared">>,[<<"missing">>],[<<"pool:other-owner">>],#{},[9]]),
            {200,G} = get(Port,"search",[{"q","redire"},{"indexes","[\"shared\"]"}],[]),
            ?assertEqual(1,maps:get(<<"count">>,G)),
            {200,GNone} = get(Port,"search",[{"q","redire"},{"indexes","[]"}],[]),
            ?assertEqual([],maps:get(<<"results">>,GNone)),
            {400,_} = get(Port,"search",[{"q","redire"},{"indexes","[]"},{"indexes","all"}],[]),
            {401,_} = get(Port,"indexes",[],[{"authorization","Basic invalid"}]),
            {401,_} = post(Port,#{<<"q">> => <<"redire">>,<<"indexes">> => [<<"shared">>]},[{"authorization","Basic invalid"}])
        after cowboy:stop_listener(Listener) end
    end) end}.

backend_ids(R) -> [maps:get(id,S) || S <- maps:get(backends,R)].
doc_ids(R) -> [maps:get(doc_id,H) || H <- maps:get(results,R)].
catalog_ids(R) -> [maps:get(id,I) || I <- maps:get(indexes,R)].

with_shared(Fun) ->
    with_env(knowledge_disk_indexes,[],fun() ->
        Ctx = ecai_search:set_opts(ecai_search:new(),#{root_mode => deferred}),
        Text = <<"Redirect test source">>,
        try
            ok = ecai_search:add_record(Ctx,<<"redirect-test">>,#{title => <<"Redirect test">>,
                text => Text,source_text => Text,source_bytes => byte_size(Text),source_complete => true,
                source_sha256 => ecai_index_job_codec:id_hex(crypto:hash(sha256,Text)),
                source_representation => <<"test_utf8">>}),
            Parent = self(), Tag = make_ref(),
            with_named(ecai_search_server,fun() -> shared_accessor(Parent,Tag,Ctx) end,fun() -> Fun(Ctx,Tag) end)
        after ecai_search:wipe(Ctx) end
    end).
with_named(Name,Loop,Fun) ->
    ?assertEqual(undefined,whereis(Name)),
    Pid = spawn(Loop), true = register(Name,Pid),
    try Fun() after
        Mon = erlang:monitor(process,Pid), exit(Pid,kill),
        receive {'DOWN',Mon,process,Pid,_} -> ok end
    end.
shared_accessor(Parent,Tag,Ctx) ->
    receive
        {'$gen_call',From,get_ctx} -> Parent ! {Tag,called},gen_server:reply(From,Ctx),shared_accessor(Parent,Tag,Ctx)
    end.
pool_accessor(Parent,Tag,State) ->
    receive
        {'$gen_call',From,{knowledge_manifests,Owner} = Request} ->
            Parent ! {Tag,Owner},
            {reply,Views,State} = ecai_index_pool:handle_call(Request,From,State),
            gen_server:reply(From,Views),pool_accessor(Parent,Tag,State)
    end.
with_env(Key,Value,Fun) ->
    Old = application:get_env(ecai,Key), application:set_env(ecai,Key,Value),
    try Fun() after
        case Old of undefined -> application:unset_env(ecai,Key); {ok,V} -> application:set_env(ecai,Key,V) end
    end.
with_dir(Fun) ->
    Root = case os:getenv("TMPDIR") of false -> "/tmp"; P -> P end,
    Dir = filename:join(Root,"ecai-index-selection-" ++ integer_to_list(erlang:unique_integer([positive,monotonic]))),
    ok = file:make_dir(Dir),
    try Fun(Dir) after file:del_dir_r(Dir) end.
post(Port,Body,Headers) ->
    URL = base_url(Port) ++ "/search",
    {ok,{{_,Code,_},_,Bytes}} = httpc:request(post,{URL,Headers,"application/json",jsx:encode(Body)},
        [{timeout,10000}],[{body_format,binary}]),
    {Code,jsx:decode(Bytes,[return_maps])}.
get(Port,Action,Pairs,Headers) ->
    URL = base_url(Port) ++ "/" ++ Action ++ "?" ++ uri_string:compose_query(Pairs),
    {ok,{{_,Code,_},_,Bytes}} = httpc:request(get,{URL,Headers},[{timeout,10000}],[{body_format,binary}]),
    {Code,jsx:decode(Bytes,[return_maps])}.
base_url(Port) -> "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/ecai/knowledge".
