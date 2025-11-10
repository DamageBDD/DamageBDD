%% =====================================================================
%% wikipedia_loader.erl  --  Minimal Wikipedia JSONL loader
%% =====================================================================
-module(wikipedia_loader).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").
-export([load/1]).

-include_lib("kernel/include/logger.hrl").


%% Defaults (tune for your box; values are bytes)
-define(SLAB, 256 * 1024).         %% not used in line-mode; keep if you switch to slab mode
-define(MEM_HIGH,  8 bsl 30).      %% 8 GiB  (pause when over this)
-define(MEM_LOW,   6 bsl 30).      %% 6 GiB  (resume when below this)
-define(BIN_HIGH,  1 bsl 30).      %% 1 GiB  (binary heap backpressure)
-define(SNOOZE_MS, 200).           %% polling interval during pause

%% ---------------- Public API ----------------

load(FilePath) ->
    %% defaults: pause if total > 8GiB OR binaries > 1GiB; resume below 6GiB
    Opts = #{
        mem_high => ?MEM_HIGH,
        mem_low  => ?MEM_LOW,
        bin_high => ?BIN_HIGH,
        snooze_ms => ?SNOOZE_MS
    },
    load(FilePath, Opts).

%% Opts = #{mem_high:=Bytes, mem_low:=Bytes, bin_high:=Bytes, snooze_ms:=Ms}
load(FilePath, Opts) when is_list(FilePath); is_binary(FilePath) ->
    File = to_list(FilePath),
    case file:open(File, [read]) of
        {ok, IoDevice} ->
            try read_lines(IoDevice, Opts)
            after file:close(IoDevice) end,
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Error opening ~s: ~p", [File, Reason]),
            {error, Reason}
    end.

%% ---------------- Streaming (line-by-line) ----------------

read_lines(IoDevice, Opts) ->
    %% Backpressure check before each read
    maybe_backpressure(Opts),
    case io:get_line(IoDevice, '') of
        eof ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR("Error reading line: ~p", [Reason]),
            {error, Reason};
        Line ->
            case safe_decode(Line) of
                skip ->
                    read_lines(IoDevice, Opts);
                DecodedJson ->
                    ok = default_index(DecodedJson),
                    read_lines(IoDevice, Opts)
            end
    end.

safe_decode(Line) ->
    %% Trim CR/LF and skip blanks; tolerate occasional bad lines
    Bin = trim_nl(list_to_binary(Line)),
    case Bin of
        <<>> -> skip;
        _ ->
            try jsx:decode(Bin) of
                M when is_map(M) -> M;
                _ -> skip
            catch _:_ -> skip end
    end.

trim_nl(<<$\r, T/binary>>) -> trim_nl(T);
trim_nl(<<$\n, T/binary>>) -> trim_nl(T);
trim_nl(B) -> B.

%% ---------------- Memory backpressure ----------------

maybe_backpressure(#{mem_high := MH, mem_low := ML, bin_high := BH, snooze_ms := Ms}) ->
    Mem = erlang:memory(),
    Total = maps:get(total, Mem),
    Bins  = maps:get(binary, Mem),
    case (Total >= MH) orelse (Bins >= BH) of
        false -> ok;  %% proceed
        true  ->
            ?LOG_WARNING("Memory high: total=~B, bins=~B (pausing)", [Total, Bins]),
            %% Light GC to drop short-lived binaries, then poll until below low watermark
            erlang:garbage_collect(self()),
            pause_until_safe(ML, BH, Ms)
    end.

pause_until_safe(MemLow, BinHigh, Ms) ->
    Mem = erlang:memory(),
    Total = maps:get(total, Mem),
    Bins  = maps:get(binary, Mem),
    case (Total =< MemLow) andalso (Bins =< BinHigh) of
        true  -> ok;
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
    Name   = b(maps:get(<<"name">>, J, <<>>)),
    Url    = b(maps:get(<<"url">>, J, <<>>)),  %% canonical article URL
    LangId = get_in(J, [<<"in_language">>, <<"identifier">>], <<"en">>),
    Abs    = b(maps:get(<<"abstract">>, J, <<>>)),
    PageId =
        case maps:get(<<"identifier">>, J, undefined) of
            I when is_integer(I) -> list_to_binary(integer_to_list(I));
            I when is_binary(I)  -> I;
            _                    -> crypto:hash(sha256, Url)
        end,
    Image    = get_in(J, [<<"image">>, <<"content_url">>], <<>>),
    WikiData = get_in(J, [<<"main_entity">>, <<"identifier">>], <<>>),
    Data = #{
        name         => Name,
        category     => <<"wikipedia">>,
        tags         => wiki_tags(LangId, WikiData),
        link         => Url,
        url          => Url,
        abstract     => Abs,
        language     => LangId,
        image        => Image,
        wikidata_id  => WikiData,
        date_modified => b(maps:get(<<"date_modified">>, J, <<>>)),
        license      => wiki_license_list(J)
    },
    {PageId, Data}.

%% ---------------- Helpers ----------------

b(B) when is_binary(B) -> binary:copy(B);
b(L) when is_list(L)   -> list_to_binary(L);
b(Other)               -> iolist_to_binary(io_lib:format("~p",[Other])).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L)   -> L.

get_in(Map, [K|Ks], Default) when is_map(Map) ->
    case maps:get(K, Map, '$nope') of
        '$nope' -> Default;
        V when Ks =:= [] -> V;
        V -> get_in(V, Ks, Default)
    end;
get_in(_, _, Default) -> Default.

wiki_tags(LangId, WD) ->
    Base = [<<"wiki">>, LangId],
    case WD of
        <<>> -> Base;
        _    -> [damage_utils:binarystr_join([<<"wikidata:">>, b(WD)]) | Base]
    end.

wiki_license_list(J) ->
    case maps:get(<<"license">>, J, []) of
        L when is_list(L) ->
            [ #{ id => maps:get(<<"identifier">>, X, <<>>),
                 name => maps:get(<<"name">>, X, <<>>),
                 url  => maps:get(<<"url">>, X, <<>>)} || X <- L, is_map(X) ];
        _ -> []
    end.

