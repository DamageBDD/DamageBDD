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
        handle_continue/2,
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
    {ok, ecai_search:new(), {continue, load_ctx}}.

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
handle_continue(load_ctx, Ctx0) ->
    NewCtx =
        case application:get_env(ecai, search_context_file) of
            {ok, File} ->
                case ecai_search:load(File) of
                    {ok, L} ->
                        ?LOG_INFO("ECAI context loaded from ~p", [File]),
                        L;
                    {error, R} ->
                        ?LOG_WARNING("Failed to load context ~p (~p). Keeping fresh ctx.", [File, R]),
                        Ctx0
                end;
            _ ->
                Ctx0
        end,

    %% snapshot path & interval configurable
    SnapPath = application:get_env(
        ecai, index_snapshot_path, "/var/lib/damage/ecai/state/ecai_index.snap"
    ),
    Interval = application:get_env(ecai, index_snapshot_ms, 60000),

    %% create parent dirs
    ok = filelib:ensure_dir(SnapPath),

    case ecai_index_snapshot:start_link(fun ecai_search_server:get_ctx/0, SnapPath, Interval) of
        {ok, _Pid} ->
            ?LOG_INFO("Index snapshotter started (~p ms -> ~s)", [Interval, SnapPath]);
        {error, {already_started, _Pid}} ->
            ?LOG_INFO("Index snapshotter already running; reusing.");
        Other ->
            ?LOG_WARNING("Snapshotter start failed: ~p", [Other])
    end,

    {noreply, NewCtx}.

terminate(Reason, _State) ->
    catch ecai_index_snapshot:force(),
    ?LOG_DEBUG("ECAI Search server terminating ~p", [Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
