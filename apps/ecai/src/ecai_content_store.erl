-module(ecai_content_store).
-behaviour(gen_server).

-export([
    start_link/0,
    start_link/1,
    status/0,
    put_job/1,
    get_job/1,
    update_job/2,
    jobs/0,
    resumable_jobs/0,
    artifact_dir/1,
    artifact_path/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(TABLE, ecai_content_pipeline_dets).

-record(state, {tab, file, state_root, runtime_root}).

start_link() -> start_link(#{}).
start_link(Opts) -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).
status() -> gen_server:call(?SERVER, status).
put_job(Job) when is_map(Job) -> gen_server:call(?SERVER, {put_job, Job}, infinity).
get_job(JobId) -> gen_server:call(?SERVER, {get_job, ecai_content_util:to_binary(JobId)}).
update_job(JobId, Patch) when is_map(Patch) ->
    gen_server:call(?SERVER, {update_job, ecai_content_util:to_binary(JobId), Patch}, infinity).
jobs() -> gen_server:call(?SERVER, jobs, infinity).
resumable_jobs() -> gen_server:call(?SERVER, resumable_jobs, infinity).

artifact_dir(JobId0) ->
    case ecai_code_paths:state_root() of
        {ok, Root} ->
            JobId = ecai_content_util:to_list(ecai_content_util:sanitize_filename(JobId0)),
            Dir = filename:join([Root, "runtime", "content", JobId]),
            case filelib:ensure_dir(filename:join(Dir, ".keep")) of
                ok -> {ok, Dir};
                {error, Reason} -> {error, {cannot_create_artifact_dir, Dir, Reason}}
            end;
        {error, _} = Error -> Error
    end.

artifact_path(JobId, Name0) ->
    case artifact_dir(JobId) of
        {ok, Dir} -> {ok, filename:join(Dir, ecai_content_util:to_list(Name0))};
        {error, _} = Error -> Error
    end.

init(Opts) ->
    process_flag(trap_exit, true),
    case ecai_code_paths:state_root(Opts) of
        {ok, Root} ->
            RuntimeRoot = filename:join([Root, "runtime", "content"]),
            ok = filelib:ensure_dir(filename:join(RuntimeRoot, ".keep")),
            File = ecai_code_paths:dets_file(Root, "content_pipeline.dets"),
            case dets:open_file(?TABLE, [{file, File}, {type, set}, {auto_save, 5000}]) of
                {ok, ?TABLE} ->
                    {ok, #state{tab = ?TABLE, file = File, state_root = Root, runtime_root = RuntimeRoot}};
                {error, Reason} -> {stop, {cannot_open_content_store, File, Reason}}
            end;
        {error, Reason} -> {stop, {cannot_resolve_state_root, Reason}}
    end.

handle_call(status, _From, State) ->
    Info = case dets:info(State#state.tab) of undefined -> []; I -> I end,
    {reply, #{file => State#state.file, state_root => State#state.state_root,
              runtime_root => State#state.runtime_root, table_info => Info}, State};
handle_call({put_job, Job0}, _From, State) ->
    JobId = ecai_content_util:to_binary(maps:get(id, Job0)),
    Now = ecai_content_util:now_iso8601(),
    Job = Job0#{id => JobId, updated_at => Now},
    Reply = persist(State#state.tab, JobId, Job),
    {reply, normalize_persist_reply(Reply, Job), State};
handle_call({get_job, JobId}, _From, State) ->
    Reply = case dets:lookup(State#state.tab, {job, JobId}) of
        [{{job, JobId}, Job}] -> {ok, Job};
        [] -> not_found
    end,
    {reply, Reply, State};
handle_call({update_job, JobId, Patch}, _From, State) ->
    Reply = case dets:lookup(State#state.tab, {job, JobId}) of
        [{{job, JobId}, Job0}] ->
            Job = maps:merge(Job0, Patch#{updated_at => ecai_content_util:now_iso8601()}),
            case persist(State#state.tab, JobId, Job) of
                ok -> {ok, Job};
                {error, _} = Error -> Error
            end;
        [] -> {error, {job_not_found, JobId}}
    end,
    {reply, Reply, State};
handle_call(jobs, _From, State) ->
    {reply, collect_jobs(State#state.tab, all), State};
handle_call(resumable_jobs, _From, State) ->
    {reply, collect_jobs(State#state.tab, resumable), State};
handle_call(_Other, _From, State) -> {reply, {error, unsupported_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, State) -> catch dets:close(State#state.tab), ok.
code_change(_Old, State, _Extra) -> {ok, State}.

persist(Tab, JobId, Job) ->
    case dets:insert(Tab, {{job, JobId}, Job}) of
        ok -> dets:sync(Tab);
        {error, _} = Error -> Error
    end.

normalize_persist_reply(ok, Job) -> {ok, Job};
normalize_persist_reply({error, _} = Error, _Job) -> Error.

collect_jobs(Tab, Mode) ->
    Jobs = dets:foldl(
        fun
            ({{job, _}, Job}, Acc) ->
                case include_job(Job, Mode) of true -> [Job | Acc]; false -> Acc end;
            (_, Acc) -> Acc
        end, [], Tab),
    lists:sort(fun(A, B) -> maps:get(created_at, A, <<>>) >= maps:get(created_at, B, <<>>) end, Jobs).

include_job(_Job, all) -> true;
include_job(Job, resumable) ->
    Status = maps:get(status, Job, queued),
    not lists:member(Status, [complete, awaiting_publish, cancelled, manual_reconcile]).
