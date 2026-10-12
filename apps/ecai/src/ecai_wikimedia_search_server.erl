-module(ecai_wikimedia_search_server).
-behaviour(gen_server).

-export([
    start_link/0,
    search/2,
    status/0,
    activate_snapshot/2,
    upsert_live_record/4,
    clear_live_index/1
]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/logger.hrl").

-define(COPY_BLOCK_BYTES, 1048576).

-record(st, {
    ctx = undefined,
    snapshot_path = undefined,
    metadata = #{},
    live_ctx = undefined,
    live_metadata = #{},
    live_owner_pid = undefined,
    live_owner_ref = undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

search(Query, Opts) when is_map(Opts) ->
    gen_server:call(?MODULE, {search, Query, Opts}, infinity).

status() ->
    gen_server:call(?MODULE, status).

activate_snapshot(Path, Metadata) when is_map(Metadata) ->
    gen_server:call(?MODULE, {activate_snapshot, Path, Metadata}, infinity).

upsert_live_record(Metadata, DocId, Record, Abstract) when
    is_map(Metadata), is_binary(DocId), is_map(Record), is_binary(Abstract)
->
    gen_server:call(
        ?MODULE,
        {upsert_live_record, Metadata, DocId, Record, Abstract},
        infinity
    ).

clear_live_index(JobId) when is_binary(JobId) ->
    gen_server:call(?MODULE, {clear_live_index, JobId}, infinity).

init([]) ->
    {ok, #st{}, {continue, restore_active_snapshot}}.

handle_continue(restore_active_snapshot, State) ->
    {noreply, restore_active_snapshot(State)}.

handle_call({search, Query, Opts}, _From, State0) ->
    case active_search_context(State0) of
        {live, Ctx, State1 = #st{live_metadata = LiveMetadata}} ->
            %% Live writes are serialized through this gen_server. Rebuild
            %% deferred proof roots only when a query actually needs them.
            _ = ecai_search:finalize_roots(Ctx),
            {reply,
                annotate_index_result(
                    ecai_wikimedia_search:search(Ctx, Query, Opts),
                    LiveMetadata,
                    true,
                    false
                ),
                State1};
        {stable, Ctx, State1 = #st{metadata = StableMetadata}} ->
            {reply,
                annotate_index_result(
                    ecai_wikimedia_search:search(Ctx, Query, Opts),
                    StableMetadata,
                    false,
                    true
                ),
                State1};
        {none, State1} ->
            {reply, {error, search_index_not_ready}, State1}
    end;
handle_call(status, _From, State0) ->
    case active_search_context(State0) of
        {live, Ctx, State1 = #st{live_metadata = Metadata, ctx = StableCtx}} ->
            {reply,
                #{
                    ready => true,
                    live => true,
                    size => ecai_search:size(Ctx),
                    records_indexed => maps:get(docs, ecai_search:size(Ctx), 0),
                    records_searchable => maps:get(docs, ecai_search:size(Ctx), 0),
                    metadata => Metadata,
                    stable_ready => StableCtx =/= undefined
                },
                State1};
        {stable, Ctx, State1 = #st{snapshot_path = Path, metadata = Metadata}} ->
            {reply,
                #{
                    ready => true,
                    live => false,
                    size => ecai_search:size(Ctx),
                    records_indexed => maps:get(docs, ecai_search:size(Ctx), 0),
                    records_searchable => maps:get(docs, ecai_search:size(Ctx), 0),
                    snapshot_path => Path,
                    metadata => Metadata
                },
                State1};
        {none, State1} ->
            {reply, #{ready => false, live => false, reason => search_index_not_ready}, State1}
    end;
handle_call(
    {upsert_live_record, Metadata, DocId, Record, Abstract},
    {OwnerPid, _Tag},
    State0
) ->
    {LiveCtx, State1} = ensure_live_context(Metadata, OwnerPid, State0),
    case live_upsert(LiveCtx, DocId, Record, Abstract) of
        ok ->
            Size = ecai_search:size(LiveCtx),
            Metadata1 = Metadata#{
                live => true,
                final => false,
                records_indexed => maps:get(docs, Size, 0),
                records_searchable => maps:get(docs, Size, 0)
            },
            {reply, {ok, Size}, State1#st{live_metadata = Metadata1}};
        {error, Reason} ->
            {reply, {error, Reason}, State1}
    end;
handle_call({clear_live_index, JobId}, _From, State = #st{live_metadata = Metadata}) ->
    case maps:get(job_id, Metadata, undefined) of
        JobId ->
            {reply, ok, clear_live_state(State)};
        _ ->
            {reply, ok, State}
    end;
handle_call({activate_snapshot, Path0, Metadata}, _From, State) ->
    %% Install a private immutable copy first. The active pointer must never
    %% depend on a job work directory that can later be compacted or removed.
    case install_snapshot(Path0) of
        {ok, InstalledPath, SnapshotSha} ->
            case load_snapshot(InstalledPath) of
                {ok, NewCtx, Path} ->
                    Metadata1 = Metadata#{
                        snapshot_sha256 => SnapshotSha,
                        live => false,
                        final => true
                    },
                    case persist_active_snapshot(Path, Metadata1) of
                        ok ->
                            wipe_ctx(State#st.ctx),
                            ClearedState = clear_live_state(State),
                            {reply, ok, ClearedState#st{
                                ctx = NewCtx,
                                snapshot_path = Path,
                                metadata = Metadata1
                            }};
                        {error, Reason} ->
                            wipe_ctx(NewCtx),
                            {reply, {error, {active_snapshot_state_failed, Reason}}, State}
                    end;
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(
    {'DOWN', Ref, process, Pid, _Reason},
    State = #st{live_owner_ref = Ref, live_owner_pid = Pid}
) ->
    {noreply, clear_live_state(State)};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    _ = clear_live_state(State),
    wipe_ctx(State#st.ctx),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

active_search_context(State = #st{live_ctx = LiveCtx}) when LiveCtx =/= undefined ->
    case ctx_alive(LiveCtx) of
        true -> {live, LiveCtx, State};
        false -> active_search_context(State#st{live_ctx = undefined, live_metadata = #{}})
    end;
active_search_context(State = #st{ctx = Ctx}) when Ctx =/= undefined ->
    case ctx_alive(Ctx) of
        true -> {stable, Ctx, State};
        false -> {none, State#st{ctx = undefined, snapshot_path = undefined, metadata = #{}}}
    end;
active_search_context(State) ->
    {none, State}.

ctx_alive(Ctx) ->
    try ecai_search:size(Ctx) of
        Size when is_map(Size) -> true
    catch
        _:_ -> false
    end.

ensure_live_context(
    Metadata,
    OwnerPid,
    State = #st{
        live_ctx = LiveCtx,
        live_metadata = Current,
        live_owner_pid = CurrentOwner
    }
) ->
    JobId = maps:get(job_id, Metadata, undefined),
    SameLiveBuild =
        LiveCtx =/= undefined andalso
            maps:get(job_id, Current, undefined) =:= JobId andalso
            CurrentOwner =:= OwnerPid andalso
            ctx_alive(LiveCtx),
    case SameLiveBuild of
        true ->
            {LiveCtx, State};
        false ->
            State1 = clear_live_state(State),
            Ctx = ecai_search:set_opts(ecai_search:new(), #{root_mode => deferred}),
            Ref = erlang:monitor(process, OwnerPid),
            {Ctx, State1#st{
                live_ctx = Ctx,
                live_metadata = Metadata,
                live_owner_pid = OwnerPid,
                live_owner_ref = Ref
            }}
    end.

clear_live_state(State = #st{live_ctx = LiveCtx, live_owner_ref = Ref}) ->
    case Ref of
        Reference when is_reference(Reference) ->
            _ = erlang:demonitor(Reference, [flush]),
            ok;
        _ ->
            ok
    end,
    wipe_ctx(LiveCtx),
    State#st{
        live_ctx = undefined,
        live_metadata = #{},
        live_owner_pid = undefined,
        live_owner_ref = undefined
    }.

live_upsert(Ctx, DocId, Record, Abstract) ->
    try
        ok = ecai_search:upsert_record(Ctx, DocId, Record),
        ok = ecai_search:index_text(Ctx, DocId, <<"abstract">>, Abstract, 120),
        ok
    catch
        Class:Reason:Stacktrace -> {error, {live_index_update_failed, Class, Reason, Stacktrace}}
    end.

annotate_index_result({ok, Result}, Metadata, Live, Final) ->
    {ok, Result#{
        live => Live,
        final => Final,
        source_index => maps:with([job_id, index_id, namespace], Metadata)
    }};
annotate_index_result(Other, _Metadata, _Live, _Final) ->
    Other.

restore_active_snapshot(State) ->
    case file:read_file(active_state_path()) of
        {ok, Bin} ->
            try binary_to_term(Bin, [safe]) of
                #{version := 1, snapshot_path := Path, metadata := Metadata} when
                    is_map(Metadata)
                ->
                    case load_snapshot(Path) of
                        {ok, Ctx, NormalizedPath} ->
                            State#st{
                                ctx = Ctx, snapshot_path = NormalizedPath, metadata = Metadata
                            };
                        {error, Reason} ->
                            ?LOG_WARNING(
                                "Unable to restore active Wikimedia search snapshot: ~p", [Reason]
                            ),
                            State
                    end;
                _ ->
                    State
            catch
                error:badarg -> State
            end;
        {error, enoent} ->
            State;
        {error, Reason} ->
            ?LOG_WARNING("Unable to read Wikimedia active-search state: ~p", [Reason]),
            State
    end.

install_snapshot(Path0) ->
    case normalize_path(Path0) of
        {ok, SourcePath} ->
            SnapshotDir = snapshot_dir(),
            ok = filelib:ensure_dir(filename:join(SnapshotDir, "x")),
            TempPath = filename:join(
                SnapshotDir,
                ".install-" ++ integer_to_list(erlang:unique_integer([positive, monotonic])) ++
                    ".tmp"
            ),
            case copy_and_hash(SourcePath, TempPath) of
                {ok, Hash} ->
                    Sha = hex(Hash),
                    FinalPath = filename:join(SnapshotDir, binary_to_list(Sha) ++ ".etf"),
                    case filelib:is_regular(FinalPath) of
                        true ->
                            _ = file:delete(TempPath),
                            {ok, unicode:characters_to_binary(FinalPath), Sha};
                        false ->
                            case file:rename(TempPath, FinalPath) of
                                ok ->
                                    {ok, unicode:characters_to_binary(FinalPath), Sha};
                                {error, Reason} ->
                                    _ = file:delete(TempPath),
                                    {error, {snapshot_install_rename_failed, Reason}}
                            end
                    end;
                {error, Reason} ->
                    _ = file:delete(TempPath),
                    {error, Reason}
            end;
        {error, _Reason} = Error ->
            Error
    end.

copy_and_hash(SourcePath, TempPath) ->
    case file:open(SourcePath, [read, raw, binary]) of
        {ok, In} ->
            case file:open(TempPath, [write, raw, binary]) of
                {ok, Out} ->
                    try
                        Hash0 = crypto:hash_init(sha256),
                        case copy_and_hash_loop(In, Out, Hash0) of
                            {ok, Hash1} ->
                                case file:sync(Out) of
                                    ok -> {ok, crypto:hash_final(Hash1)};
                                    {error, Reason} -> {error, {snapshot_sync_failed, Reason}}
                                end;
                            {error, _Reason} = Error ->
                                Error
                        end
                    after
                        ok = file:close(Out),
                        ok = file:close(In)
                    end;
                {error, Reason} ->
                    ok = file:close(In),
                    {error, {snapshot_install_open_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {snapshot_source_open_failed, Reason}}
    end.

copy_and_hash_loop(In, Out, Hash0) ->
    case file:read(In, ?COPY_BLOCK_BYTES) of
        eof ->
            {ok, Hash0};
        {ok, Chunk} ->
            case file:write(Out, Chunk) of
                ok -> copy_and_hash_loop(In, Out, crypto:hash_update(Hash0, Chunk));
                {error, Reason} -> {error, {snapshot_install_write_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {snapshot_source_read_failed, Reason}}
    end.

load_snapshot(Path0) ->
    case normalize_path(Path0) of
        {ok, Path} ->
            Ctx0 = ecai_search:new(),
            try ecai_search:load(Ctx0, Path) of
                {ok, Ctx} ->
                    {ok, Ctx, unicode:characters_to_binary(Path)};
                {error, Reason} ->
                    wipe_ctx(Ctx0),
                    {error, {snapshot_load_failed, Reason}};
                Other ->
                    wipe_ctx(Ctx0),
                    {error, {unexpected_snapshot_load_result, Other}}
            catch
                Class:Reason:Stacktrace ->
                    wipe_ctx(Ctx0),
                    {error, {snapshot_load_failed, Class, Reason, Stacktrace}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

persist_active_snapshot(Path, Metadata) ->
    StatePath = active_state_path(),
    ok = filelib:ensure_dir(StatePath),
    atomic_write(
        StatePath, term_to_binary(#{version => 1, snapshot_path => Path, metadata => Metadata})
    ).

snapshot_dir() ->
    filename:join(filename:dirname(active_state_path()), "wikimedia-search-snapshots").

active_state_path() ->
    case
        application:get_env(
            ecai,
            wikimedia_active_search_state_path,
            "/var/lib/damage/ecai/state/wikimedia-active-search.etf"
        )
    of
        Bin when is_binary(Bin) -> unicode:characters_to_list(Bin);
        List when is_list(List), List =/= [] -> List;
        _ -> "/var/lib/damage/ecai/state/wikimedia-active-search.etf"
    end.

normalize_path(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    try
        {ok, unicode:characters_to_list(Bin)}
    catch
        _:_ -> {error, invalid_snapshot_path}
    end;
normalize_path(List) when is_list(List), List =/= [] -> {ok, List};
normalize_path(_) ->
    {error, invalid_snapshot_path}.

atomic_write(Path, Bytes) ->
    Tmp = Path ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            Result =
                try
                    ok = file:write(Fd, Bytes),
                    file:sync(Fd)
                after
                    ok = file:close(Fd)
                end,
            case Result of
                ok -> file:rename(Tmp, Path);
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

hex(Bin) when is_binary(Bin) ->
    <<<<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0f))>> || <<Byte:8>> <= Bin>>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + (N - 10).

wipe_ctx(undefined) ->
    ok;
wipe_ctx(Ctx) ->
    try
        ecai_search:wipe(Ctx)
    catch
        _:_ -> ok
    end.
