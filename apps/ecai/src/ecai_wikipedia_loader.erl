%% =====================================================================
%% wikipedia_loader.erl  --  Minimal Wikipedia JSONL loader
%% =====================================================================
-module(ecai_wikipedia_loader).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-export(
    [
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
-export([
    load/1,
    load/2,
    load_auto/1,
    load_chunks/1,
    load_chunks/2,
    tune_memory_opts/1,
    system_memory/0,
    get_wikipedia_job/1
]).
-import(damage_utils, [ensure_dir/1]).

-include_lib("kernel/include/logger.hrl").

%% Defaults (tune for your box; values are bytes)

%% not used in line-mode; keep if you switch to slab mode
-define(SLAB, 256 * 1024).
%% 8 GiB  (pause when over this)
-define(MEM_HIGH, 4 bsl 30).
%% 6 GiB  (resume when below this)
-define(MEM_LOW, 3 bsl 30).
%% 1 GiB  (binary heap backpressure)
-define(BIN_HIGH, 1 bsl 30).
%% polling interval during pause
-define(SNOOZE_MS, 200).
%% Defaults (tweak as you like)
-define(CHK_DIR, "/var/lib/damage/ecai/state/wiki_checkpoints").
-define(CHK_EVERY, 100).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #{}, {continue, start_indexing}}.

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
handle_continue(start_indexing, Ctx) ->
    %Chunk = get_wikipedia_job(Ctx),
    %load(Chunk),
    {noreply, Ctx}.
terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
get_wikipedia_job(#{public_key := AeAccount, metadata := MetaData, knowledge := Knowledge}) ->
    KeyPair = #{public_key := _NodePub, private_key := _NodePriv} = secrets:node_keypair(),
    damage_ae:contract_call(
        KeyPair,
        ct_id(#{}),
        "contracts/knowledge_nft.aes",
        "mint",
        [AeAccount, MetaData, Knowledge]
    ).

%% ---------------- Public API ----------------
%% Pull the contract id from Opts or application env
-spec ct_id(map()) -> binary().
ct_id(Opts) ->
    case maps:get(ct, Opts, undefined) of
        <<"ct_", _/binary>> = Ct ->
            Ct;
        _ ->
            case application:get_env(ecai, index_registry_ct) of
                {ok, <<"ct_", _/binary>> = C} -> C;
                _ -> error({missing_contract_id, index_registry_ct})
            end
    end.

load(SourceRef) ->
    %% Defaults:
    %%  - auto_tune=true: thresholds are derived from *system* memory (moderate profile)
    %%  - backpressure is based on erlang:memory/0, but tuned against host capacity
    Opts = tune_memory_opts(#{
        auto_tune => true,
        mem_profile => moderate,
        snooze_ms => ?SNOOZE_MS
    }),
    load(SourceRef, Opts).

%% Convenience: always auto-tune with the moderate profile.
load_auto(SourceRef) ->
    load(SourceRef, #{auto_tune => true, mem_profile => moderate}).

%% Directly consume the descriptor maps returned by
%% ecai_wikipedia_chunker:make_chunks_ndjson/3 while still accepting paths.
load_chunks(ChunkRefs) when is_list(ChunkRefs) ->
    load_chunks(ChunkRefs, #{auto_tune => true, mem_profile => moderate}).

load_chunks(ChunkRefs, Opts) when is_list(ChunkRefs), is_map(Opts) ->
    load_chunk_refs(ChunkRefs, Opts);
load_chunks(_ChunkRefs, _Opts) ->
    {error, badarg}.

%% Opts may include:
%%  #{mem_high:=Bytes, mem_low:=Bytes, bin_high:=Bytes, snooze_ms:=Ms,
%%    checkpoint_dir:=Path, checkpoint_every:=N}
load(SourceRef, Opts0) when
    (is_list(SourceRef) orelse is_binary(SourceRef) orelse is_map(SourceRef)),
    is_map(Opts0)
->
    File = source_path(SourceRef),
    %% merge defaults
    Opts1 = maps:merge(
        #{
            checkpoint_dir => ?CHK_DIR,
            checkpoint_every => ?CHK_EVERY,
            checkpoint_enabled => true,
            auto_tune => false,
            mem_profile => moderate,
            tune_every_ms => 2000,
            snooze_ms => ?SNOOZE_MS,
            %% Safe fallbacks (used if auto_tune=false)
            mem_high => ?MEM_HIGH,
            mem_low => ?MEM_LOW,
            bin_high => ?BIN_HIGH
        },
        Opts0
    ),
    Opts = tune_memory_opts(Opts1),
    ChkDir = maps:get(checkpoint_dir, Opts),
    ok = ensure_dir(ChkDir),
    CkptPath = checkpoint_path(ChkDir, File),

    case file:open(File, [read, raw, binary]) of
        {ok, IoDevice} ->
            %% A durable live-search snapshot is not committed together with
            %% this local offset. Pipeline jobs therefore disable loader
            %% checkpoints and replay their bounded index-input file safely.
            case initial_checkpoint(Opts, CkptPath) of
                {ok, Off, LinesDone} ->
                    _ = file:position(IoDevice, Off),
                    ?LOG_INFO("Resuming ~s at offset ~B (lines ~B)", [File, Off, LinesDone]),
                    try
                        read_lines(IoDevice, File, Opts, CkptPath, LinesDone)
                    after
                        file:close(IoDevice)
                    end;
                not_found ->
                    ?LOG_INFO("Starting fresh: ~s", [File]),
                    try
                        read_lines(IoDevice, File, Opts, CkptPath, 0)
                    after
                        file:close(IoDevice)
                    end
            end;
        {error, Reason} ->
            ?LOG_ERROR("Error opening ~s: ~p", [File, Reason]),
            {error, Reason}
    end;
load(_SourceRef, _Opts) ->
    {error, badarg}.

%% ---------------- Streaming (line-by-line) with checkpointing --------

read_lines(IoDevice, _File, Opts0, CkptPath, Lines0) ->
    %% Backpressure check (and optional retune) before each read
    Opts = maybe_backpressure(Opts0),
    case file:read_line(IoDevice) of
        eof ->
            %% success: remove checkpoint
            _ = file:delete(CkptPath),
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Error reading line: ~p", [Reason]),
            {error, Reason};
        {ok, Line} ->
            case safe_decode(Line) of
                skip ->
                    read_lines(IoDevice, _File, Opts, CkptPath, Lines0);
                DecodedJson ->
                    ok = default_index(DecodedJson, Opts),
                    Lines1 = Lines0 + 1,
                    %% periodic checkpoint
                    case checkpoint_due(Opts, Lines1) of
                        true ->
                            {ok, CurOff} = file:position(IoDevice, cur),
                            ?LOG_INFO("write_checkpoint current offset: ~p read lines ~p", [
                                CurOff, Lines1
                            ]),
                            ok = write_checkpoint(CkptPath, CurOff, Lines1),
                            read_lines(IoDevice, _File, Opts, CkptPath, Lines1);
                        false ->
                            read_lines(IoDevice, _File, Opts, CkptPath, Lines1)
                    end
            end
    end.

safe_decode(Line0) ->
    %% Validate before decoding so malformed UTF-8 never reaches the index.
    case line_binary(Line0) of
        {ok, <<>>} ->
            skip;
        {ok, <<"\n">>} ->
            skip;
        {ok, <<"\r\n">>} ->
            skip;
        {ok, Line} ->
            case ecai_chunker:validate_utf8(Line) of
                ok ->
                    try simdjson:decode(Line) of
                        M when is_map(M) -> M;
                        _ -> skip
                    catch
                        _:_ -> skip
                    end;
                {error, _Reason} ->
                    skip
            end;
        error ->
            skip
    end.

load_chunk_refs([], _Opts) ->
    ok;
load_chunk_refs([ChunkRef | Rest], Opts) ->
    case load(ChunkRef, Opts) of
        ok -> load_chunk_refs(Rest, Opts);
        {error, _Reason} = Error -> Error
    end.

source_path(SourceRef) ->
    to_list(ecai_chunker:chunk_path(SourceRef)).

line_binary(Bin) when is_binary(Bin) ->
    {ok, Bin};
line_binary(List) when is_list(List) ->
    try
        {ok, unicode:characters_to_binary(List)}
    catch
        _:_ -> error
    end;
line_binary(_Other) ->
    error.

initial_checkpoint(Opts, CkptPath) ->
    case maps:get(checkpoint_enabled, Opts, true) of
        true ->
            read_checkpoint(CkptPath);
        false ->
            _ = file:delete(CkptPath),
            not_found
    end.

checkpoint_due(Opts, Lines) ->
    case maps:get(checkpoint_enabled, Opts, true) of
        false ->
            false;
        true ->
            case maps:get(checkpoint_every, Opts, ?CHK_EVERY) of
                N when is_integer(N), N > 0 -> Lines rem N =:= 0;
                _ -> false
            end
    end.

checkpoint_path(Dir, FilePath) ->
    %% content-address the *path* to avoid clashes
    Hash = ecai_utils:hex(crypto:hash(sha256, list_to_binary(FilePath))),
    filename:join(Dir, Hash ++ ".ckpt").

write_checkpoint(Path, Offset, Lines) ->
    Term = {offset, Offset, lines, Lines},
    Tmp = Path ++ ".tmp",
    ok = file:write_file(Tmp, term_to_binary(Term), [raw, binary, sync]),
    ok = file:rename(Tmp, Path),
    ok.

read_checkpoint(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            try binary_to_term(Bin, [safe]) of
                {offset, Off, lines, N} when
                    is_integer(Off),
                    Off >= 0,
                    is_integer(N),
                    N >= 0
                ->
                    {ok, Off, N};
                _ ->
                    not_found
            catch
                error:badarg -> not_found
            end;
        _ ->
            not_found
    end.

%% ---------------- Memory backpressure ----------------

maybe_backpressure(Opts0) ->
    %% Optionally re-tune thresholds against host memory every tune_every_ms.
    Opts1 = maybe_retune(Opts0),
    #{mem_high := MH, mem_low := _ML, bin_high := BH, snooze_ms := Ms} = Opts1,

    Mem = erlang:memory(),
    Total = proplists:get_value(total, Mem),
    Bins = proplists:get_value(binary, Mem),
    case (Total >= MH) orelse (Bins >= BH) of
        false ->
            Opts1;
        true ->
            ?LOG_WARNING("Memory high: total=~B, bins=~B (pausing)", [Total, Bins]),
            %% Light GC to drop short-lived binaries, then poll until below low watermark
            erlang:garbage_collect(self()),
            pause_until_safe(Opts1, Ms)
    end.

pause_until_safe(Opts0, Ms) ->
    %% While paused, keep polling and allow thresholds to adapt (e.g., other processes free RAM).
    Opts1 = maybe_retune(Opts0),
    #{mem_low := MemLow, bin_high := BinHigh} = Opts1,
    Mem = erlang:memory(),
    Total = proplists:get_value(total, Mem),
    Bins = proplists:get_value(binary, Mem),
    case (Total =< MemLow) andalso (Bins =< BinHigh) of
        true ->
            ?LOG_INFO("Memory ok: total=~B, bins=~B (resuming)", [Total, Bins]),
            Opts1;
        false ->
            timer:sleep(Ms),
            %% (optional) tick another GC occasionally
            pause_until_safe(Opts1, Ms)
    end.

%% ---------------- Auto-tuned memory thresholds ----------------
%% The goal: "moderate" memory use that scales with host RAM.
%%
%% Keys:
%%  auto_tune      := boolean()
%%  mem_profile    := conservative | moderate | aggressive
%%  tune_every_ms  := integer()   (how often to re-evaluate host memory)
%%  tuned_at_ms    := integer()   (monotonic timestamp)
%%  tuned_from     := #{total:=Bytes, available:=Bytes}  (for logging/debug)
%%
%% We tune mem_high/mem_low/bin_high (bytes) used by maybe_backpressure/1.

-spec tune_memory_opts(map()) -> map().
tune_memory_opts(Opts0) ->
    case maps:get(auto_tune, Opts0, false) of
        false ->
            Opts0;
        true ->
            Sys = system_memory(),
            Profile = maps:get(mem_profile, Opts0, moderate),
            Tuned = tuned_thresholds(Profile, Sys),
            Now = erlang:monotonic_time(millisecond),
            maps:merge(Opts0, Tuned#{tuned_at_ms => Now, tuned_from => Sys})
    end.

-spec maybe_retune(map()) -> map().
maybe_retune(Opts0) ->
    case maps:get(auto_tune, Opts0, false) of
        false ->
            Opts0;
        true ->
            Now = erlang:monotonic_time(millisecond),
            Every = maps:get(tune_every_ms, Opts0, 2000),
            Last = maps:get(tuned_at_ms, Opts0, 0),
            case (Now - Last) >= Every of
                false ->
                    Opts0;
                true ->
                    tune_memory_opts(Opts0)
            end
    end.

-spec tuned_thresholds(conservative | moderate | aggressive, map()) -> map().
tuned_thresholds(Profile, #{total := Total, available := Avail}) ->
    %% Ratios are against TOTAL physical memory, but we also cap by AVAILABLE
    %% to behave well under external memory pressure.
    {HighR, LowR, BinR} =
        case Profile of
            conservative -> {0.45, 0.35, 0.10};
            aggressive -> {0.70, 0.60, 0.20};
            _moderate -> {0.55, 0.45, 0.12}
        end,

    High0 = trunc(Total * HighR),
    Low0 = trunc(Total * LowR),
    Bin0 = trunc(Total * BinR),

    %% Keep headroom for OS/other processes by capping against AVAILABLE.
    High1 = min(High0, trunc(Avail * 0.85)),
    Low1 = min(Low0, trunc(Avail * 0.75)),

    %% Floors must scale down on small operators. The previous 1 GiB floor
    %% could disable backpressure entirely on a sub-GiB host.
    MinHigh = erlang:min(256 bsl 20, erlang:max(64 bsl 20, Avail div 2)),
    High = erlang:max(High1, MinHigh),
    Low = erlang:max(
        32 bsl 20,
        erlang:min(Low1, erlang:max(32 bsl 20, High - (32 bsl 20)))
    ),
    BinHigh = erlang:max(32 bsl 20, erlang:min(Bin0, High div 3)),

    #{mem_high => High, mem_low => Low, bin_high => BinHigh}.

-spec system_memory() -> #{total := non_neg_integer(), available := non_neg_integer()}.
system_memory() ->
    %% Prefer os_mon's memsup when available; fall back to /proc/meminfo; then best-effort.
    case system_memory_memsup() of
        {ok, M} ->
            M;
        _ ->
            case system_memory_procfs() of
                {ok, M2} ->
                    M2;
                _ ->
                    Mem = erlang:memory(),
                    Used = proplists:get_value(total, Mem, 0),
                    %% Best-effort fallback (keeps behaviour similar to old defaults)
                    Total = 8 bsl 30,
                    Avail = max(Total - Used, 1 bsl 30),
                    #{total => Total, available => Avail}
            end
    end.

system_memory_memsup() ->
    case code:ensure_loaded(memsup) of
        {module, memsup} ->
            try
                _ = application:ensure_all_started(os_mon),
                Data = memsup:get_system_memory_data(),
                %% memsup reports byte counts. Do not scale these values again.
                TotalBytes = proplists:get_value(total_memory, Data, undefined),
                AvailableBytes =
                    case proplists:get_value(available_memory, Data, undefined) of
                        undefined ->
                            Free = proplists:get_value(free_memory, Data, 0),
                            Cached = proplists:get_value(cached_memory, Data, 0),
                            Buffered = proplists:get_value(buffered_memory, Data, 0),
                            Free + Cached + Buffered;
                        Value ->
                            Value
                    end,
                case TotalBytes of
                    undefined -> {error, no_total};
                    _ -> {ok, #{total => TotalBytes, available => AvailableBytes}}
                end
            catch
                _:_ -> {error, memsup_failed}
            end;
        _ ->
            {error, no_memsup}
    end.

system_memory_procfs() ->
    case file:read_file("/proc/meminfo") of
        {ok, Bin} ->
            Lines = binary:split(Bin, <<"\n">>, [global]),
            TotalKB = meminfo_kb(Lines, <<"MemTotal:">>),
            AvailKB = meminfo_kb(Lines, <<"MemAvailable:">>),
            case {TotalKB, AvailKB} of
                {undefined, _} -> {error, no_total};
                {T, undefined} -> {ok, #{total => T * 1024, available => T * 1024}};
                {T, A} -> {ok, #{total => T * 1024, available => A * 1024}}
            end;
        _ ->
            {error, no_procfs}
    end.

meminfo_kb(Lines, Key) ->
    Found = lists:filter(fun(L) -> binary:match(L, Key) =/= nomatch end, Lines),
    case Found of
        [L | _] ->
            case re:run(L, <<"([0-9]+)">>, [{capture, [1], binary}]) of
                {match, [NumBin]} -> binary_to_integer(NumBin);
                _ -> undefined
            end;
        _ ->
            undefined
    end.

%% ---------------- Default indexer (unchanged) ----------------

default_index(Json, Opts) when is_map(Json), is_map(Opts) ->
    Ctx = index_context(Opts),
    {DocId, Rec} = wiki_to_search_record(Json),
    ok = ecai_search:upsert_record(Ctx, DocId, Rec),
    Abstract = maps:get(<<"abstract">>, Json, <<>>),
    ecai_search:index_text(Ctx, DocId, <<"abstract">>, Abstract, 120),
    ok.

index_context(Opts) ->
    case maps:find(ctx, Opts) of
        {ok, Ctx} -> Ctx;
        error -> ecai_search_server:get_ctx()
    end.

wiki_to_search_record(J) ->
    Name = b(maps:get(<<"name">>, J, <<>>)),
    %% canonical article URL
    Url = b(maps:get(<<"url">>, J, <<>>)),
    LangId = get_in(J, [<<"in_language">>, <<"identifier">>], <<"en">>),
    Abs = b(maps:get(<<"abstract">>, J, <<>>)),
    PageId0 =
        case maps:get(<<"identifier">>, J, undefined) of
            I when is_integer(I) -> list_to_binary(integer_to_list(I));
            I when is_binary(I) -> I;
            _ -> crypto:hash(sha256, Url)
        end,
    Project = get_in(J, [<<"ecai_source">>, <<"project">>], <<>>),
    %% Wikimedia page IDs are project-local. Preserve the historical bare ID
    %% for legacy records, but namespace visibility-pipeline documents so
    %% enwiki:42 and frwiki:42 cannot overwrite one another.
    PageId =
        case Project of
            P when is_binary(P), byte_size(P) > 0 -> <<P/binary, ":", PageId0/binary>>;
            _ -> PageId0
        end,
    Image = get_in(J, [<<"image">>, <<"content_url">>], <<>>),
    WikiData = get_in(J, [<<"main_entity">>, <<"identifier">>], <<>>),
    Visibility = maps:get(<<"visibility">>, J, #{}),
    Pageviews = map_int(Visibility, <<"pageviews">>, 0),
    ActiveMonths = map_int(Visibility, <<"active_months">>, 0),
    VisibilityRank = map_int(Visibility, <<"rank">>, 0),
    Categories = binary_list(maps:get(<<"categories">>, J, [])),
    Redirects = binary_list(maps:get(<<"redirects">>, J, [])),
    Data = #{
        name => Name,
        title => Name,
        category => <<"wikipedia">>,
        tags => wiki_tags(LangId, WikiData, Categories),
        link => Url,
        url => Url,
        abstract => Abs,
        text => Abs,
        language => LangId,
        image => Image,
        wikidata_id => WikiData,
        date_modified => b(maps:get(<<"date_modified">>, J, <<>>)),
        license => wiki_license_list(J),
        pageviews => Pageviews,
        active_months => ActiveMonths,
        visibility_rank => VisibilityRank,
        redirects => Redirects,
        categories => Categories,
        ecai_source => maps:get(<<"ecai_source">>, J, #{})
    },
    {PageId, Data}.

%% ---------------- Helpers ----------------

b(B) when is_binary(B) -> binary:copy(B);
b(L) when is_list(L) -> list_to_binary(L);
b(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

get_in(Map, [K | Ks], Default) when is_map(Map) ->
    case maps:get(K, Map, '$nope') of
        '$nope' -> Default;
        V when Ks =:= [] -> V;
        V -> get_in(V, Ks, Default)
    end;
get_in(_, _, Default) ->
    Default.

wiki_tags(LangId, WD, Categories) ->
    Base0 = [<<"wiki">>, LangId],
    Base =
        case WD of
            <<>> -> Base0;
            _ -> [damage_utils:binarystr_join([<<"wikidata:">>, b(WD)]) | Base0]
        end,
    lists:usort(Base ++ [<<"category:", Category/binary>> || Category <- Categories]).

map_int(Map, Key, Default) when is_map(Map) ->
    case maps:get(Key, Map, Default) of
        Value when is_integer(Value) -> Value;
        Bin when is_binary(Bin) ->
            try
                binary_to_integer(Bin)
            catch
                error:badarg -> Default
            end;
        _ ->
            Default
    end;
map_int(_Map, _Key, Default) ->
    Default.

binary_list(List) when is_list(List) ->
    lists:usort([b(Value) || Value <- List]);
binary_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> [Bin];
binary_list(_Other) ->
    [].

wiki_license_list(J) ->
    case maps:get(<<"license">>, J, []) of
        L when is_list(L) ->
            [
                #{
                    id => maps:get(<<"identifier">>, X, <<>>),
                    name => maps:get(<<"name">>, X, <<>>),
                    url => maps:get(<<"url">>, X, <<>>)
                }
             || X <- L, is_map(X)
            ];
        _ ->
            []
    end.
