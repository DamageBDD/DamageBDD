%%% @doc
%%% 〘*PROJECT NAME*〙: 〘*CAP SERVICE*〙 Worker
%%% @end

-module(〘*PREFIX*〙_〘*SERVICE*〙).
-vsn("〘*VERSION*〙").
-behavior(gen_server).
〘*AUTHOR*〙
〘*COPYRIGHT*〙
〘*LICENSE*〙

%% gen_server
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).
-include("$zx_include/zx_logger.hrl").


%%% Type and Record Definitions


-record(s,
        {}).


-type state() :: #s{}.



%%% Interface



%%% gen_server

-spec start_link() -> Result
    when Result :: {ok, pid()}
                 | {error, Reason :: term()}.

start_link() ->
    gen_server:start_link(?MODULE, none, []).


init(none) ->
    State = #s{},
    {ok, State}.


handle_call(Unexpected, From, State) ->
    ok = log(warning, "Unexpected call from ~tp: ~tp", [From, Unexpected]),
    {noreply, State}.


handle_cast(Unexpected, State) ->
    ok = log(warning, "Unexpected cast: ~tp", [Unexpected]),
    {noreply, State}.


handle_info(Unexpected, State) ->
    ok = log(warning, "Unexpected info: ~tp", [Unexpected]),
    {noreply, State}.


-spec code_change(OldVersion, State, Extra) -> {ok, NewState} | {error, Reason}
    when OldVersion :: Version | {old, Version},
         Version    :: term(),
         State      :: state(),
         Extra      :: term(),
         NewState   :: term(),
         Reason     :: term().

code_change(_, State, _) ->
    {ok, State}.


terminate(_, _) ->
    ok.



%%% Doer Functions
