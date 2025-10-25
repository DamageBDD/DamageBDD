%%% ecai_search_server.erl
-module(ecai_search_server).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export(
    [
        get_ctx/0,
        set_ctx/1,
        start_link/0,
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
    ]
).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_ctx() ->
    gen_server:call(?MODULE, get_ctx).
set_ctx(Ctx) ->
    gen_server:call(?MODULE, {set_ctx, Ctx}).

init([]) ->
    Ctx = ecai_search:new(),
    {ok, Ctx}.

handle_call(get_ctx, _From, Ctx) ->
    {reply, Ctx, Ctx};
handle_call({set_ctx, NewCtx}, _From, _Ctx) ->
    {reply, ok, NewCtx}.

handle_cast(Any, State) ->
    ?LOG_DEBUG("ECAI Search server got cast message: ~s~n", [Any]),
    {noreply, State}.
handle_info(Any, State) ->
    ?LOG_DEBUG("ECAI Search server got cast message: ~s~n", [Any]),
    {noreply, State}.
terminate(Reason, _State) ->
    ?LOG_DEBUG("ECAI Search server terminating~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
