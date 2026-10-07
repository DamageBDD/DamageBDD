-module(nosternity_search_tests).
-include_lib("eunit/include/eunit.hrl").

%% Real JSX serialization, BIP-340 signatures, ECAI index and native curve
%% mapping are exercised. No fake crypto, event verifier or search backend.
search_relay_test_() ->
    {timeout, 90, [
        ?_test(with_relay(fun signed_ingress/0)),
        ?_test(with_relay(fun filter_validation/0)),
        ?_test(with_relay(fun union_and_filtered_limit/0)),
        ?_test(with_relay(fun ranked_search/0)),
        ?_test(with_relay(fun multi_term_ranking/0)),
        ?_test(with_relay(fun replacement_and_tie/0)),
        ?_test(with_relay(fun address_replacement/0)),
        ?_test(with_relay(fun deletion_author_and_delay/0)),
        ?_test(with_relay(fun address_deletion_cutoff/0)),
        ?_test(with_relay(fun expiry/0)),
        ?_test(with_relay(fun ephemeral_live_generation/0)),
        ?_test(with_relay(fun durability/0)),
        ?_test(with_relay(fun capacity/0)),
        ?_test(with_relay(fun websocket_wire/0)),
        ?_test(with_relay(fun websocket_guards/0))
    ]}.

with_relay(Fun) ->
    Dir = filename:join(temp_dir(), "nosternity-search-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    File = filename:join(Dir, "events.dets"),
    Names = [search_store_file, ae_event_store_rehydrate, search_max_events],
    Saved = [{K, application:get_env(nosternity, K)} || K <- Names],
    application:set_env(nosternity, search_store_file, File),
    application:set_env(nosternity, ae_event_store_rehydrate, false),
    application:set_env(nosternity, search_max_events, 10000),
    try
        ?assertMatch({_, _, _}, ecai:hash_to_curve(<<"nosternity-real-nif-test">>)),
        start(),
        Fun()
    after
        stop(),
        lists:foreach(fun
            ({K, undefined}) -> application:unset_env(nosternity, K);
            ({K, {ok, V}}) -> application:set_env(nosternity, K, V)
        end, Saved),
        file:del_dir_r(Dir),
        flush_relay_messages()
    end.

temp_dir() -> case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end.
start() -> {ok, Pid} = nosternity_relay:start_link(), unlink(Pid), ok.
stop() ->
    case whereis(nosternity_relay) of
        undefined -> ok;
        Pid -> gen_server:stop(Pid, normal, 30000)
    end.
restart() -> stop(), start().
flush_relay_messages() ->
    receive
        {nosternity_event, _, _, _} -> flush_relay_messages();
        {nosternity_closed, _, _} -> flush_relay_messages()
    after 0 -> ok end.

signed_ingress() ->
    E = event(1, <<"canonical verified note">>, [], 1, 1700000000),
    ?assertEqual({ok, E}, nosternity_filter:validate_event(E)),
    ?assertEqual(ok, nosternity_relay:publish_event(nosternity_filter:wire(E))),
    ?assertEqual(ok, nosternity_relay:publish_event(E)),
    ?assertEqual([id(E)], ids([#{}])),
    ?assertMatch({error, _}, nosternity_filter:validate_event(E#{content => <<"changed">>})),
    ?assertEqual({error, invalid_event}, nosternity_relay:publish_event(E#{sig => binary:copy(<<"0">>, 128)})),
    ?assertEqual({error, invalid_event}, nosternity_relay:publish_event(maps:remove(tags, E))),
    ?assertEqual({error, invalid_event}, nosternity_relay:publish_event(E#{tags => [[<<"t">>, 123]]})),
    ?assertEqual({error, invalid_event}, nosternity_relay:publish_event(E#{content => <<255>>})),
    ?assertEqual({error, invalid_event}, nosternity_relay:publish_event(event(1, <<"future">>, [], 1, erlang:system_time(second)+301))),
    ?assertEqual([id(E)], ids([#{}])).

filter_validation() ->
    lists:foreach(fun(Fs) ->
        ?assertEqual({error, invalid_filters}, nosternity_relay:search(Fs))
    end, [[], #{}, [false], [#{<<"authors">> => [<<"bad">>]}],
        [#{<<"limit">> => -1}], [#{<<"limit">> => <<"1">>}],
        [#{<<"kinds">> => [65536]}], [#{<<"search">> => <<255>>}],
        [#{<<"#t">> => [1]}], [#{<<"unknown">> => true}],
        lists:duplicate(9, #{})]),
    ?assertEqual({ok, [#{}]}, nosternity_filter:valid_filters([#{}])),
    ?assertEqual(<<"hello world">>, nosternity_filter:search_text(<<"hello language:en world include:spam">>)).

union_and_filtered_limit() ->
    Want = event(1, <<"needle alpha">>, [[<<"t">>, <<"keep">>]], 1, 1700000000),
    OtherAuthor = event(1, <<"needle alpha beta">>, [[<<"t">>, <<"keep">>]], 2, 1700000010),
    OtherKind = event(30023, <<"needle alpha beta">>, [[<<"d">>, <<"article">>], [<<"t">>, <<"keep">>]], 1, 1700000020),
    OtherTag = event(1, <<"needle alpha beta">>, [[<<"t">>, <<"drop">>]], 1, 1700000030),
    publish([Want, OtherAuthor, OtherKind, OtherTag]),
    F = #{<<"search">> => <<"needle alpha beta">>, <<"authors">> => [pub(Want)],
        <<"kinds">> => [1], <<"#t">> => [<<"keep">>], <<"limit">> => 1},
    ?assertEqual([id(Want)], ids([F])),
    ?assertEqual([id(Want)], ids([F, #{<<"ids">> => [id(Want)]}])),
    ?assertEqual(lists:sort([id(Want), id(OtherAuthor)]),
        lists:sort(ids([#{<<"ids">> => [id(Want)]}, #{<<"ids">> => [id(OtherAuthor)]}]))),
    ?assertEqual([id(Want)], ids([#{<<"since">> => 1700000000, <<"until">> => 1700000000}])),
    ?assertEqual([], ids([#{<<"limit">> => 0}])).

ranked_search() ->
    OlderBest = event(1, <<"beta">>, [], 1, 1700000000),
    NewerWeak = event(1, <<"alpha only">>, [], 1, 1700000010),
    Private = event(4, <<"alpha beta secret">>, [], 1, 1700000020),
    OtherWeak = event(1, <<"alpha common">>, [], 2, 1700000005),
    publish([OlderBest, NewerWeak, Private, OtherWeak]),
    Rs = results([#{<<"search">> => <<"alpha beta language:en">>}]),
    ?assertEqual([id(OlderBest), id(NewerWeak), id(OtherWeak)], [id(maps:get(event, R)) || R <- Rs]),
    [R1, R2 | _] = Rs,
    ?assert(maps:get(score, R1) > maps:get(score, R2)),
    ?assertEqual([], ids([#{<<"search">> => <<"secret">>}])).

multi_term_ranking() ->
    OlderBest = event(1, <<"alpha beta">>, [], 1, 1700000000),
    NewerWeak = event(1, <<"alpha only">>, [], 1, 1700000010),
    publish([OlderBest, NewerWeak]),
    Rs = results([#{<<"search">> => <<"alpha beta">>}]),
    ?assertEqual([id(OlderBest), id(NewerWeak)], [id(maps:get(event, R)) || R <- Rs]),
    [R1, R2] = Rs,
    ?assert(maps:get(score, R1) > maps:get(score, R2)).

replacement_and_tie() ->
    Old = event(0, <<"old profile">>, [], 1, 1700000000),
    New = event(0, <<"new profile">>, [], 1, 1700000010),
    publish([Old, New]),
    ?assertEqual([id(New)], ids([#{<<"kinds">> => [0]}])),
    ?assertEqual([], ids([#{<<"search">> => <<"old">>}])),
    ?assertEqual({error, superseded}, nosternity_relay:publish_event(Old)),
    A = event(0, <<"tie a">>, [], 1, 1700000020),
    B = event(0, <<"tie b">>, [], 1, 1700000020),
    [Winner, Loser] = lists:sort(fun(X,Y) -> id(X) < id(Y) end, [A,B]),
    publish([Loser, Winner]),
    ?assertEqual({error, superseded}, nosternity_relay:publish_event(Loser)),
    ?assertEqual([id(Winner)], ids([#{<<"kinds">> => [0]}])),
    restart(),
    ?assertEqual([id(Winner)], ids([#{<<"kinds">> => [0]}])).

address_replacement() ->
    A = event(30023, <<"first article">>, [[<<"d">>, <<"a">>]], 1, 1700000000),
    B = event(30023, <<"other article">>, [[<<"d">>, <<"b">>]], 1, 1700000001),
    NewA = event(30023, <<"updated article">>, [[<<"d">>, <<"a">>]], 1, 1700000002),
    publish([A, B, NewA]),
    ?assertEqual(lists:sort([id(B), id(NewA)]), lists:sort(ids([#{<<"kinds">> => [30023]}]))),
    ?assertEqual({error, superseded}, nosternity_relay:publish_event(A)).

deletion_author_and_delay() ->
    E = event(1, <<"delete me">>, [], 1, 1700000000),
    Wrong = event(5, <<>>, [[<<"e">>, id(E)]], 2, 1700000010),
    publish([E, Wrong]),
    ?assertEqual([id(E)], ids([#{<<"ids">> => [id(E)]}])),
    Right = event(5, <<>>, [[<<"e">>, id(E)]], 1, 1700000020),
    publish([Right]),
    ?assertEqual([], ids([#{<<"ids">> => [id(E)]}])),
    ?assertEqual([], ids([#{<<"search">> => <<"delete">>}])),
    ?assertEqual({error, deleted}, nosternity_relay:publish_event(E)),
    Delayed = event(1, <<"delayed deleted note">>, [], 1, 1700000030),
    BeforeArrival = event(5, <<>>, [[<<"e">>, id(Delayed)]], 1, 1700000040),
    publish([BeforeArrival]),
    ?assertEqual({error, deleted}, nosternity_relay:publish_event(Delayed)),
    restart(),
    ?assertEqual({error, deleted}, nosternity_relay:publish_event(E)),
    ?assertEqual({error, deleted}, nosternity_relay:publish_event(Delayed)).

address_deletion_cutoff() ->
    Old = event(30023, <<"old address">>, [[<<"d">>, <<"x:y">>]], 1, 1700000000),
    Addr = nosternity_filter:address(Old),
    Wrong = event(5, <<>>, [[<<"a">>, Addr]], 2, 1700000010),
    publish([Old, Wrong]),
    ?assertEqual([id(Old)], ids([#{<<"kinds">> => [30023]}])),
    Deletion = event(5, <<>>, [[<<"a">>, Addr]], 1, 1700000020),
    publish([Deletion]),
    ?assertEqual([], ids([#{<<"kinds">> => [30023]}])),
    AtCutoff = event(30023, <<"at cutoff">>, [[<<"d">>, <<"x:y">>]], 1, 1700000020),
    ?assertEqual({error, deleted}, nosternity_relay:publish_event(AtCutoff)),
    New = event(30023, <<"new address">>, [[<<"d">>, <<"x:y">>]], 1, 1700000021),
    publish([New]),
    restart(),
    ?assertEqual([id(New)], ids([#{<<"kinds">> => [30023]}])),
    ?assertEqual({error, deleted}, nosternity_relay:publish_event(Old)).

expiry() ->
    Now = erlang:system_time(second),
    Expired = event(1, <<"expired">>, [[<<"expiration">>, integer_to_binary(Now)]], 1, Now-1),
    ?assertEqual({error, expired}, nosternity_relay:publish_event(Expired)),
    Bad = event(1, <<"bad expiry">>, [[<<"expiration">>, <<"never">>]], 1, Now),
    ?assertEqual({error, invalid_event}, nosternity_relay:publish_event(Bad)),
    Soon = event(1, <<"vanishes">>, [[<<"expiration">>, integer_to_binary(Now+2)]], 1, Now),
    publish([Soon]),
    ?assertEqual([id(Soon)], ids([#{<<"search">> => <<"vanishes">>}])),
    receive after 2100 -> ok end,
    ?assertEqual([], ids([#{<<"search">> => <<"vanishes">>}])),
    restart(),
    ?assertEqual([], ids([#{<<"ids">> => [id(Soon)]}])).

ephemeral_live_generation() ->
    G1 = make_ref(),
    ?assertMatch({ok, #{results := []}}, nosternity_relay:subscribe(<<"live">>, [#{<<"limit">> => 0}], G1)),
    E = event(20001, <<"ephemeral">>, [], 1, 1700000000),
    publish([E]),
    receive {nosternity_event, <<"live">>, G1, E} -> ok after 1000 -> ?assert(false) end,
    ?assertEqual([], ids([#{<<"ids">> => [id(E)]}])),
    G2 = make_ref(),
    ?assertMatch({ok, _}, nosternity_relay:subscribe(<<"live">>, [#{<<"kinds">> => [1], <<"limit">> => 0}], G2)),
    E2 = event(1, <<"new generation">>, [], 1, 1700000010),
    publish([E2]),
    receive {nosternity_event, <<"live">>, G2, E2} -> ok after 1000 -> ?assert(false) end,
    receive {nosternity_event, <<"live">>, G1, _} -> ?assert(false) after 0 -> ok end,
    ok = nosternity_relay:unsubscribe(<<"live">>),
    publish([event(1, <<"unsubscribed">>, [], 1, 1700000020)]),
    receive {nosternity_event, <<"live">>, _, _} -> ?assert(false) after 0 -> ok end,
    restart(),
    ?assertEqual([], ids([#{<<"ids">> => [id(E)]}])).

durability() ->
    E = event(1, <<"persistent searchable note">>, [[<<"t">>, <<"durable">>]], 1, 1700000000),
    publish([E]),
    Before = results([#{<<"search">> => <<"persistent">>}]),
    restart(),
    ?assertEqual(Before, results([#{<<"search">> => <<"persistent">>}])),
    ?assertEqual([id(E)], ids([#{<<"#t">> => [<<"durable">>]}])).

capacity() ->
    application:set_env(nosternity, search_max_events, 1),
    E = event(1, <<"one">>, [], 1, 1700000000),
    publish([E]),
    ?assertEqual(ok, nosternity_relay:publish_event(E)),
    ?assertEqual({error, capacity}, nosternity_relay:publish_event(event(1, <<"two">>, [], 1, 1700000001))),
    ?assertEqual(ok, nosternity_relay:publish_event(event(20001, <<"transient">>, [], 1, 1700000002))),
    ?assertEqual([id(E)], ids([#{}])),
    %% A deletion at the limit is admitted because it replaces its target.
    Deletion = event(5, <<>>, [[<<"e">>, id(E)]], 1, 1700000010),
    publish([Deletion]),
    ?assertEqual([], ids([#{<<"ids">> => [id(E)]}])).

websocket_wire() ->
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    Name = make_ref(),
    Dispatch = cowboy_router:compile([{'_', [{"/nostr", nosternity_websocket, #{}}]}]),
    {ok, _} = cowboy:start_clear(Name, [{ip, {127,0,0,1}}, {port, 0}], #{env => #{dispatch => Dispatch}}),
    Port = ranch:get_port(Name),
    try
        {ok, #{status := 200, headers := Headers, body := InfoBody}} = damage_gun:get(
            "127.0.0.1", Port, "/nostr", [{<<"accept">>, <<"application/nostr+json">>}],
            #{transport => tcp, proxy => direct, timeout => 3000}),
        ?assertEqual(<<"*">>, proplists:get_value(<<"access-control-allow-origin">>, Headers)),
        ?assertEqual(<<"application/nostr+json">>, proplists:get_value(<<"content-type">>, Headers)),
        ?assertEqual([1,9,11,40,50], maps:get(<<"supported_nips">>, jsx:decode(InfoBody, [return_maps]))),
        {P1,R1} = ws_open(Port),
        {P2,R2} = ws_open(Port),
        try
            E = event(1, <<"wire indexed evidence">>, [], 1, 1700000000),
            ws_send(P1,R1,[<<"EVENT">>,nosternity_filter:wire(E)]),
            ?assertEqual([<<"OK">>,id(E),true,<<>>], ws_receive(P1,R1)),
            ws_send(P1,R1,[<<"REQ">>,<<"shared">>,#{<<"search">> => <<"evidence">>},#{<<"ids">> => [id(E)]}]),
            ?assertEqual([<<"EVENT">>,<<"shared">>,nosternity_filter:wire(E)], ws_receive(P1,R1)),
            ?assertEqual([<<"EOSE">>,<<"shared">>], ws_receive(P1,R1)),
            ws_send(P1,R1,[<<"REQ">>,<<"shared">>,#{<<"kinds">> => [1], <<"limit">> => 0}]),
            ?assertEqual([<<"EOSE">>,<<"shared">>], ws_receive(P1,R1)),
            ws_send(P2,R2,[<<"REQ">>,<<"shared">>,#{<<"kinds">> => [20001], <<"limit">> => 0}]),
            ?assertEqual([<<"EOSE">>,<<"shared">>], ws_receive(P2,R2)),
            Ephemeral = event(20001, <<"live only">>, [], 1, 1700000001),
            ws_send(P1,R1,[<<"EVENT">>,nosternity_filter:wire(Ephemeral)]),
            ?assertEqual([<<"OK">>,id(Ephemeral),true,<<>>], ws_receive(P1,R1)),
            ?assertEqual([<<"EVENT">>,<<"shared">>,nosternity_filter:wire(Ephemeral)], ws_receive(P2,R2)),
            ?assertEqual([], ids([#{<<"ids">> => [id(Ephemeral)]}])),
            ws_send(P2,R2,[<<"CLOSE">>,<<"shared">>]),
            %% A subsequent request provides an ordering barrier for CLOSE.
            ws_send(P2,R2,[<<"REQ">>,<<"bad">>,#{<<"limit">> => -1}]),
            ?assertMatch([<<"CLOSED">>,<<"bad">>,_], ws_receive(P2,R2)),
            E2 = event(1, <<"scoped connection">>, [], 1, 1700000002),
            ws_send(P2,R2,[<<"EVENT">>,nosternity_filter:wire(E2)]),
            ?assertEqual([<<"OK">>,id(E2),true,<<>>], ws_receive(P2,R2)),
            ?assertEqual([<<"EVENT">>,<<"shared">>,nosternity_filter:wire(E2)], ws_receive(P1,R1)),
            ws_send(P2,R2,[<<"EVENT">>,nosternity_filter:wire(E2#{sig => binary:copy(<<"0">>,128)})]),
            ?assertMatch([<<"OK">>,_,false,_], ws_receive(P2,R2)),
            ws_send(P2,R2,[<<"unknown">>]),
            ?assertMatch([<<"NOTICE">>,_], ws_receive(P2,R2)),
            gun:ws_send(P2,R2,ping),
            ws_send(P2,R2,[<<"REQ">>,<<"after-ping">>,#{<<"limit">> => 0}]),
            ?assertEqual([<<"EOSE">>,<<"after-ping">>], ws_receive(P2,R2))
        after gun:close(P1),gun:close(P2) end
    after cowboy:stop_listener(Name) end.

ws_open(Port) ->
    {ok, Pid} = gun:open("127.0.0.1", Port, #{transport => tcp, protocols => [http]}),
    {ok, http} = gun:await_up(Pid, 3000),
    Ref = gun:ws_upgrade(Pid, "/nostr"),
    receive {gun_upgrade,Pid,Ref,[<<"websocket">>],_} -> {Pid,Ref}
    after 3000 -> error(websocket_upgrade_timeout) end.
ws_send(Pid,Ref,M) -> gun:ws_send(Pid,Ref,{text,jsx:encode(M)}).
ws_receive(Pid,Ref) ->
    receive
        {gun_ws,Pid,Ref,{text,B}} -> jsx:decode(B,[return_maps]);
        {gun_ws,Pid,Ref,pong} -> ws_receive(Pid,Ref);
        {gun_ws,Pid,Ref,{pong,_}} -> ws_receive(Pid,Ref)
    after 3000 -> error(websocket_receive_timeout) end.

websocket_guards() ->
    E = event(1, <<"quota event">>, [], 1, 1700000000),
    S = #{subscriptions => #{}, count => 120, window => erlang:monotonic_time(millisecond)},
    {reply,{text,Rejected},_} = nosternity_websocket:websocket_handle(
        {text,jsx:encode([<<"EVENT">>,nosternity_filter:wire(E)])},S),
    ?assertMatch([<<"OK">>,_,false,<<"rate-limited:",_/binary>>],jsx:decode(Rejected)),
    {reply,{text,Closed},_} = nosternity_websocket:websocket_handle(
        {text,jsx:encode([<<"REQ">>,<<"quota">>,#{}])},S),
    ?assertMatch([<<"CLOSED">>,<<"quota">>,<<"rate-limited:",_/binary>>],jsx:decode(Closed)),
    ?assertEqual([],ids([#{}])),
    G = make_ref(),
    Live = S#{subscriptions => #{<<"s">> => G}},
    Expired = E#{tags => [[<<"expiration">>,integer_to_binary(erlang:system_time(second)-1)]]},
    ?assertEqual({ok,Live},nosternity_websocket:websocket_info({nosternity_event,<<"s">>,G,Expired},Live)),
    ?assertEqual({ok,Live},nosternity_websocket:websocket_info({nosternity_event,<<"s">>,make_ref(),E},Live)).

publish(Events) -> lists:foreach(fun(E) -> ?assertEqual(ok, nosternity_relay:publish_event(E)) end, Events).
results(Fs) -> {ok, #{results := Rs, total := N}} = nosternity_relay:search(Fs), ?assertEqual(length(Rs), N), Rs.
ids(Fs) -> [id(maps:get(event, R)) || R <- results(Fs)].
id(E) -> maps:get(id, E).
pub(E) -> maps:get(pubkey, E).
event(Kind, Content, Tags, KeyNumber, Time) ->
    Key = <<KeyNumber:256>>,
    {ok, PublicKey} = nostrlib_schnorr:new_publickey(Key),
    Pubkey = damage_nostr_event:lower_hex(PublicKey),
    Hash = crypto:hash(sha256, jsx:encode([0, Pubkey, Time, Kind, Tags, Content])),
    {ok, Sig} = nostrlib_schnorr:sign(Hash, Key, <<0:256>>),
    #{id => damage_nostr_event:lower_hex(Hash), pubkey => Pubkey,
        created_at => Time, kind => Kind, tags => Tags, content => Content,
        sig => damage_nostr_event:lower_hex(Sig)}.
