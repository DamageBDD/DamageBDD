-module(nosternity_config_tests).
-include_lib("eunit/include/eunit.hrl").

defaults_and_validation_test() ->
    with_env([{enabled,true}, {search_default_limit,50}, {search_max_limit,200}], fun() ->
        ?assertEqual(ok, nosternity_config:validate()),
        ?assertEqual(50, nosternity_filter:default_limit()),
        ?assertEqual(200, nosternity_filter:max_limit()),
        with_env([{search_default_limit,201}], fun() ->
            ?assertEqual({error,{invalid_configuration,search_default_limit}}, nosternity_config:validate())
        end)
    end).

configuration_boundaries_test() ->
    lists:foreach(fun({Key,Min,Max}) ->
        lists:foreach(fun(Value) ->
            with_env([{Key,Value}], fun() -> ?assertEqual(Value, nosternity_config:get(Key)) end)
        end, [Min,Max]),
        lists:foreach(fun(Value) ->
            with_env([{Key,Value}], fun() ->
                ?assertError({invalid_configuration,Key}, nosternity_config:get(Key))
            end)
        end, [Min-1,Max+1,1.0,<<"1">>,infinity])
    end, [
        {port,0,65535}, {http_num_acceptors,1,100}, {http_max_connections,1,100000},
        {http_idle_timeout_ms,1000,86400000}, {http_request_timeout_ms,1000,86400000},
        {websocket_idle_timeout_ms,1000,86400000}, {max_subscriptions,1,1024},
        {max_total_subscriptions,1,100000}, {max_filters,1,64}, {max_filter_values,1,4096},
        {search_default_limit,1,10000}, {search_max_limit,1,10000}, {search_max_events,1,100000},
        {websocket_messages_per_minute,1,100000}, {subscriber_queue_max,1,10000},
        {ae_event_store_hydrate_page_size,1,100}, {ae_event_store_retry_ms,1000,3600000}
    ]),
    lists:foreach(fun(Key) ->
        lists:foreach(fun(Value) -> with_env([{Key,Value}], fun() ->
            ?assertEqual(Value, nosternity_config:get(Key)) end) end, [true,false]),
        with_env([{Key,<<"true">>}], fun() ->
            ?assertError({invalid_configuration,Key}, nosternity_config:get(Key)) end)
    end, [enabled,http_enabled,websocket_enabled,nostr_clients_enabled]),
    lists:foreach(fun(Value) -> with_env([{ip,Value}], fun() ->
        ?assertEqual(Value,nosternity_config:get(ip)) end) end,
        [{0,0,0,0},{127,0,0,1},{0,0,0,0,0,0,0,1},{16#ffff,0,0,0,0,0,0,1}]),
    lists:foreach(fun(Value) -> with_env([{ip,Value}], fun() ->
        ?assertError({invalid_configuration,ip},nosternity_config:get(ip)) end) end,
        ["127.0.0.1",<<"0.0.0.0">>,{256,0,0,1},{-1,0,0,1},{127,0,0},{0,0,0,0,0,0,0,65536}]),
    with_env([{enabled,true},{ip,"bad"}], fun() ->
        ?assertEqual({error,{invalid_configuration,ip}},nosternity_config:validate()) end).

configured_filters_and_discovery_test() ->
    with_env([{max_filters,1},{max_filter_values,2},{max_subscriptions,3},
              {search_default_limit,4},{search_max_limit,7}], fun() ->
        ?assertEqual(ok,nosternity_config:validate()),
        ?assertEqual({ok,[#{}]},nosternity_filter:valid_filters([#{}])),
        ?assertEqual({error,invalid_filters},nosternity_filter:valid_filters([#{},#{}])),
        ?assertMatch({ok,_},nosternity_filter:valid_filters([#{<<"kinds">>=>[1,2]}])),
        ?assertEqual({error,invalid_filters},nosternity_filter:valid_filters([#{<<"kinds">>=>[1,2,3]}])),
        #{limitation:=Limits}=nosternity_websocket:relay_info(),
        ?assertEqual(3,maps:get(max_subscriptions,Limits)),
        ?assertEqual(4,maps:get(default_limit,Limits)),
        ?assertEqual(7,maps:get(max_limit,Limits)),
        ?assertEqual(64,maps:get(max_subid_length,Limits)),
        ?assertEqual({ok,[#{<<"search">>=><<"needle">>,<<"limit">>=>4}]},
            nosternity_search_http:query_filters([{<<"q">>,<<"needle">>}])),
        ?assertMatch({ok,_},nosternity_search_http:query_filters(
            [{<<"q">>,<<"needle">>},{<<"limit">>,<<"7">>}])),
        ?assertEqual({error,invalid_query},nosternity_search_http:query_filters(
            [{<<"q">>,<<"needle">>},{<<"limit">>,<<"8">>}]))
    end).

configured_websocket_quota_test() ->
    with_env([{websocket_messages_per_minute,1}],fun() ->
        S=#{subscriptions=>#{},count=>0,window=>erlang:monotonic_time(millisecond)},
        {reply,{text,First},S1}=nosternity_websocket:websocket_handle({text,<<"[]">>},S),
        ?assertEqual([<<"NOTICE">>,<<"invalid: expected EVENT, REQ or CLOSE">>],jsx:decode(First)),
        {reply,{text,Second},_}=nosternity_websocket:websocket_handle({text,<<"[]">>},S1),
        ?assertEqual([<<"NOTICE">>,<<"rate-limited: 1 messages per minute">>],jsx:decode(Second))
    end).

configured_relay_test_() -> {timeout,30,fun configured_relay/0}.
configured_relay() ->
    Dir=filename:join(temp_dir(),"nosternity-config-"++integer_to_list(erlang:unique_integer([positive,monotonic]))),
    with_env([{search_store_file,filename:join(Dir,"events.dets")},
              {ae_event_store_rehydrate,false},{search_default_limit,1},{search_max_limit,2},
              {max_subscriptions,1},{max_total_subscriptions,1},{subscriber_queue_max,1}],fun() ->
        {ok,Relay}=nosternity_relay:start_link(),unlink(Relay),
        try
            lists:foreach(fun(N)->ok=nosternity_relay:publish_event(event(N)) end,[1,2,3]),
            {ok,#{total:=1}}=nosternity_relay:search([#{}]),
            {ok,#{total:=2}}=nosternity_relay:search([#{<<"limit">>=>100}]),
            {ok,_}=nosternity_relay:subscribe(<<"first">>,[#{<<"limit">>=>0}],make_ref()),
            ?assertEqual({error,subscription_limit},nosternity_relay:subscribe(<<"second">>,[#{}],make_ref())),
            %% Replacing an existing subscription remains allowed at capacity.
            {ok,_}=nosternity_relay:subscribe(<<"first">>,[#{<<"limit">>=>0}],make_ref()),
            Parent=self(),
            {Child,Ref}=spawn_monitor(fun() ->
                Parent ! {other_subscription,nosternity_relay:subscribe(<<"other">>,[#{}],make_ref())}
            end),
            receive {other_subscription,Result}->?assertEqual({error,subscription_limit},Result)
            after 3000->error(subscriber_timeout) end,
            receive {'DOWN',Ref,process,Child,normal}->ok after 3000->error(subscriber_exit_timeout) end,
            ok=nosternity_relay:unsubscribe(<<"first">>),
            slow_subscriber()
        after
            gen_server:stop(Relay,normal,30000),file:del_dir_r(Dir)
        end
    end).

slow_subscriber() ->
    Parent=self(),
    {Pid,Ref}=spawn_monitor(fun() ->
        {ok,_}=nosternity_relay:subscribe(<<"slow">>,[#{<<"limit">>=>0}],make_ref()),
        Parent ! ready,
        receive stop -> ok end
    end),
    try
        receive ready->ok after 3000->error(subscriber_timeout) end,
        ok=nosternity_relay:publish_event(event(4)),
        ok=nosternity_relay:publish_event(event(5)),
        #{subscriptions:=0}=nosternity_relay:status()
    after
        Pid ! stop,
        receive {'DOWN',Ref,process,Pid,_}->ok after 3000->exit(Pid,kill) end
    end.

disabled_websocket_keeps_discovery_test_() -> {timeout,15,fun disabled_websocket_keeps_discovery/0}.
disabled_websocket_keeps_discovery() ->
    {ok,_}=application:ensure_all_started(cowboy),
    {ok,_}=application:ensure_all_started(gun),
    with_env([{websocket_enabled,false}],fun() ->
        Name=make_ref(),
        Dispatch=cowboy_router:compile([{'_',[{"/nostr",nosternity_websocket,#{}}]}]),
        {ok,_}=cowboy:start_clear(Name,[{ip,{127,0,0,1}},{port,0}],#{env=>#{dispatch=>Dispatch}}),
        Port=ranch:get_port(Name),
        Opts=#{transport=>tcp,proxy=>direct,timeout=>3000},
        try
            {ok,#{status:=403}}=damage_gun:get("127.0.0.1",Port,"/nostr",
                [{<<"upgrade">>,<<"websocket">>}],Opts),
            {ok,#{status:=200,body:=Body}}=damage_gun:get("127.0.0.1",Port,"/nostr",[],Opts),
            ?assertEqual([1,9,11,40,50],maps:get(<<"supported_nips">>,jsx:decode(Body,[return_maps])))
        after cowboy:stop_listener(Name) end
    end).

with_env(Values,Fun) ->
    Saved=[{K,application:get_env(nosternity,K)} || {K,_}<-Values],
    lists:foreach(fun({K,V})->application:set_env(nosternity,K,V) end,Values),
    try Fun() after lists:foreach(fun
        ({K,undefined})->application:unset_env(nosternity,K);
        ({K,{ok,V}})->application:set_env(nosternity,K,V)
    end,Saved) end.

temp_dir() -> case os:getenv("TMPDIR") of false->"/tmp";D->D end.
event(N) ->
    Key = <<1:256>>,
    {ok,Public}=nostrlib_schnorr:new_publickey(Key),
    Pub=damage_nostr_event:lower_hex(Public),
    Content=integer_to_binary(N),Time=1700000000+N,
    Hash=crypto:hash(sha256,jsx:encode([0,Pub,Time,1,[],Content])),
    {ok,Sig}=nostrlib_schnorr:sign(Hash,Key),
    #{id=>damage_nostr_event:lower_hex(Hash),pubkey=>Pub,created_at=>Time,kind=>1,
      tags=>[],content=>Content,sig=>damage_nostr_event:lower_hex(Sig)}.
