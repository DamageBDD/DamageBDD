%% Real in-memory and ECS1/DETS indexing. No HTTP/auth/payment mocks here.
-module(ecai_knowledge_prefix_tests).
-include_lib("eunit/include/eunit.hrl").

live_typeahead_test() ->
    Ctx = ecai_search:set_opts(ecai_search:new(),#{root_mode => deferred}),
    try
        ok = ecai_search:add_record(Ctx,<<"redirect">>,#{title => <<"Redirect test">>}),
        ok = ecai_search:add_record(Ctx,<<"red">>,#{title => <<"Red rectangle">>}),
        {Hs,Meta} = ecai_search:text_search(Ctx,<<"redire">>,10,bool_prefix),
        ?assertEqual([<<"redirect">>],[maps:get(doc_id,H) || H <- Hs]),
        ?assertEqual(false,maps:get(truncated,Meta)),
        ?assertMatch({[],_},ecai_search:text_search(Ctx,<<"redirect xyz">>,10,bool_prefix)),
        ?assertMatch({[],_},ecai_search:text_search(Ctx,<<"redire">>,10,exact)),
        ok = ecai_search:upsert_record(Ctx,<<"redirect">>,#{title => <<"Renamed document">>}),
        ?assertMatch({[],_},ecai_search:text_search(Ctx,<<"redire">>,10,bool_prefix))
    after ecai_search:wipe(Ctx) end.

retained_body_prefix_beyond_preview_test() ->
    Ctx = ecai_search:set_opts(ecai_search:new(),#{root_mode => deferred}),
    Text = <<(binary:copy(<<"filler ">>,300))/binary,"tailredirect">>,
    Record = #{title => <<"Source document">>,text => <<"short preview">>,source_text => Text,
        source_sha256 => ecai_index_job_codec:id_hex(crypto:hash(sha256,Text)),
        source_bytes => byte_size(Text),source_complete => true,
        source_representation => <<"test_utf8">>},
    try
        ok = ecai_search:add_record(Ctx,<<"body">>,Record),
        ok = ecai_source_retrieval:index_text(Ctx,<<"body">>,Record),
        {Hits,_} = ecai_search:text_search(Ctx,<<"tailred">>,10,bool_prefix),
        ?assertEqual([<<"body">>],[maps:get(doc_id,H) || H <- Hits]),
        {ok,Recovered} = ecai_search:source(Ctx,<<"body">>),
        ?assertEqual(Text,maps:get(text,Recovered))
    after ecai_search:wipe(Ctx) end.

wikimedia_preserves_filters_and_dedupe_test() ->
    Ctx = ecai_search:set_opts(ecai_search:new(),#{root_mode => deferred}),
    try
        lists:foreach(fun({Id,Lang,Rank}) ->
            ok = ecai_search:add_record(Ctx,Id,#{title => <<"Redirect test">>,
                language => Lang,wikidata_id => <<"Q1">>,visibility_rank => Rank})
        end,[{<<"en">>,<<"en">>,1},{<<"fr">>,<<"fr">>,2}]),
        {ok,A} = ecai_wikimedia_search:search(Ctx,<<"redire">>,
            #{matching => bool_prefix,include_proofs => false}),
        ?assertEqual(1,maps:get(count,A)),
        {ok,B} = ecai_wikimedia_search:search(Ctx,<<"redire">>,
            #{matching => bool_prefix,language => <<"fr">>,include_proofs => false}),
        ?assertEqual([<<"fr">>],[maps:get(doc_id,H) || H <- maps:get(results,B)]),
        {ok,C} = ecai_wikimedia_search:search(Ctx,<<"redirect xyz">>,
            #{matching => bool_prefix,include_proofs => false}),
        ?assertEqual([],maps:get(results,C))
    after ecai_search:wipe(Ctx) end.

disk_existing_format_and_source_test() ->
    with_dir(fun(Dir) ->
        Text = <<"Redirect test source with internationalization details">>,
        {ok,Ref} = ecai_source_retrieval:retain(Dir,Text,<<"smoke">>,<<"v1">>),
        S0 = ecai_disk_indexer:new(Dir,#{max_docs => 1,flush_interval_ms => 60000}),
        S1 = ecai_disk_indexer:add_records(S0,[
            #{title => <<"Redirect test">>,text => Text,source_blob => Ref}]),
        %% Search while the writer is still running; only published batches.
        try
            {Hs,Meta} = ecai_disk_search:text_search(Dir,<<"redire">>,10,bool_prefix),
            ?assertEqual([1],[maps:get(doc_id,H) || H <- Hs]),
            ?assertEqual(false,maps:get(truncated,Meta)),
            ?assertMatch({[_],_},ecai_disk_search:text_search(Dir,<<"redirect te">>,10,bool_prefix)),
            ?assertMatch({[],_},ecai_disk_search:text_search(Dir,<<"redirect xyz">>,10,bool_prefix)),
            ?assertMatch({[],_},ecai_disk_search:text_search(Dir,<<"redire">>,10,exact)),
            ?assertMatch({[_],_},ecai_disk_search:text_search(Dir,<<"internationaliz">>,10,bool_prefix)),
            {ok,Source} = ecai_source_retrieval:disk(Dir,1),
            ?assertEqual(Text,maps:get(text,Source)),
            ?assertEqual(verified_sha256,maps:get(integrity,Source)),
            [Seg] = ecai_disk_manifest:list_segments(Dir),
            {ok,Bytes} = file:read_file(Seg),
            ?assertMatch(<<"ECS1",_/binary>>,Bytes),
            Hash = crypto:hash(sha256,Bytes),
            _ = ecai_disk_search:text_search(Dir,<<"redire">>,10,bool_prefix),
            {ok,After} = file:read_file(Seg),
            ?assertEqual(Hash,crypto:hash(sha256,After))
        after ecai_disk_indexer:close(S1) end,
        ?assertMatch({[_],_},ecai_disk_search:text_search(Dir,<<"redire">>,10,bool_prefix))
    end).

and_across_segments_test() ->
    with_dir(fun(Dir) ->
        S0 = ecai_disk_indexer:new(Dir,#{max_docs => 1,flush_interval_ms => 60000}),
        S1 = ecai_disk_indexer:add_records(S0,[#{title => <<"Redirect alone">>},
             #{title => <<"Test alone">>},#{title => <<"Redirect test">>}]),
        try
            {Hs,_} = ecai_disk_search:text_search(Dir,<<"redirect te">>,1,bool_prefix),
            ?assertEqual([3],[maps:get(doc_id,H) || H <- Hs])
        after ecai_disk_indexer:close(S1) end
    end).

disk_range_limits_and_empty_dictionary_test() ->
    with_dir(fun(Dir) ->
        ok = ecai_disk_segment:write(Dir,"empty.ecs",#{}),
        {ok,Empty} = ecai_disk_segment:open(filename:join(Dir,"empty.ecs")),
        try ?assertEqual({[],false},ecai_disk_segment:prefix_terms(Empty,<<"title:re">>,1))
        after ecai_disk_segment:close(Empty) end,
        ok = ecai_disk_segment:write(Dir,"range.ecs",#{<<"title:redirect">> => [1,2],
            <<"title:redirection">> => [3],<<"title:rectangle">> => [4]}),
        {ok,Seg} = ecai_disk_segment:open(filename:join(Dir,"range.ecs")),
        try
            ?assertEqual({[<<"title:redirect">>],true},ecai_disk_segment:prefix_terms(Seg,<<"title:redire">>,1)),
            ?assertEqual({[1],true},ecai_disk_segment:get_postings(Seg,<<"title:redirect">>,1)),
            ?assertEqual({[],false},ecai_disk_segment:prefix_terms(Seg,<<"title:zzz">>,1))
        after ecai_disk_segment:close(Seg) end
    end).

unpublished_batch_not_visible_test() ->
    with_dir(fun(Dir) ->
        S0 = ecai_disk_indexer:new(Dir,#{max_docs => 100,flush_interval_ms => 60000}),
        S1 = ecai_disk_indexer:add_records(S0,[#{title => <<"Redirect test">>}]),
        try ?assertMatch({[],_},ecai_disk_search:text_search(Dir,<<"redire">>,10,bool_prefix))
        after ecai_disk_indexer:close(S1) end,
        ?assertMatch({[_],_},ecai_disk_search:text_search(Dir,<<"redire">>,10,bool_prefix))
    end).

private_directory_rejected_test() ->
    with_dir(fun(Dir) ->
        Saved = application:get_env(ecai,private_corpora),
        try
            application:set_env(ecai,private_corpora,#{<<"secret">> => #{base_dir => Dir}}),
            ?assertError(private_index_requires_authorized_api,
                ecai_disk_search:text_search(Dir,<<"redire">>,10,bool_prefix))
        after restore(private_corpora,Saved) end
    end).

invalid_query_fails_before_backends_test() ->
    ?assertEqual({error,invalid_query},ecai_knowledge:search(<<"\t">>)),
    ?assertEqual({error,invalid_matching},ecai_knowledge:search(<<"redire">>,#{matching => fuzzy})).

%% Uses the production snapshot writer / manifest hash checks. Like the
%% existing shard/proof suites, this needs the repository's ECAI NIF build.
verified_snapshot_shard_prefix_test() ->
    with_dir(fun(Dir) ->
        Ctx = ecai_search:set_opts(ecai_search:new(),#{root_mode => deferred}),
        Snap = filename:join(Dir,"legacy-terms-v1.etf"),
        try
            ok = ecai_search:add_record(Ctx,<<"redirect">>,#{title => <<"Redirect test">>}),
            ok = ecai_search:save(Ctx,Snap)
        after ecai_search:wipe(Ctx) end,
        {ok,Bytes} = file:read_file(Snap),
        Sha = ecai_index_job_codec:id_hex(crypto:hash(sha256,Bytes)),
        Shard = #{ordinal => 1,job_id => <<"prefix-test-job">>,snapshot_sha256 => Sha,
            snapshot_path => list_to_binary(Snap)},
        Identity = #{schema => <<"ecai-shard-index/v1">>,group_id => <<"prefix-test">>,
            original_spec_sha256 => binary:copy(<<"0">>,64),
            shards => [maps:with([ordinal,snapshot_sha256,job_id],Shard)]},
        Root = ecai_index_job_codec:id_hex(crypto:hash(sha256,ecai_index_job_codec:canonical_binary(Identity))),
        Manifest = filename:join(Dir,"manifest.etf"),
        ok = file:write_file(Manifest,term_to_binary(Identity#{shards => [Shard],index_root => Root})),
        Q = #{knowledge_query => <<"redire">>,matching => bool_prefix},
        {ok,Result} = ecai_index_shards:search(Manifest,Q,10,#{include_proofs => false}),
        [Hit] = maps:get(results,Result),
        ?assertEqual(<<"redirect">>,maps:get(doc_id,Hit)),
        ?assertEqual(1,maps:get(shard_ordinal,Hit)),
        ?assertEqual(Root,maps:get(index_root,Result)),
        {ok,Absent} = ecai_index_shards:search(Manifest,Q#{knowledge_query => <<"redirect xyz">>},10,#{include_proofs => false}),
        ?assertEqual([],maps:get(results,Absent)),
        {ok,Unchanged} = file:read_file(Snap),
        ?assertEqual(Bytes,Unchanged),
        ok = file:write_file(Snap,<<Bytes/binary,0>>),
        ?assertEqual({error,snapshot_hash_mismatch},ecai_index_shards:search(Manifest,Q,10,#{include_proofs => false}))
    end).

funded_manifest_owner_filter_unchanged_test() ->
    %% Seed only the read-only callback's state; do not start a payment runner.
    State = {st,undefined,#{jobs => #{
        <<"a">> => #{id => <<"a">>,owner => <<"alice">>,manifest => #{path => <<"alice.etf">>}},
        <<"b">> => #{id => <<"b">>,owner => <<"bob">>,manifest => #{path => <<"bob.etf">>}}
    }},undefined,undefined,undefined},
    {reply,[Alice],State} = ecai_index_pool:handle_call({knowledge_manifests,<<"alice">>},unused,State),
    ?assertEqual(<<"alice.etf">>,maps:get(path,Alice)),
    ?assertEqual([],ecai_index_pool:knowledge_manifests(undefined)),
    ?assertMatch({reply,[],State},ecai_index_pool:handle_call({knowledge_manifests,<<"outsider">>},unused,State)).

%% Real Cowboy route + JSON request/response; the lightweight registered
%% process supplies only get_ctx. Search, indexing and source reads are real.
http_redire_regression_test_() ->
    {timeout,30,fun() -> with_dir(fun(Dir) ->
        ?assertEqual(undefined,whereis(ecai_search_server)),
        Saved = application:get_env(ecai,knowledge_disk_indexes),
        application:set_env(ecai,knowledge_disk_indexes,[]),
        Ctx = ecai_search:set_opts(ecai_search:new(),#{root_mode => deferred}),
        Text = <<"Redirect test retained source">>,
        Record = #{title => <<"Redirect test">>,text => Text,source_text => Text,
            source_sha256 => ecai_index_job_codec:id_hex(crypto:hash(sha256,Text)),
            source_bytes => byte_size(Text),source_complete => true,
            source_representation => <<"test_utf8">>},
        Accessor = spawn_link(fun() -> context_accessor(Ctx) end),
        true = register(ecai_search_server,Accessor),
        try
            ok = ecai_search:add_record(Ctx,<<"redirect-test">>,Record),
            ok = ecai_search:add_record(Ctx,<<"shorter-prefix">>,#{title => <<"Red rectangle">>}),
            {ok,_} = application:ensure_all_started(cowboy),
            {ok,_} = application:ensure_all_started(inets),
            Dispatch = cowboy_router:compile([{'_',[
                {"/ecai/knowledge/search",ecai_knowledge_http,#{action => search}},
                {"/ecai/knowledge/source",ecai_knowledge_http,#{action => source}}
            ]}]),
            Listener = ecai_knowledge_prefix_test_listener,
            {ok,_} = cowboy:start_clear(Listener,[{ip,{127,0,0,1}},{port,0}],
                #{env => #{dispatch => Dispatch}}),
            try
                Port = ranch:get_port(Listener),
                {200,Body} = post(Port,"search",#{<<"q">> => <<"redire">>},[]),
                ?assertEqual(<<"bool_prefix">>,maps:get(<<"matching">>,Body)),
                [Hit] = maps:get(<<"results">>,Body),
                ?assertEqual(<<"redirect-test">>,maps:get(<<"doc_id">>,Hit)),
                {200,Multi} = post(Port,"search",#{<<"q">> => <<"redirect te">>},[]),
                ?assertEqual(1,maps:get(<<"count">>,Multi)),
                {200,Absent} = post(Port,"search",#{<<"q">> => <<"redirect xyz">>},[]),
                ?assertEqual([],maps:get(<<"results">>,Absent)),
                {200,Exact} = post(Port,"search",#{<<"q">> => <<"redire">>,<<"matching">> => <<"exact">>},[]),
                ?assertEqual([],maps:get(<<"results">>,Exact)),
                {200,Recovered} = post(Port,"source",#{<<"source_ref">> => maps:get(<<"source_ref">>,Hit)},[]),
                ?assertEqual(Text,maps:get(<<"text">>,Recovered)),
                ?assertEqual(<<"verified_sha256">>,maps:get(<<"integrity">>,Recovered)),
                {401,_} = post(Port,"search",#{<<"q">> => <<"redire">>},[{"authorization","Basic rejected"}]),
                {400,_} = post(Port,"search",#{<<"q">> => <<"redire">>,<<"matching">> => <<"fuzzy">>},[]),
                {200,Private} = post(Port,"search",#{<<"q">> => <<"redire">>,
                    <<"owner">> => <<"someone-else">>,<<"principal">> => <<"someone-else">>},[]),
                ?assertEqual([<<"shared">>],lists:usort([maps:get(<<"index">>,H) || H <- maps:get(<<"results">>,Private)])),
                %% Also exercise the disk adapter through the unified API.
                S0 = ecai_disk_indexer:new(Dir,#{max_docs => 1}),
                S1 = ecai_disk_indexer:add_records(S0,[#{title => <<"Redirect disk">>}]),
                ok = ecai_disk_indexer:close(S1),
                application:set_env(ecai,knowledge_disk_indexes,[#{id => <<"disk-test">>,dir => Dir}]),
                {200,DiskBody} = post(Port,"search",#{<<"q">> => <<"redire">>},[]),
                ?assertEqual([<<"disk-test">>,<<"shared">>],lists:sort([maps:get(<<"index">>,H) || H <- maps:get(<<"results">>,DiskBody)]))
            after cowboy:stop_listener(Listener) end
        after
            Mon = erlang:monitor(process,Accessor), Accessor ! stop,
            receive {'DOWN',Mon,process,Accessor,_} -> ok after 2000 -> exit(Accessor,kill) end,
            ecai_search:wipe(Ctx), restore(knowledge_disk_indexes,Saved)
        end
    end) end}.

context_accessor(Ctx) ->
    receive
        {'$gen_call',From,get_ctx} -> gen_server:reply(From,Ctx),context_accessor(Ctx);
        stop -> ok
    end.
post(Port,Action,Body,Headers) ->
    URL = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/ecai/knowledge/" ++ Action,
    {ok,{{_,Code,_},_,Bytes}} = httpc:request(post,{URL,Headers,"application/json",jsx:encode(Body)},
        [{timeout,5000}],[{body_format,binary}]),
    {Code,jsx:decode(Bytes,[return_maps])}.

with_dir(Fun) ->
    Root = case os:getenv("TMPDIR") of false -> "/tmp"; P -> P end,
    Dir = filename:join(Root,"ecai-prefix-" ++ integer_to_list(erlang:unique_integer([positive,monotonic]))),
    ok = file:make_dir(Dir),
    try Fun(Dir) after file:del_dir_r(Dir) end.
restore(K,undefined) -> application:unset_env(ecai,K);
restore(K,{ok,V}) -> application:set_env(ecai,K,V).
