%%%-------------------------------------------------------------------
%%% ecai_indexer: singleton async index job with progress + locking
%%%-------------------------------------------------------------------
-module(ecai_indexer).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-behaviour(gen_server).

-export([start_link/0, start/3, status/0, cancel/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    status = idle :: idle | running | done | canceled | error,
    job_id = undefined :: binary() | undefined,
    started_at = 0 :: integer(),
    finished_at = 0 :: integer(),
    ctx :: term() | undefined,
    paths = [] :: [binary()],
    limit = infinity :: pos_integer() | infinity,
    total = 0 :: non_neg_integer(),
    done = 0 :: non_neg_integer(),
    docs_done = 0 :: non_neg_integer(),
    err :: term() | undefined
}).

%%% ===== Public API ==================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Start an async job, returns {ok, JobId} | {error,busy}
start(Ctx, Paths, Limit) ->
    gen_server:call(?MODULE, {start, Ctx, Paths, Limit}, infinity).

%% Status map (safe to call often)
status() ->
    gen_server:call(?MODULE, status).

%% Cancel current job, if any
cancel() ->
    gen_server:call(?MODULE, cancel).

%%% ===== gen_server ==================================================

init([]) ->
    {ok, #state{}}.

handle_call(status, _From, S) ->
    {reply, to_map(S), S};
handle_call(cancel, _From, S = #state{status = running}) ->
    %% cooperative cancel: switch flag; worker loop checks status again via server state
    New = S#state{status = canceled},
    {reply, ok, New};
handle_call(cancel, _From, S) ->
    {reply, {error, nojob}, S};
handle_call({start, _Ctx, _Paths, _Limit}, _From, S = #state{status = running}) ->
    {reply, {error, busy}, S};
handle_call({start, Ctx, Paths0, Limit}, _From, _S = #state{}) ->
    Paths = [unicode:characters_to_binary(P) || P <- Paths0],
    JobId = iolist_to_binary(
        io_lib:format("job-~B", [erlang:unique_integer([monotonic, positive])])
    ),

    S1 = #state{
        status = running,
        job_id = JobId,
        started_at = erlang:system_time(millisecond),
        ctx = Ctx,
        paths = Paths,
        limit = Limit,
        total = length(Paths),
        done = 0,
        docs_done = 0
    },
    Self = self(),
    _Pid = spawn_link(fun() -> run_index(Self, S1) end),
    {reply, {ok, JobId}, S1}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info(
    {progress, FileInc, DocsInc}, S = #state{status = running, done = D0, docs_done = Doc0}
) ->
    {noreply, S#state{done = D0 + FileInc, docs_done = Doc0 + DocsInc}};
handle_info({finished, ok}, S = #state{status = running}) ->
    {noreply, S#state{status = done, finished_at = now_ms()}};
handle_info({finished, {error, Why}}, S = #state{status = running}) ->
    ?LOG_WARNING(#{what => index_failed, reason => Why}),
    {noreply, S#state{status = error, err = Why, finished_at = now_ms()}};
handle_info(_Other, S) ->
    {noreply, S}.

terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

%%% ===== Worker ======================================================

run_index(Server, _S0 = #state{ctx = Ctx, paths = Paths, limit = Limit}) ->
    try
        %% Iterate by file so we can report progress & respect cancel
        lists:foreach(
            fun(Path) ->
                %% Check cancel/busy before each file
                case gen_server:call(?MODULE, status) of
                    #{status := canceled} -> throw(canceled);
                    _ -> ok
                end,
                DocsBefore = get_docs(Ctx),
                ok = ecai_yelp_loader:index_chunks(Ctx, [Path], Limit),
                DocsAfter = get_docs(Ctx),
                %% no-op, keep mailbox flowing
                gen_server:cast(?MODULE, {set, dummy}),
                Server ! {progress, 1, DocsAfter - DocsBefore}
            end,
            Paths
        ),
        Server ! {finished, ok}
    catch
        throw:canceled -> Server ! {finished, {error, canceled}};
        C:R -> Server ! {finished, {error, {C, R}}}
    end.

get_docs(Ctx) ->
    case ecai_search:size(Ctx) of
        #{docs := N} -> N;
        _ -> 0
    end.

now_ms() -> erlang:system_time(millisecond).

to_map(#state{
    status = St,
    job_id = Id,
    started_at = T0,
    finished_at = T1,
    total = Tot,
    done = Done,
    docs_done = Docs,
    err = Err
}) ->
    #{
        status => St,
        job_id => Id,
        started_at => T0,
        finished_at => T1,
        files_total => Tot,
        files_done => Done,
        docs_done => Docs,
        error => Err
    }.
