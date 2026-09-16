%% Offline backend for the IPFS review regression suite. Never contacts Kubo.
-module(damage_ipfs_review_backend).
-behaviour(gen_server).
-export([start_link/0, rules/1, calls/0, execute/2, run/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
rules(Rules) -> gen_server:call(?MODULE, {rules, Rules}).
calls() -> gen_server:call(?MODULE, calls).
execute(crash, _) ->
    exit(self(), kill);
execute({echo, Value}, _) ->
    {ok, Value};
execute({hold, Ms, Observer}, _) ->
    Observer ! {backend_worker, self()},
    timer:sleep(Ms),
    {ok, finished};
execute(Request, _) ->
    case gen_server:call(?MODULE, {request, Request}) of
        {delay, Ms, Result} ->
            timer:sleep(Ms),
            Result;
        Result ->
            Result
    end.
%% Exercise per-item backoff opt-out independently of network/store timing.
run(_, Data) -> {ok, #{failed => 1, backoff => false}, Data}.
init([]) -> {ok, #{rules => #{}, calls => []}}.
handle_call({rules, Rules}, _, S) ->
    {reply, ok, S#{rules => Rules, calls => []}};
handle_call(calls, _, S) ->
    {reply, lists:reverse(maps:get(calls, S)), S};
handle_call({request, Request}, _, S) ->
    Result = maps:get(Request, maps:get(rules, S), default(Request)),
    {reply, Result, S#{calls => [Request | maps:get(calls, S)]}};
handle_call(_, _, S) ->
    {reply, {error, unsupported}, S}.
default(identity) -> {ok, #{<<"ID">> => <<"SelfPeer">>}};
default({connect, _}) -> {ok, connected};
default({pin_check, _}) -> {ok, true};
default({explicit_pin_check, _}) -> {ok, false};
default(_) -> {error, unsupported}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.
