%%--------------------------------------------------------------------
%% Single-owner durable ingest writer.
%%
%% This process is the only component allowed to append to the ingest WAL and
%% the only allocator of local document IDs. A successful submit reply means
%% the committed batch has passed file:sync/1 and is recoverable after restart.
%%--------------------------------------------------------------------
-module(ecai_ingest_writer).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/0,
    start_link/1,
    start_link/2,
    submit_batch/1,
    submit_batch/2,
    lookup_event/1,
    lookup_event/2,
    lookup_doc/1,
    lookup_doc/2,
    list_records/0,
    list_records/1,
    list_records/2,
    status/0,
    status/1,
    stop/0,
    stop/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(DEFAULT_NAME, ?MODULE).
-define(DEFAULT_BASE_DIR, "/var/lib/damage/ecai/ipfs-index").
-define(DEFAULT_MAX_BATCH_EVENTS, 4096).
-define(DEFAULT_MAX_BATCH_BYTES, 67108864).
-define(DEFAULT_LIST_LIMIT, 1000).
-define(MAX_LIST_LIMIT, 10000).

-record(st, {
    base_dir,
    wal,
    event_tab,
    records_tab,
    next_doc_id = 1,
    recovered_unique = 0,
    recovered_duplicates = 0,
    repaired_bytes = 0,
    max_batch_events = ?DEFAULT_MAX_BATCH_EVENTS,
    max_batch_bytes = ?DEFAULT_MAX_BATCH_BYTES,
    opts = #{}
}).

start_link() ->
    BaseDir = application:get_env(
        ecai,
        ipfs_index_dir,
        ?DEFAULT_BASE_DIR
    ),
    MaxBatchEvents = application:get_env(
        ecai,
        ingest_wal_max_batch_events,
        ?DEFAULT_MAX_BATCH_EVENTS
    ),
    MaxBatchBytes = application:get_env(
        ecai,
        ingest_wal_max_batch_bytes,
        ?DEFAULT_MAX_BATCH_BYTES
    ),
    start_link(#{
        name => ?DEFAULT_NAME,
        base_dir => BaseDir,
        max_batch_events => MaxBatchEvents,
        max_batch_bytes => MaxBatchBytes
    }).

start_link(BaseDir) when is_list(BaseDir); is_binary(BaseDir) ->
    start_link(#{base_dir => BaseDir});
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, undefined) of
        undefined ->
            gen_server:start_link(?MODULE, Opts, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Opts, []);
        InvalidName ->
            {error, {invalid_writer_name, InvalidName}}
    end;
start_link(_Invalid) ->
    {error, badarg}.

start_link(BaseDir, Opts) when is_map(Opts) ->
    start_link(Opts#{base_dir => BaseDir});
start_link(_BaseDir, _Opts) ->
    {error, badarg}.

submit_batch(Records) ->
    submit_batch(?DEFAULT_NAME, Records).

submit_batch(Server, Records) ->
    gen_server:call(Server, {submit_batch, Records}, infinity).

lookup_event(EventId) ->
    lookup_event(?DEFAULT_NAME, EventId).

lookup_event(Server, EventId) ->
    gen_server:call(Server, {lookup_event, EventId}).

lookup_doc(DocId) ->
    lookup_doc(?DEFAULT_NAME, DocId).

lookup_doc(Server, DocId) ->
    gen_server:call(Server, {lookup_doc, DocId}).

list_records() ->
    list_records(?DEFAULT_NAME, ?DEFAULT_LIST_LIMIT).

list_records(Limit) ->
    list_records(?DEFAULT_NAME, Limit).

list_records(Server, Limit) ->
    gen_server:call(Server, {list_records, Limit}).

status() ->
    status(?DEFAULT_NAME).

status(Server) ->
    gen_server:call(Server, status).

stop() ->
    stop(?DEFAULT_NAME).

stop(Server) ->
    gen_server:stop(Server).

init(Opts) when is_map(Opts) ->
    case maps:find(base_dir, Opts) of
        error ->
            {stop, missing_base_dir};
        {ok, BaseDir} ->
            init_with_base_dir(BaseDir, Opts)
    end;
init(_Invalid) ->
    {stop, invalid_options}.

init_with_base_dir(BaseDir0, Opts) ->
    case normalize_base_dir(BaseDir0) of
        {ok, BaseDir} ->
            init_canonical_base_dir(BaseDir, Opts);
        {error, Reason} ->
            {stop, Reason}
    end.

init_canonical_base_dir(BaseDir, Opts) ->
    MaxBatchEvents = maps:get(
        max_batch_events,
        Opts,
        ?DEFAULT_MAX_BATCH_EVENTS
    ),
    MaxBatchBytes = maps:get(
        max_batch_bytes,
        Opts,
        ?DEFAULT_MAX_BATCH_BYTES
    ),
    WalOpts = #{
        max_batch_events => MaxBatchEvents,
        max_batch_bytes => MaxBatchBytes
    },
    case ecai_wal:open(BaseDir, WalOpts) of
        {ok, Wal, Recovery} ->
            EventTab = ets:new(ecai_ingest_event_ids, [set, private]),
            RecordsTab = ets:new(ecai_ingest_records, [ordered_set, private]),
            Records = maps:get(records, Recovery),
            {NextDocId, Unique, Duplicates} = install_recovered(
                Records,
                EventTab,
                RecordsTab,
                1,
                0,
                0
            ),
            RepairedBytes = maps:get(repaired_bytes, Recovery),
            log_recovery(BaseDir, Recovery, Unique, Duplicates),
            {ok, #st{
                base_dir = BaseDir,
                wal = Wal,
                event_tab = EventTab,
                records_tab = RecordsTab,
                next_doc_id = NextDocId,
                recovered_unique = Unique,
                recovered_duplicates = Duplicates,
                repaired_bytes = RepairedBytes,
                max_batch_events = MaxBatchEvents,
                max_batch_bytes = MaxBatchBytes,
                opts = Opts
            }};
        {error, Reason} ->
            ?LOG_ERROR("ECAI ingest WAL failed to open: ~p", [Reason]),
            {stop, Reason}
    end.

handle_call({submit_batch, Records0}, _From, State0) ->
    case prepare_submission(Records0, State0) of
        {ok, Submission} ->
            commit_submission(Submission, State0);
        {error, _Reason} = Error ->
            {reply, Error, State0}
    end;
handle_call({lookup_event, EventId}, _From, State) when
    is_binary(EventId), byte_size(EventId) =:= 32
->
    Reply =
        case ets:lookup(State#st.event_tab, EventId) of
            [{EventId, DocId}] -> lookup_doc_reply(DocId, State#st.records_tab);
            [] -> not_found
        end,
    {reply, Reply, State};
handle_call({lookup_event, _InvalidEventId}, _From, State) ->
    {reply, {error, invalid_event_id}, State};
handle_call({lookup_doc, DocId}, _From, State) when
    is_integer(DocId), DocId > 0
->
    {reply, lookup_doc_reply(DocId, State#st.records_tab), State};
handle_call({lookup_doc, _InvalidDocId}, _From, State) ->
    {reply, {error, invalid_doc_id}, State};
handle_call({list_records, Limit}, _From, State) when
    is_integer(Limit), Limit > 0, Limit =< ?MAX_LIST_LIMIT
->
    {reply, list_records_from_ets(State#st.records_tab, Limit), State};
handle_call({list_records, _InvalidLimit}, _From, State) ->
    {reply, {error, invalid_limit}, State};
handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #st{wal = Wal}) ->
    _ = catch ecai_wal:close(Wal),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

prepare_submission(Records0, State) when is_list(Records0) ->
    Submitted = length(Records0),
    case Submitted =< State#st.max_batch_events of
        false ->
            {error, {
                batch_event_limit_exceeded,
                Submitted,
                State#st.max_batch_events
            }};
        true ->
            prepare_submission_records(
                Records0,
                State#st.event_tab,
                #{},
                [],
                1,
                Submitted,
                0
            )
    end;
prepare_submission(_Records0, _State) ->
    {error, invalid_batch}.

prepare_submission_records(
    [],
    _EventTab,
    _BatchSeen,
    NewRev,
    _Position,
    Submitted,
    Duplicates
) ->
    {ok, #{
        submitted => Submitted,
        duplicates => Duplicates,
        new_records => lists:reverse(NewRev)
    }};
prepare_submission_records(
    [Record0 | Rest],
    EventTab,
    BatchSeen,
    NewRev,
    Position,
    Submitted,
    Duplicates
) ->
    case ecai_ingest_record:normalize(Record0) of
        {ok, Record} ->
            EventId = maps:get(event_id, Record),
            AlreadyInBatch = maps:is_key(EventId, BatchSeen),
            AlreadyDurable = ets:member(EventTab, EventId),
            case AlreadyInBatch orelse AlreadyDurable of
                true ->
                    prepare_submission_records(
                        Rest,
                        EventTab,
                        BatchSeen,
                        NewRev,
                        Position + 1,
                        Submitted,
                        Duplicates + 1
                    );
                false ->
                    prepare_submission_records(
                        Rest,
                        EventTab,
                        BatchSeen#{EventId => true},
                        [Record | NewRev],
                        Position + 1,
                        Submitted,
                        Duplicates
                    )
            end;
        {error, Reason} ->
            {error, {invalid_record, Position, Reason}}
    end.

commit_submission(Submission, State0) ->
    NewRecords = maps:get(new_records, Submission),
    case NewRecords of
        [] ->
            {reply, {ok, duplicate_ack(Submission)}, State0};
        _ ->
            case ecai_wal:append_batch(State0#st.wal, NewRecords) of
                {ok, Wal1, BatchMeta} ->
                    run_test_hook(after_wal_sync, State0#st.opts),
                    {State1, FirstDocId, LastDocId} = install_new_records(
                        NewRecords,
                        State0#st{wal = Wal1}
                    ),
                    Ack = committed_ack(
                        Submission,
                        BatchMeta,
                        FirstDocId,
                        LastDocId
                    ),
                    {reply, {ok, Ack}, State1};
                {error, Reason} ->
                    %% The append may have reached storage even when sync or
                    %% the reply failed. Restart and replay before accepting
                    %% further writes so the deduplication ledger is exact.
                    ?LOG_ERROR("ECAI ingest WAL append failed: ~p", [Reason]),
                    {stop, {wal_append_failed, Reason}, {error, Reason}, State0}
            end
    end.

install_recovered(
    [],
    _EventTab,
    _RecordsTab,
    NextDocId,
    Unique,
    Duplicates
) ->
    {NextDocId, Unique, Duplicates};
install_recovered(
    [Record | Rest],
    EventTab,
    RecordsTab,
    NextDocId,
    Unique,
    Duplicates
) ->
    EventId = maps:get(event_id, Record),
    case ets:member(EventTab, EventId) of
        true ->
            install_recovered(
                Rest,
                EventTab,
                RecordsTab,
                NextDocId,
                Unique,
                Duplicates + 1
            );
        false ->
            ok = insert_record(EventTab, RecordsTab, NextDocId, Record),
            install_recovered(
                Rest,
                EventTab,
                RecordsTab,
                NextDocId + 1,
                Unique + 1,
                Duplicates
            )
    end.

install_new_records(Records, State0) ->
    FirstDocId = State0#st.next_doc_id,
    NextDocId = lists:foldl(
        fun(Record, DocId) ->
            ok = insert_record(
                State0#st.event_tab,
                State0#st.records_tab,
                DocId,
                Record
            ),
            DocId + 1
        end,
        FirstDocId,
        Records
    ),
    LastDocId = NextDocId - 1,
    {State0#st{next_doc_id = NextDocId}, FirstDocId, LastDocId}.

insert_record(EventTab, RecordsTab, DocId, Record) ->
    EventId = maps:get(event_id, Record),
    true = ets:insert(EventTab, {EventId, DocId}),
    true = ets:insert(RecordsTab, {DocId, Record}),
    ok.

lookup_doc_reply(DocId, RecordsTab) ->
    case ets:lookup(RecordsTab, DocId) of
        [{DocId, Record}] -> {ok, #{doc_id => DocId, record => Record}};
        [] -> not_found
    end.

list_records_from_ets(RecordsTab, Limit) ->
    list_records_from_ets(RecordsTab, ets:first(RecordsTab), Limit, []).

list_records_from_ets(_RecordsTab, '$end_of_table', _Remaining, Acc) ->
    lists:reverse(Acc);
list_records_from_ets(_RecordsTab, _Key, 0, Acc) ->
    lists:reverse(Acc);
list_records_from_ets(RecordsTab, DocId, Remaining, Acc) ->
    [{DocId, Record}] = ets:lookup(RecordsTab, DocId),
    Next = ets:next(RecordsTab, DocId),
    list_records_from_ets(
        RecordsTab,
        Next,
        Remaining - 1,
        [#{doc_id => DocId, record => Record} | Acc]
    ).

committed_ack(Submission, BatchMeta, FirstDocId, LastDocId) ->
    BatchId = maps:get(batch_id, BatchMeta),
    NewCount = maps:get(event_count, BatchMeta),
    #{
        accepted => true,
        durable => true,
        ledger_visible => true,
        index_searchable => false,
        submitted => maps:get(submitted, Submission),
        durable_new => NewCount,
        duplicates => maps:get(duplicates, Submission),
        batch_id => BatchId,
        batch_id_hex => ecai_ingest_event:id_hex(BatchId),
        wal_bytes_written => maps:get(bytes, BatchMeta),
        first_doc_id => FirstDocId,
        last_doc_id => LastDocId
    }.

duplicate_ack(Submission) ->
    #{
        accepted => true,
        durable => true,
        ledger_visible => true,
        index_searchable => false,
        submitted => maps:get(submitted, Submission),
        durable_new => 0,
        duplicates => maps:get(duplicates, Submission),
        batch_id => undefined,
        batch_id_hex => undefined,
        wal_bytes_written => 0,
        first_doc_id => undefined,
        last_doc_id => undefined
    }.

status_map(State) ->
    WalStats = ecai_wal:stats(State#st.wal),
    {message_queue_len, QueueLen} = process_info(self(), message_queue_len),
    WalStats#{
        base_dir => State#st.base_dir,
        ready => true,
        writer_pid => self(),
        message_queue_len => QueueLen,
        record_count => ets:info(State#st.records_tab, size),
        next_doc_id => State#st.next_doc_id,
        recovered_unique => State#st.recovered_unique,
        recovered_duplicates => State#st.recovered_duplicates,
        repaired_bytes_at_startup => State#st.repaired_bytes,
        durability_scope => local_wal,
        publication_state => ledger_only,
        index_searchable => false
    }.

normalize_base_dir(BaseDir) when is_binary(BaseDir), byte_size(BaseDir) > 0 ->
    try unicode:characters_to_list(BaseDir) of
        List when is_list(List), List =/= [] ->
            {ok, filename:absname(List)};
        _ ->
            {error, invalid_base_dir}
    catch
        _:_ -> {error, invalid_base_dir}
    end;
normalize_base_dir(BaseDir) when is_list(BaseDir), BaseDir =/= [] ->
    try
        {ok, filename:absname(BaseDir)}
    catch
        _:_ -> {error, invalid_base_dir}
    end;
normalize_base_dir(_Invalid) ->
    {error, invalid_base_dir}.

log_recovery(BaseDir, Recovery, Unique, Duplicates) ->
    RepairedBytes = maps:get(repaired_bytes, Recovery),
    Args = [
        BaseDir,
        maps:get(batch_count, Recovery),
        maps:get(event_count, Recovery),
        Unique,
        Duplicates,
        RepairedBytes
    ],
    case RepairedBytes of
        0 ->
            ?LOG_INFO(
                "ECAI ingest WAL ready base_dir=~ts batches=~B events=~B unique=~B duplicates=~B repaired_bytes=~B",
                Args
            );
        _ ->
            ?LOG_WARNING(
                "ECAI ingest WAL repaired an incomplete tail base_dir=~ts batches=~B events=~B unique=~B duplicates=~B repaired_bytes=~B",
                Args
            )
    end.

run_test_hook(Point, Opts) ->
    case maps:get(test_hook, Opts, undefined) of
        Fun when is_function(Fun, 1) -> Fun(Point);
        _ -> ok
    end.
