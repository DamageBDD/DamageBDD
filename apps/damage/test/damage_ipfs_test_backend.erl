%% Deterministic, isolated backend for EUnit. Never contacts Kubo.
-module(damage_ipfs_test_backend).
-behaviour(gen_server).
-export([start_link/0, execute/2, mode/1, drop/1, pinned/1, calls/0]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
mode(M) -> gen_server:call(?MODULE, {mode, M}).
drop(Cid) -> gen_server:call(?MODULE, {drop, Cid}).
pinned(Cid) -> gen_server:call(?MODULE, {pinned, Cid}).
calls() -> gen_server:call(?MODULE, calls).
execute({sleep, Ms, Observer}, _) ->
    Observer ! {backend_worker, self()},
    timer:sleep(Ms),
    {ok, slept};
execute(crash, _) ->
    exit(self(), kill);
execute({echo, X}, _) ->
    {ok, X};
execute(R, _) ->
    gen_server:call(?MODULE, {execute, R}).
init([]) -> {ok, #{mode => online, pins => #{}, calls => []}}.
handle_call({mode, M}, _, S) ->
    {reply, ok, S#{mode => M}};
handle_call({drop, C}, _, S) ->
    {reply, ok, S#{pins => maps:remove(C, maps:get(pins, S))}};
handle_call({pinned, C}, _, S) ->
    {reply, maps:is_key(C, maps:get(pins, S)), S};
handle_call(calls, _, S) ->
    {reply, lists:reverse(maps:get(calls, S)), S};
handle_call({execute, R}, _, S) ->
    S1 = S#{calls => [R | maps:get(calls, S)]},
    case maps:get(mode, S) of
        offline -> {reply, {error, unavailable}, S1};
        online -> respond(R, S1)
    end;
handle_call(_, _, S) ->
    {reply, {error, unknown_request}, S}.
respond(version, S) ->
    {reply, {ok, #{<<"Version">> => <<"fake">>}}, S};
respond(identity, S) ->
    {reply, {ok, #{<<"ID">> => <<"SelfPeer">>}}, S};
respond(swarm_peers, S) ->
    {reply, {ok, #{<<"Peers">> => []}}, S};
respond({connect, _}, S) ->
    {reply, {ok, connected}, S};
respond({ensure_pin, Cid}, S) ->
    {reply, {ok, pinned}, S#{pins => (maps:get(pins, S))#{Cid => true}}};
respond({unpin, Cid}, S) ->
    {reply, {ok, unpinned}, S#{pins => maps:remove(Cid, maps:get(pins, S))}};
respond({Op, Cid}, S) when Op =:= pin_check; Op =:= explicit_pin_check ->
    {reply, {ok, maps:is_key(Cid, maps:get(pins, S))}, S};
respond({cat, <<"raw">>}, S) ->
    {reply, <<"raw bytes">>, S};
respond({cat, <<"missing">>}, S) ->
    {reply, {error, not_found}, S};
respond({cat, _}, S) ->
    {reply, {ok, <<"Feature: supervised IPFS\n">>}, S};
respond(R, S) ->
    {reply, {ok, R}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.
