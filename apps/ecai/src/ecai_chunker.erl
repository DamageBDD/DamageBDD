%%%-------------------------------------------------------------------
%%% ecai_chunker.erl
%%%
%%% Unified ECAI chunking implementation.
%%%
%%% Compatibility APIs:
%%%   * start/3, status/0, cancel/0, start_link/0 retain the Yelp
%%%     asynchronous chunk-job contract.
%%%   * make_chunks_ndjson/3 retains the Yelp path-list result.
%%%
%%% Shared APIs:
%%%   * start/4 and make_chunks_ndjson/4 support Yelp and Wikipedia
%%%     line-oriented dataset chunking.
%%%   * version/0, validate_utf8/1, chunk_utf8/3 and fold_utf8/5 provide
%%%     deterministic UTF-8 text windows for IPFS and record ingestion.
%%%-------------------------------------------------------------------
-module(ecai_chunker).
-behaviour(gen_server).

-export([
    start_link/0,
    start/3,
    start/4,
    status/0,
    cancel/0,
    make_chunks_ndjson/3,
    make_chunks_ndjson/4,
    chunk_path/1,
    chunk_paths/1,
    line_version/0,
    version/0,
    validate_utf8/1,
    chunk_utf8/3,
    fold_utf8/5
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-export_type([
    chunk/0,
    line_chunk/0,
    chunk_profile/0
]).

-include_lib("kernel/include/logger.hrl").

-define(YELP_CHUNKS_KEY, ecai_admin_chunks).
-define(UTF8_VERSION, <<"ecai-utf8-window/v1">>).
-define(LINE_VERSION, <<"ecai-ndjson-lines/v1">>).

-type chunk_profile() :: yelp | wikipedia.

-type chunk() :: #{
    chunker := binary(),
    ordinal := pos_integer(),
    byte_start := non_neg_integer(),
    byte_end := non_neg_integer(),
    text := binary()
}.

-type line_chunk() :: #{
    path := binary(),
    profile := chunk_profile(),
    index := non_neg_integer(),
    start_line := pos_integer(),
    line_count := pos_integer(),
    chunk_id := <<_:256>>,
    chunker := binary()
}.

-record(state, {
    job_id :: binary() | undefined,
    status :: idle | running | done | canceled | error,
    worker :: pid() | undefined,
    started_at :: integer() | undefined,
    ended_at :: integer() | undefined,
    profile :: chunk_profile() | undefined,
    params :: map() | undefined,
    result :: map() | undefined
}).

%%%===================================================================
%%% Legacy-compatible asynchronous dataset chunk job
%%%===================================================================

-spec start(file:filename_all(), file:filename_all(), pos_integer()) ->
    {ok, binary()} | {error, term()}.
start(InPath, OutDir, ChunkSize) ->
    start(yelp, InPath, OutDir, ChunkSize).

-spec start(
    chunk_profile() | binary() | list(),
    file:filename_all(),
    file:filename_all(),
    pos_integer()
) -> {ok, binary()} | {error, term()}.
start(Profile0, InPath0, OutDir0, ChunkSize) ->
    case normalize_job_params(Profile0, InPath0, OutDir0, ChunkSize) of
        {ok, Params} ->
            ensure_started(),
            gen_server:call(?MODULE, {start, Params}, 5000);
        {error, _Reason} = Error ->
            Error
    end.

-spec status() -> map().
status() ->
    ensure_started(),
    gen_server:call(?MODULE, status, 5000).

-spec cancel() -> map().
cancel() ->
    ensure_started(),
    gen_server:call(?MODULE, cancel, 5000).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, #{}, []).

init(#{} = _Args) ->
    process_flag(trap_exit, true),
    {ok, #state{status = idle}}.

handle_call(status, _From, State) ->
    {reply, state_to_map(State), State};
handle_call(cancel, _From, State = #state{status = running, worker = Worker}) when
    is_pid(Worker)
->
    _ = exit(Worker, kill),
    Next = State#state{
        status = canceled,
        ended_at = now_ms(),
        worker = undefined
    },
    {reply, #{ok => true, status => canceled, job_id => Next#state.job_id}, Next};
handle_call(cancel, _From, State) ->
    Reply = #{
        ok => false,
        reason => not_running,
        status => State#state.status
    },
    {reply, Reply, State};
handle_call({start, _Params}, _From, State = #state{status = running}) ->
    {reply, {error, busy}, State};
handle_call(
    {start, Params = #{profile := Profile, in := InPath, out := OutDir, k := ChunkSize}},
    _From,
    State
) ->
    JobId = make_job_id(),
    Parent = self(),
    Worker = spawn_link(fun() ->
        run_chunk_job(Parent, JobId, Profile, InPath, OutDir, ChunkSize)
    end),
    Next = State#state{
        job_id = JobId,
        status = running,
        worker = Worker,
        started_at = now_ms(),
        ended_at = undefined,
        profile = Profile,
        params = Params,
        result = undefined
    },
    {reply, {ok, JobId}, Next}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({chunk_done, JobId, Result}, State = #state{job_id = JobId}) ->
    Next = State#state{
        status = done,
        ended_at = now_ms(),
        worker = undefined,
        result = Result
    },
    {noreply, Next};
handle_info({chunk_error, JobId, Reason}, State = #state{job_id = JobId}) ->
    Next = State#state{
        status = error,
        ended_at = now_ms(),
        worker = undefined,
        result = #{error => Reason}
    },
    {noreply, Next};
handle_info({'EXIT', Worker, normal}, State = #state{worker = Worker}) ->
    %% The worker sends chunk_done/chunk_error before returning. Exit signals
    %% from the same process are ordered after messages already sent.
    {noreply, State};
handle_info({'EXIT', Worker, Reason}, State = #state{worker = Worker, status = running}) ->
    Next = State#state{
        status = error,
        ended_at = now_ms(),
        worker = undefined,
        result = #{error => {worker_exit, Reason}}
    },
    {noreply, Next};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

run_chunk_job(Parent, JobId, Profile, InPath, OutDir, ChunkSize) ->
    try
        Chunks = make_chunks_ndjson(Profile, InPath, OutDir, ChunkSize),
        Paths = chunk_paths(Chunks),
        maybe_publish_legacy_paths(Profile, Paths),
        Parent !
            {chunk_done, JobId, #{
                profile => Profile,
                count => length(Chunks),
                paths => Paths,
                chunks => Chunks,
                chunker => line_version()
            }}
    catch
        Class:Reason:Stacktrace ->
            ?LOG_ERROR("chunk job failed: ~p:~p ~p", [Class, Reason, Stacktrace]),
            Parent ! {chunk_error, JobId, {Class, Reason}}
    end.

maybe_publish_legacy_paths(yelp, Paths) ->
    persistent_term:put(?YELP_CHUNKS_KEY, Paths),
    ok;
maybe_publish_legacy_paths(_Profile, _Paths) ->
    ok.

%%%===================================================================
%%% Shared line-oriented NDJSON/JSONL chunking
%%%===================================================================

%% Historical Yelp API: return only path binaries and retain the original
%% chunk_000001.ndjson naming convention.
-spec make_chunks_ndjson(file:filename_all(), file:filename_all(), pos_integer()) ->
    [binary()].
make_chunks_ndjson(InPath, OutDir, LinesPerChunk) ->
    chunk_paths(make_chunks_ndjson(yelp, InPath, OutDir, LinesPerChunk)).

%% Shared API. Wikipedia retains zero-based indexes, wiki_chunk_*.jsonl names,
%% and the historical chunk_id calculation used by ecai_wikipedia_chunker.
-spec make_chunks_ndjson(
    chunk_profile() | binary() | list(),
    file:filename_all(),
    file:filename_all(),
    pos_integer()
) -> [line_chunk()].
make_chunks_ndjson(Profile0, InPath0, OutDir0, LinesPerChunk) ->
    case normalize_job_params(Profile0, InPath0, OutDir0, LinesPerChunk) of
        {ok, #{profile := Profile, in := InPathBin, out := OutDirBin, k := K}} ->
            split_ndjson(
                Profile,
                InPathBin,
                OutDirBin,
                K,
                legacy_source_path(InPath0)
            );
        {error, Reason} ->
            erlang:error(Reason)
    end.

-spec chunk_path(file:filename_all() | line_chunk() | map() | tuple()) -> binary().
chunk_path(#{path := Path}) ->
    path_binary(Path);
chunk_path(#{<<"path">> := Path}) ->
    path_binary(Path);
chunk_path({Path, _Metadata}) ->
    path_binary(Path);
chunk_path(Path) when is_binary(Path); is_list(Path) ->
    path_binary(Path);
chunk_path(_Other) ->
    erlang:error(badarg).

-spec chunk_paths([term()]) -> [binary()].
chunk_paths(Chunks) when is_list(Chunks) ->
    [chunk_path(Chunk) || Chunk <- Chunks];
chunk_paths(_Other) ->
    erlang:error(badarg).

-spec line_version() -> binary().
line_version() ->
    ?LINE_VERSION.

split_ndjson(Profile, InPathBin, OutDirBin, LinesPerChunk, SourceIdentityPath) ->
    InPath = path_list(InPathBin),
    OutDir = path_list(OutDirBin),
    ok = ensure_directory(OutDir),
    case file:open(InPath, [read, raw, binary]) of
        {ok, Input} ->
            try
                split_ndjson_loop(
                    Input,
                    Profile,
                    SourceIdentityPath,
                    OutDir,
                    LinesPerChunk,
                    profile_start_index(Profile),
                    1,
                    []
                )
            after
                ok = file:close(Input)
            end;
        {error, Reason} ->
            erlang:error({cannot_open, InPath, Reason})
    end.

split_ndjson_loop(
    Input,
    Profile,
    SourcePath,
    OutDir,
    LinesPerChunk,
    ChunkIndex,
    StartLine,
    Acc
) ->
    case file:read_line(Input) of
        eof ->
            lists:reverse(Acc);
        {ok, FirstLine} ->
            OutputPath = chunk_filename(Profile, OutDir, ChunkIndex),
            {ok, Output} = open_output(OutputPath),
            {LineCount, NextLine, ReachedEof} =
                try
                    ok = file:write(Output, FirstLine),
                    write_chunk_tail(
                        Input,
                        Output,
                        LinesPerChunk - 1,
                        1,
                        StartLine + 1
                    )
                after
                    ok = file:close(Output)
                end,
            Chunk = make_line_chunk(
                Profile,
                SourcePath,
                OutputPath,
                ChunkIndex,
                StartLine,
                LineCount
            ),
            case ReachedEof of
                true ->
                    lists:reverse([Chunk | Acc]);
                false ->
                    split_ndjson_loop(
                        Input,
                        Profile,
                        SourcePath,
                        OutDir,
                        LinesPerChunk,
                        ChunkIndex + 1,
                        NextLine,
                        [Chunk | Acc]
                    )
            end;
        {error, Reason} ->
            erlang:error({read_error, Reason})
    end.

write_chunk_tail(_Input, _Output, 0, LineCount, NextLine) ->
    {LineCount, NextLine, false};
write_chunk_tail(Input, Output, Remaining, LineCount, NextLine) ->
    case file:read_line(Input) of
        eof ->
            {LineCount, NextLine, true};
        {ok, Line} ->
            ok = file:write(Output, Line),
            write_chunk_tail(
                Input,
                Output,
                Remaining - 1,
                LineCount + 1,
                NextLine + 1
            );
        {error, Reason} ->
            erlang:error({read_error, Reason})
    end.

open_output(Path) ->
    case file:open(Path, [write, raw, binary]) of
        {ok, Output} ->
            {ok, Output};
        {error, Reason} ->
            erlang:error({cannot_open_chunk, Path, Reason})
    end.

make_line_chunk(Profile, SourcePath, OutputPath, Index, StartLine, LineCount) ->
    #{
        path => path_binary(OutputPath),
        profile => Profile,
        index => Index,
        start_line => StartLine,
        line_count => LineCount,
        chunk_id => line_chunk_id(Profile, SourcePath, StartLine, LineCount),
        chunker => line_version()
    }.

%% Preserve the exact pre-merge Wikipedia identifier contract.
line_chunk_id(wikipedia, SourcePath, StartLine, LineCount) ->
    crypto:hash(sha256, term_to_binary({SourcePath, StartLine, LineCount}));
line_chunk_id(Profile, SourcePath, StartLine, LineCount) ->
    crypto:hash(
        sha256,
        term_to_binary({line_version(), Profile, SourcePath, StartLine, LineCount})
    ).

profile_start_index(yelp) -> 1;
profile_start_index(wikipedia) -> 0.

chunk_filename(yelp, OutDir, Index) ->
    Name = io_lib:format("chunk_~6..0B.ndjson", [Index]),
    filename:join(OutDir, lists:flatten(Name));
chunk_filename(wikipedia, OutDir, Index) ->
    Name = io_lib:format("wiki_chunk_~6.10.0B.jsonl", [Index]),
    filename:join(OutDir, lists:flatten(Name)).

ensure_directory(OutDir) ->
    Probe = filename:join(OutDir, ".ecai_chunker_dir"),
    case filelib:ensure_dir(Probe) of
        ok -> ok;
        {error, Reason} -> erlang:error({cannot_create_output_dir, OutDir, Reason})
    end.

%%%===================================================================
%%% Deterministic UTF-8 text windows
%%%===================================================================

-spec version() -> binary().
version() ->
    ?UTF8_VERSION.

-spec validate_utf8(binary()) -> ok | {error, {invalid_utf8, non_neg_integer()}}.
validate_utf8(Bin) when is_binary(Bin) ->
    validate_utf8(Bin, 0);
validate_utf8(_Other) ->
    {error, {invalid_utf8, 0}}.

-spec chunk_utf8(binary(), pos_integer(), non_neg_integer()) ->
    {ok, [chunk()]} | {error, term()}.
chunk_utf8(Bin, Size, Overlap) ->
    case
        fold_utf8(
            Bin,
            Size,
            Overlap,
            fun(Chunk, Acc) -> {ok, [Chunk | Acc]} end,
            []
        )
    of
        {ok, Reversed} ->
            {ok, lists:reverse(Reversed)};
        {error, _Reason} = Error ->
            Error
    end.

-spec fold_utf8(
    binary(),
    pos_integer(),
    non_neg_integer(),
    fun((chunk(), term()) -> {ok, term()} | {error, term()}),
    term()
) -> {ok, term()} | {error, term()}.
fold_utf8(Bin, Size, Overlap, Fun, Acc0) when
    is_binary(Bin),
    is_integer(Size),
    Size > 0,
    is_integer(Overlap),
    Overlap >= 0,
    Overlap < Size,
    is_function(Fun, 2)
->
    %% Validate the complete input before invoking a callback. Malformed input
    %% therefore cannot leave a partially indexed source version.
    case validate_utf8(Bin) of
        ok ->
            Step = Size - Overlap,
            fold_utf8_loop(Bin, Size, Step, Fun, Acc0, 1, 0);
        {error, _Reason} = Error ->
            Error
    end;
fold_utf8(_Bin, _Size, _Overlap, _Fun, _Acc0) ->
    {error, badarg}.

fold_utf8_loop(<<>>, _Size, _Step, _Fun, Acc, _Ordinal, _ByteStart) ->
    {ok, Acc};
fold_utf8_loop(Bin, Size, Step, Fun, Acc0, Ordinal, ByteStart) ->
    case byte_offset_after_codepoints(Bin, Size) of
        {eof, ByteEndRelative} ->
            emit_final_utf8_chunk(
                Bin,
                ByteEndRelative,
                Fun,
                Acc0,
                Ordinal,
                ByteStart
            );
        {ok, ByteEndRelative} when ByteEndRelative =:= byte_size(Bin) ->
            emit_final_utf8_chunk(
                Bin,
                ByteEndRelative,
                Fun,
                Acc0,
                Ordinal,
                ByteStart
            );
        {ok, ByteEndRelative} ->
            Chunk = make_utf8_chunk(Bin, ByteEndRelative, Ordinal, ByteStart),
            case invoke_fold_callback(Fun, Chunk, Acc0) of
                {ok, Acc1} ->
                    {ok, StepBytes} = byte_offset_after_codepoints(Bin, Step),
                    NextSize = byte_size(Bin) - StepBytes,
                    Next = binary:part(Bin, StepBytes, NextSize),
                    fold_utf8_loop(
                        Next,
                        Size,
                        Step,
                        Fun,
                        Acc1,
                        Ordinal + 1,
                        ByteStart + StepBytes
                    );
                {error, _Reason} = Error ->
                    Error
            end;
        {error, InvalidOffset} ->
            {error, {invalid_utf8, ByteStart + InvalidOffset}}
    end.

emit_final_utf8_chunk(Bin, ByteEndRelative, Fun, Acc0, Ordinal, ByteStart) ->
    Chunk = make_utf8_chunk(Bin, ByteEndRelative, Ordinal, ByteStart),
    invoke_fold_callback(Fun, Chunk, Acc0).

make_utf8_chunk(Bin, ByteEndRelative, Ordinal, ByteStart) ->
    #{
        chunker => version(),
        ordinal => Ordinal,
        byte_start => ByteStart,
        byte_end => ByteStart + ByteEndRelative,
        text => binary:part(Bin, 0, ByteEndRelative)
    }.

invoke_fold_callback(Fun, Chunk, Acc0) ->
    case Fun(Chunk, Acc0) of
        {ok, _Acc1} = Ok ->
            Ok;
        {error, _Reason} = Error ->
            Error;
        Other ->
            {error, {invalid_callback_return, Other}}
    end.

byte_offset_after_codepoints(Bin, Count) ->
    byte_offset_after_codepoints(Bin, Count, 0).

byte_offset_after_codepoints(_Bin, 0, Offset) ->
    {ok, Offset};
byte_offset_after_codepoints(<<>>, _Count, Offset) ->
    {eof, Offset};
byte_offset_after_codepoints(Bin, Count, Offset) ->
    case next_utf8_length(Bin) of
        {ok, Length} ->
            <<_Codepoint:Length/binary, Rest/binary>> = Bin,
            byte_offset_after_codepoints(Rest, Count - 1, Offset + Length);
        error ->
            {error, Offset}
    end.

validate_utf8(<<>>, _Offset) ->
    ok;
validate_utf8(Bin, Offset) ->
    case next_utf8_length(Bin) of
        {ok, Length} ->
            <<_Codepoint:Length/binary, Rest/binary>> = Bin,
            validate_utf8(Rest, Offset + Length);
        error ->
            {error, {invalid_utf8, Offset}}
    end.

%% RFC 3629-valid UTF-8 scalar sequences. These clauses reject overlong
%% encodings, UTF-16 surrogates, values above U+10FFFF and truncated input.
next_utf8_length(<<C1, _/binary>>) when C1 =< 16#7F ->
    {ok, 1};
next_utf8_length(<<C1, C2, _/binary>>) when
    C1 >= 16#C2,
    C1 =< 16#DF,
    C2 >= 16#80,
    C2 =< 16#BF
->
    {ok, 2};
next_utf8_length(<<16#E0, C2, C3, _/binary>>) when
    C2 >= 16#A0,
    C2 =< 16#BF,
    C3 >= 16#80,
    C3 =< 16#BF
->
    {ok, 3};
next_utf8_length(<<C1, C2, C3, _/binary>>) when
    C1 >= 16#E1,
    C1 =< 16#EC,
    C2 >= 16#80,
    C2 =< 16#BF,
    C3 >= 16#80,
    C3 =< 16#BF
->
    {ok, 3};
next_utf8_length(<<16#ED, C2, C3, _/binary>>) when
    C2 >= 16#80,
    C2 =< 16#9F,
    C3 >= 16#80,
    C3 =< 16#BF
->
    {ok, 3};
next_utf8_length(<<C1, C2, C3, _/binary>>) when
    C1 >= 16#EE,
    C1 =< 16#EF,
    C2 >= 16#80,
    C2 =< 16#BF,
    C3 >= 16#80,
    C3 =< 16#BF
->
    {ok, 3};
next_utf8_length(<<16#F0, C2, C3, C4, _/binary>>) when
    C2 >= 16#90,
    C2 =< 16#BF,
    C3 >= 16#80,
    C3 =< 16#BF,
    C4 >= 16#80,
    C4 =< 16#BF
->
    {ok, 4};
next_utf8_length(<<C1, C2, C3, C4, _/binary>>) when
    C1 >= 16#F1,
    C1 =< 16#F3,
    C2 >= 16#80,
    C2 =< 16#BF,
    C3 >= 16#80,
    C3 =< 16#BF,
    C4 >= 16#80,
    C4 =< 16#BF
->
    {ok, 4};
next_utf8_length(<<16#F4, C2, C3, C4, _/binary>>) when
    C2 >= 16#80,
    C2 =< 16#8F,
    C3 >= 16#80,
    C3 =< 16#BF,
    C4 >= 16#80,
    C4 =< 16#BF
->
    {ok, 4};
next_utf8_length(_Bin) ->
    error.

%%%===================================================================
%%% Shared helpers
%%%===================================================================

normalize_job_params(Profile0, InPath0, OutDir0, ChunkSize) when
    is_integer(ChunkSize), ChunkSize > 0
->
    try
        Profile = normalize_profile(Profile0),
        InPath = path_binary(InPath0),
        OutDir = path_binary(OutDir0),
        {ok, #{profile => Profile, in => InPath, out => OutDir, k => ChunkSize}}
    catch
        error:badarg -> {error, badarg}
    end;
normalize_job_params(_Profile, _InPath, _OutDir, _ChunkSize) ->
    {error, badarg}.

normalize_profile(yelp) -> yelp;
normalize_profile(wikipedia) -> wikipedia;
normalize_profile(<<"yelp">>) -> yelp;
normalize_profile(<<"wikipedia">>) -> wikipedia;
normalize_profile("yelp") -> yelp;
normalize_profile("wikipedia") -> wikipedia;
normalize_profile(_Other) -> erlang:error(badarg).

legacy_source_path(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
legacy_source_path(List) when is_list(List) ->
    List.

ensure_started() ->
    case whereis(?MODULE) of
        undefined ->
            case start_link() of
                {ok, _Pid} -> ok;
                {error, {already_started, _Pid}} -> ok;
                {error, Reason} -> exit({start_failed, Reason})
            end;
        _Pid ->
            ok
    end.

state_to_map(#state{
    job_id = JobId,
    status = Status,
    started_at = StartedAt,
    ended_at = EndedAt,
    profile = Profile,
    params = Params,
    result = Result
}) ->
    #{
        job_id => JobId,
        status => Status,
        started_at => StartedAt,
        ended_at => EndedAt,
        profile => Profile,
        params => Params,
        result => Result
    }.

make_job_id() ->
    Bin = crypto:strong_rand_bytes(12),
    <<
        <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 16#0F))>>
     || <<Byte:8>> <= Bin
    >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $A + (N - 10).

now_ms() ->
    erlang:system_time(millisecond).

path_binary(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    Bin;
path_binary(List) when is_list(List), List =/= [] ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin), byte_size(Bin) > 0 -> Bin;
        _Invalid -> erlang:error(badarg)
    end;
path_binary(_Other) ->
    erlang:error(badarg).

%% Use byte-preserving conversion for binary paths. This matches the original
%% Wikipedia chunker and therefore preserves its chunk_id for non-ASCII paths.
path_list(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
path_list(List) when is_list(List) ->
    List.
