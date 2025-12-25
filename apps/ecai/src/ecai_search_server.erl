%%% ecai_search_server.erl
-module(ecai_search_server).
-behaviour(gen_server).
-include_lib("kernel/include/logger.hrl").

-export(
    [
        get_ctx/0,
        get_ctx_size/0,
        set_ctx/1,
        start_link/0,
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        handle_continue/2,
        terminate/2,
        code_change/3
    ]
).
-define(CTX_TIMEOUT, 60000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_ctx() ->
    gen_server:call(?MODULE, get_ctx, ?CTX_TIMEOUT).
get_ctx_size() ->
    gen_server:call(?MODULE, get_ctx_size, ?CTX_TIMEOUT).
set_ctx(Ctx) ->
    gen_server:call(?MODULE, {set_ctx, Ctx}, ?CTX_TIMEOUT).

init([]) ->
    {ok, ecai_search:new(), {continue, load_ctx}}.

handle_call(get_ctx, _From, Ctx) ->
    {reply, Ctx, Ctx};
handle_call(get_ctx_size, _From, Ctx) ->
    {reply, tuple_size(Ctx), Ctx};
handle_call({set_ctx, NewCtx}, _From, _Ctx) ->
    {reply, ok, NewCtx}.

handle_cast(Any, State) ->
    ?LOG_DEBUG("ECAI Search server got cast message: ~s~n", [Any]),
    {noreply, State}.
handle_info(Any, State) ->
    ?LOG_DEBUG("ECAI Search server got cast message: ~s~n", [Any]),
    {noreply, State}.
handle_continue(load_ctx, Ctx0) ->
    SnapShotPath = application:get_env(
        ecai, index_snapshot_path, "/var/lib/damage/ecai/state/ecai_index.snap"
    ),
    CtxPath =
        case filelib:is_file(SnapShotPath) of
            true ->
                SnapShotPath;
            false ->
                application:get_env(ecai, search_context_file, "/var/lib/damage/ecai/default.ctx")
        end,
    NewCtx =
        case ecai_search:load(Ctx0, CtxPath) of
            {ok, L} ->
                ?LOG_INFO("ECAI context loaded from ~p", [CtxPath]),
                L;
            {error, R} ->
                ?LOG_WARNING("Failed to load context ~p (~p). Keeping existing ctx.", [CtxPath, R]),
                Ctx0
        end,
    {noreply, NewCtx}.

terminate(Reason, _State) ->
    catch ecai_index_snapshot:force(),
    ?LOG_DEBUG("ECAI Search server terminating ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
