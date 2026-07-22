%%--------------------------------------------------------------------
%% Dedicated supervisor for the durable ECAI ingest writer.
%%--------------------------------------------------------------------
-module(ecai_ingest_sup).
-behaviour(supervisor).

-export([
    start_link/0,
    start_link/1,
    start_link/2,
    writer/0,
    writer/1,
    stop/1
]).

-export([init/1]).

-define(DEFAULT_BASE_DIR, "/var/lib/damage/ecai/ipfs-index").

start_link() ->
    BaseDir = application:get_env(
        ecai,
        ipfs_index_dir,
        ?DEFAULT_BASE_DIR
    ),
    MaxBatchEvents = application:get_env(
        ecai,
        ingest_wal_max_batch_events,
        4096
    ),
    MaxBatchBytes = application:get_env(
        ecai,
        ingest_wal_max_batch_bytes,
        67108864
    ),
    Opts = #{
        base_dir => BaseDir,
        writer_name => ecai_ingest_writer,
        max_batch_events => MaxBatchEvents,
        max_batch_bytes => MaxBatchBytes
    },
    supervisor:start_link({local, ?MODULE}, ?MODULE, Opts).

start_link(BaseDir) ->
    start_link(BaseDir, #{}).

start_link(BaseDir, WriterOpts) when is_map(WriterOpts) ->
    supervisor:start_link(
        ?MODULE,
        #{base_dir => BaseDir, writer_opts => WriterOpts}
    );
start_link(_BaseDir, _WriterOpts) ->
    {error, badarg}.

writer() ->
    case whereis(ecai_ingest_writer) of
        Pid when is_pid(Pid) -> {ok, Pid};
        undefined -> {error, not_running}
    end.

writer(Sup) ->
    case lists:keyfind(ecai_ingest_writer, 1, supervisor:which_children(Sup)) of
        {ecai_ingest_writer, Pid, worker, _Modules} when is_pid(Pid) ->
            {ok, Pid};
        {ecai_ingest_writer, restarting, worker, _Modules} ->
            {error, restarting};
        false ->
            {error, not_found}
    end.

stop(SupRef) ->
    case resolve_pid(SupRef) of
        undefined ->
            ok;
        Pid ->
            unlink(Pid),
            try gen_server:stop(Pid, shutdown, 30000) of
                ok -> ok
            catch
                exit:{noproc, _} -> ok;
                exit:noproc -> ok;
                exit:Reason -> exit({supervisor_stop_failed, Pid, Reason})
            end
    end.

init(#{base_dir := BaseDir} = Opts) ->
    WriterOpts0 = maps:get(writer_opts, Opts, #{}),
    WriterName = maps:get(writer_name, Opts, undefined),
    WriterOpts1 = WriterOpts0#{base_dir => BaseDir},
    WriterOpts2 =
        case WriterName of
            undefined -> WriterOpts1;
            Name -> WriterOpts1#{name => Name}
        end,
    WriterOpts3 = copy_option(max_batch_events, Opts, WriterOpts2),
    WriterOpts4 = copy_option(max_batch_bytes, Opts, WriterOpts3),
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    Child = #{
        id => ecai_ingest_writer,
        start => {ecai_ingest_writer, start_link, [WriterOpts4]},
        restart => permanent,
        shutdown => 30000,
        type => worker,
        modules => [ecai_ingest_writer]
    },
    {ok, {SupFlags, [Child]}};
init(Invalid) ->
    erlang:error({invalid_supervisor_options, Invalid}).

copy_option(Key, Source, Destination) ->
    case maps:find(Key, Source) of
        {ok, Value} -> Destination#{Key => Value};
        error -> Destination
    end.

resolve_pid(Pid) when is_pid(Pid) -> Pid;
resolve_pid(Name) when is_atom(Name) -> whereis(Name).
