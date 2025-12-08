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
    get_wikipedia_job/1
]).
-import(damage_utils, [ensure_dir/1]).

-include_lib("kernel/include/logger.hrl").

%% Defaults (tune for your box; values are bytes)

%% not used in line-mode; keep if you switch to slab mode
-define(SLAB, 256 * 1024).
%% 8 GiB  (pause when over this)
-define(MEM_HIGH, 24 bsl 30).
%% 6 GiB  (resume when below this)
-define(MEM_LOW, 16 bsl 30).
%% 1 GiB  (binary heap backpressure)
-define(BIN_HIGH, 6 bsl 30).
%% polling interval during pause
-define(SNOOZE_MS, 200).
%% Defaults (tweak as you like)
-define(CHK_DIR, "/var/lib/damage/ecai/state/wiki_checkpoints").
-define(CHK_EVERY, 1000).

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

load(FilePath) ->
    %% defaults: pause if total > 8GiB OR binaries > 1GiB; resume below 6GiB
    Opts = #{
        mem_high => ?MEM_HIGH,
        mem_low => ?MEM_LOW,
        bin_high => ?BIN_HIGH,
        snooze_ms => ?SNOOZE_MS
    },
    load(FilePath, Opts).

%% Opts may include:
%%  #{mem_high:=Bytes, mem_low:=Bytes, bin_high:=Bytes, snooze_ms:=Ms,
%%    checkpoint_dir:=Path, checkpoint_every:=N}
load(FilePath, Opts0) when is_list(FilePath); is_binary(FilePath) ->
    File = to_list(FilePath),
    %% merge defaults
    Opts = maps:merge(
        #{checkpoint_dir => ?CHK_DIR, checkpoint_every => ?CHK_EVERY},
        Opts0
    ),
    ChkDir = maps:get(checkpoint_dir, Opts),
    ok = ensure_dir(ChkDir),
    CkptPath = checkpoint_path(ChkDir, File),

    case file:open(File, [read]) of
        {ok, IoDevice} ->
            %% resume if we have a checkpoint
            case read_checkpoint(CkptPath) of
                {ok, Off, LinesDone} ->
                    _ = file:position(IoDevice, Off),
                    ?LOG_INFO("Resuming ~s at offset ~B (lines ~B)", [File, Off, LinesDone]),
                    try
                        read_lines(IoDevice, File, Opts, CkptPath, LinesDone)
                    after
                        file:close(IoDevice)
                    end,
                    ok;
                not_found ->
                    ?LOG_INFO("Starting fresh: ~s", [File]),
                    try
                        read_lines(IoDevice, File, Opts, CkptPath, 0)
                    after
                        file:close(IoDevice)
                    end,
                    ok
            end;
        {error, Reason} ->
            ?LOG_ERROR("Error opening ~s: ~p", [File, Reason]),
            {error, Reason}
    end.

%% ---------------- Streaming (line-by-line) with checkpointing --------

read_lines(IoDevice, _File, Opts, CkptPath, Lines0) ->
    %% Backpressure check before each read
    maybe_backpressure(Opts),
    case io:get_line(IoDevice, '') of
        eof ->
            %% success: remove checkpoint
            _ = file:delete(CkptPath),
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Error reading line: ~p", [Reason]),
            {error, Reason};
        Line ->
            case safe_decode(Line) of
                skip ->
                    read_lines(IoDevice, _File, Opts, CkptPath, Lines0);
                DecodedJson ->
                    ok = default_index(DecodedJson),
                    Lines1 = Lines0 + 1,
                    %% periodic checkpoint
                    N = maps:get(checkpoint_every, Opts, ?CHK_EVERY),
                    case Lines1 rem N of
                        0 ->
                            {ok, CurOff} = file:position(IoDevice, cur),
                            ?LOG_INFO("write_checkpoint ~p ~p", [CurOff, Lines1]),
                            ok = write_checkpoint(CkptPath, CurOff, Lines1),
                            read_lines(IoDevice, _File, Opts, CkptPath, Lines1);
                        _ ->
                            read_lines(IoDevice, _File, Opts, CkptPath, Lines1)
                    end
            end
    end.

safe_decode(Line) ->
    %% Trim CR/LF and skip blanks; tolerate occasional bad lines
    %Bin = trim_nl(list_to_binary(Line)),
    case Line of
        <<>> ->
            skip;
        _ ->
            try simdjson:decode(Line) of
                %try jsx:decode(Bin) of
                M when is_map(M) -> M;
                _ -> skip
            catch
                _:_ -> skip
            end
    end.

checkpoint_path(Dir, FilePath) ->
    %% content-address the *path* to avoid clashes
    Hash = ecai_utils:hex(crypto:hash(sha256, list_to_binary(FilePath))),
    filename:join(Dir, Hash ++ ".ckpt").

write_checkpoint(Path, Offset, Lines) ->
    Term = {offset, Offset, lines, Lines},
    Tmp = Path ++ ".tmp",
    ok = file:write_file(Tmp, term_to_binary(Term), [raw, binary]),
    ok = file:rename(Tmp, Path),
    ok.

read_checkpoint(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case binary_to_term(Bin) of
                {offset, Off, lines, N} when is_integer(Off), is_integer(N) ->
                    {ok, Off, N};
                _ ->
                    not_found
            end;
        _ ->
            not_found
    end.

%% ---------------- Memory backpressure ----------------

maybe_backpressure(#{mem_high := MH, mem_low := ML, bin_high := BH, snooze_ms := Ms}) ->
    Mem = erlang:memory(),
    Total = proplists:get_value(total, Mem),
    Bins = proplists:get_value(binary, Mem),
    case (Total >= MH) orelse (Bins >= BH) of
        %% proceed
        false ->
            ok;
        true ->
            ?LOG_WARNING("Memory high: total=~B, bins=~B (pausing)", [Total, Bins]),
            %% Light GC to drop short-lived binaries, then poll until below low watermark
            erlang:garbage_collect(self()),
            pause_until_safe(ML, BH, Ms)
    end.

pause_until_safe(MemLow, BinHigh, Ms) ->
    Mem = erlang:memory(),
    Total = proplists:get_value(total, Mem),
    Bins = proplists:get_value(binary, Mem),
    case (Total =< MemLow) andalso (Bins =< BinHigh) of
        true ->
            ?LOG_INFO("Memory ok: total=~B, bins=~B (resuming)", [Total, Bins]);
        false ->
            timer:sleep(Ms),
            %% (optional) tick another GC occasionally
            pause_until_safe(MemLow, BinHigh, Ms)
    end.

%% ---------------- Default indexer (unchanged) ----------------

default_index(Json) when is_map(Json) ->
    Ctx = ecai_search_server:get_ctx(),
    {DocId, Rec} = wiki_to_search_record(Json),
    ok = ecai_search:upsert_record(Ctx, DocId, Rec),
    Abstract = maps:get(<<"abstract">>, Json, <<>>),
    ecai_search:index_text(Ctx, DocId, <<"abstract">>, Abstract, 120),
    ok.

wiki_to_search_record(J) ->
    Name = b(maps:get(<<"name">>, J, <<>>)),
    %% canonical article URL
    Url = b(maps:get(<<"url">>, J, <<>>)),
    LangId = get_in(J, [<<"in_language">>, <<"identifier">>], <<"en">>),
    Abs = b(maps:get(<<"abstract">>, J, <<>>)),
    PageId =
        case maps:get(<<"identifier">>, J, undefined) of
            I when is_integer(I) -> list_to_binary(integer_to_list(I));
            I when is_binary(I) -> I;
            _ -> crypto:hash(sha256, Url)
        end,
    Image = get_in(J, [<<"image">>, <<"content_url">>], <<>>),
    WikiData = get_in(J, [<<"main_entity">>, <<"identifier">>], <<>>),
    Data = #{
        name => Name,
        category => <<"wikipedia">>,
        tags => wiki_tags(LangId, WikiData),
        link => Url,
        url => Url,
        abstract => Abs,
        language => LangId,
        image => Image,
        wikidata_id => WikiData,
        date_modified => b(maps:get(<<"date_modified">>, J, <<>>)),
        license => wiki_license_list(J)
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

wiki_tags(LangId, WD) ->
    Base = [<<"wiki">>, LangId],
    case WD of
        <<>> -> Base;
        _ -> [damage_utils:binarystr_join([<<"wikidata:">>, b(WD)]) | Base]
    end.

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
