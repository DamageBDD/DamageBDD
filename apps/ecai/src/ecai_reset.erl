%%%-------------------------------------------------------------------
%%% ecai_reset.erl  —  Reset the ECAI search context and GPU snapshots
%%%-------------------------------------------------------------------
-module(ecai_reset).
-export([reset/0, reset/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("ecai_search.hrl").

%% reset() -> ok | {error, Reason}
reset() ->
    case ecai_search_server:get_ctx() of
        Ctx when is_record(Ctx, ctx) ->
            reset(Ctx);
        _ ->
            %% server not started; just build new context
            New = fresh_ctx(),
            ecai_search_server:set_ctx(New),
            ok
    end.

%% reset(Context) -> ok
reset(Ctx = #ctx{}) ->
    ?LOG_WARNING("ECAI Reset: wiping all ETS and GPU resources", []),
    %% 1. Stop background snapshotter if running
    catch ecai_index_snapshot:stop(),

    %% 2. Free GPU memory (both compact and dynamic)
    case Ctx#ctx.backend of
        gpu ->
            catch ecai_gpu:free_dynamic(Ctx#ctx.dyn),
            catch ecai_gpu:free(Ctx#ctx.gpu);
        _ ->
            ok
    end,

    %% 3. Drop all ETS tables
    catch ecai_search:wipe(Ctx),

    %% 4. Build a new blank context with GPU ready
    NewCtx = fresh_ctx(),

    %% 5. Replace in the running gen_server
    ok = ecai_search_server:set_ctx(NewCtx),

    %% 6. Restart snapshotter if desired
    maybe_restart_snapshot(NewCtx),
    ?LOG_INFO("ECAI context reset complete", []),
    ok.

%% ------------------------------------------------------------------
%% Helpers
%% ------------------------------------------------------------------

fresh_ctx() ->
    %% brand new ETS + GPU
    C0 = ecai_search:new(),
    case ecai_gpu:new_dynamic(2000000, 64, 8000000) of
        {ok, DynH} ->
            C0#ctx{backend = gpu, dyn = DynH};
        Error ->
            ?LOG_WARNING("GPU dynamic init failed: ~p (using ETS fallback)", [Error]),
            C0#ctx{backend = ets}
    end.

maybe_restart_snapshot(_Ctx) ->
    case application:get_env(ecai, index_snapshot_path) of
        undefined ->
            ok;
        {ok, Path} ->
            _ = ecai_index_snapshot:start_link(fun ecai_search_server:get_ctx/0, Path),
            ok
    end.
