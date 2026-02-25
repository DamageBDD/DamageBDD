%%-------------------------------------------------------------------
%% steps_ecai_sbrm.erl
%% DamageBDD BDD steps: ECAI + SBRM JSON/JSONL ingestion + index load/query
%%
%% These steps are intentionally "easy mode" wrappers:
%%   - Create a fresh index handle (if the underlying index module supports it)
%%   - Ingest a JSONL (JSON-Lines) file stored on IPFS
%%   - Load an index from disk (if supported)
%%   - Query the index and store results in the scenario context
%%
%% Notes:
%%   * This module targets the ECAI SBRM financial ingestion pipeline:
%%       ecai_sbrm_ipfs_financial_ingest
%%       ecai_sbrm_financial_statement_ingestor
%%       ecai_named_set_index
%%
%%   * We don't assume one canonical API for ecai_named_set_index.
%%     Where multiple plausible function shapes exist, we probe with
%%     erlang:function_exported/3 and fall back gracefully.
%%
%%   * If no explicit index handle API exists, ingestion will still run
%%     (via ecai_named_set_index:ingest/1), and queries will attempt
%%     ecai_named_set_index:query/1.
%%
%%-------------------------------------------------------------------
-module(steps_ecai_sbrm).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6]).

%% ------------------------------------------------------------------
%% Step patterns
%% ------------------------------------------------------------------
-define(STEP_OPEN_DISK_SEARCH_CTX, [
    "I open the ECAI disk search at base dir",
    BaseDirVar,
    "and store it in",
    Var
]).

-define(STEP_NEW_INDEX_STORE, [
    "I create a new ECAI SBRM index and store it in",
    Var
]).

-define(STEP_LOAD_INDEX_FROM_PATH_STORE, [
    "I load the ECAI SBRM index from the path in",
    PathVar,
    "and store it in",
    Var
]).

-define(STEP_SET_DEFAULT_INDEX, [
    "I set the default ECAI SBRM index to the value in",
    Var
]).

-define(STEP_INGEST_IPFS_JSONL_INTO_INDEX, [
    "I ingest the JSONL file from IPFS hash in",
    IpfsVar,
    "into the ECAI SBRM index in",
    IndexVar
]).

-define(STEP_INGEST_IPFS_JSONL_DEFAULT_INDEX, [
    "I ingest the JSONL file from IPFS hash in",
    IpfsVar,
    "into the default ECAI SBRM index"
]).

-define(STEP_QUERY_INDEX_STORE, [
    "I query the ECAI SBRM index in",
    IndexVar,
    "for",
    Query,
    "and store the results in",
    Var
]).

-define(STEP_QUERY_DEFAULT_INDEX_STORE, [
    "I query the default ECAI SBRM index for",
    Query,
    "and store the results in",
    Var
]).

-define(STEP_STORE_LAST_INGEST_RESULT_IN, [
    "I store the last ECAI SBRM ingest result in",
    Var
]).

%% ------------------------------------------------------------------
%% step/6
%% ------------------------------------------------------------------

-spec step(
    proplists:proplist(),
    map(),
    binary() | documentation,
    integer(),
    [string() | binary()],
    iodata()
) -> map().

%% -------------------------- documentation --------------------------
step(_Cfg, _Ctx, documentation, _N, ?STEP_OPEN_DISK_SEARCH_CTX, _) ->
    _ = BaseDirVar,
    _ = Var,
    "GIVEN: Create a disk search context #{base_dir := Dir, hot_tab := Tab} and store it.";
step(_Cfg, _Ctx, documentation, _N, ?STEP_NEW_INDEX_STORE, _) ->
    _ = Var,
    "GIVEN: Create a fresh ECAI SBRM index handle and store it in Var.";
step(_Cfg, _Ctx, documentation, _N, ?STEP_LOAD_INDEX_FROM_PATH_STORE, _) ->
    _ = PathVar,
    _ = Var,
    "GIVEN: Load an ECAI SBRM index from a filesystem path stored in PathVar and store handle in Var.";
step(_Cfg, _Ctx, documentation, _N, ?STEP_SET_DEFAULT_INDEX, _) ->
    _ = Var,
    "GIVEN: Set the default index handle (Context key ecai_sbrm_index) from Var.";
step(_Cfg, _Ctx, documentation, _N, ?STEP_INGEST_IPFS_JSONL_INTO_INDEX, _) ->
    _ = IpfsVar,
    _ = IndexVar,
    "WHEN: Fetch JSONL from IPFS CID in IpfsVar and ingest each JSON line as a report into the index handle in IndexVar.";
step(_Cfg, _Ctx, documentation, _N, ?STEP_INGEST_IPFS_JSONL_DEFAULT_INDEX, _) ->
    _ = IpfsVar,
    "WHEN: Fetch JSONL from IPFS CID in IpfsVar and ingest each JSON line into the default index handle (Context key ecai_sbrm_index).";
step(_Cfg, _Ctx, documentation, _N, ?STEP_QUERY_INDEX_STORE, _) ->
    _ = IndexVar,
    _ = Query,
    _ = Var,
    "WHEN: Query index handle in IndexVar with Query and store results in Var.";
step(_Cfg, _Ctx, documentation, _N, ?STEP_QUERY_DEFAULT_INDEX_STORE, _) ->
    _ = Query,
    _ = Var,
    "WHEN: Query default index handle (Context key ecai_sbrm_index) with Query and store results in Var.";
step(_Cfg, _Ctx, documentation, _N, ?STEP_STORE_LAST_INGEST_RESULT_IN, _) ->
    _ = Var,
    "THEN: Store Context key ecai_sbrm_last_ingest into Var.";
%% ---------------------------- runtime -----------------------------

step(_Cfg, Ctx0, <<"Given">>, _N, ?STEP_OPEN_DISK_SEARCH_CTX, _Body) ->
    Dir0 = get_var(Ctx0, BaseDirVar),
    case Dir0 of
        undefined ->
            Ctx0#{fail => <<"Base dir var not set">>};
        _ ->
            HotTab = ensure_hot_tab(#{}),
            DiskCtx = #{base_dir => to_list(Dir0), hot_tab => HotTab},
            Ctx0#{to_bin(Var) => DiskCtx}
    end;
%% Create new index handle
step(_Cfg, Ctx0, <<"Given">>, _N, ?STEP_NEW_INDEX_STORE, _Body) ->
    Index = new_index_handle(),
    Ctx0#{to_bin(Var) => Index};
%% Load index from disk path
step(_Cfg, Ctx0, <<"Given">>, _N, ?STEP_LOAD_INDEX_FROM_PATH_STORE, _Body) ->
    Path0 = get_var(Ctx0, PathVar),
    case Path0 of
        undefined ->
            Ctx0#{fail => <<"Index path var not set">>};
        _ ->
            Path = to_list(Path0),
            case load_index_handle(Path) of
                {ok, Index} ->
                    Ctx0#{to_bin(Var) => Index};
                {error, Why} ->
                    Ctx0#{fail => to_bin(io_lib:format("failed to load index: ~p", [Why]))}
            end
    end;
%% Set default index
step(_Cfg, Ctx0, <<"Given">>, _N, ?STEP_SET_DEFAULT_INDEX, _Body) ->
    case get_var(Ctx0, Var) of
        undefined -> Ctx0#{fail => <<"Index var not set">>};
        Index -> Ctx0#{ecai_sbrm_index => Index}
    end;
%% Ingest JSONL from IPFS into explicit index
step(_Cfg, Ctx0, <<"When">>, _N, ?STEP_INGEST_IPFS_JSONL_INTO_INDEX, _Body) ->
    Ipfs = get_var(Ctx0, IpfsVar),
    Index = get_var(Ctx0, IndexVar),
    case {Ipfs, Index} of
        {undefined, _} ->
            Ctx0#{fail => <<"IPFS hash var not set">>};
        {_, undefined} ->
            Ctx0#{fail => <<"Index var not set">>};
        _ ->
            do_ingest_ipfs_jsonl(Ctx0, Ipfs, Index)
    end;
%% Ingest JSONL from IPFS into default index
step(_Cfg, Ctx0, <<"When">>, _N, ?STEP_INGEST_IPFS_JSONL_DEFAULT_INDEX, _Body) ->
    Ipfs = get_var(Ctx0, IpfsVar),
    Index = maps:get(ecai_sbrm_index, Ctx0, undefined),
    case {Ipfs, Index} of
        {undefined, _} ->
            Ctx0#{fail => <<"IPFS hash var not set">>};
        {_, undefined} ->
            Ctx0#{fail => <<"Default index not set (use: I create a new ECAI SBRM index... )">>};
        _ ->
            do_ingest_ipfs_jsonl(Ctx0, Ipfs, Index)
    end;
%% Query explicit index
step(_Cfg, Ctx0, <<"When">>, _N, ?STEP_QUERY_INDEX_STORE, _Body) ->
    Index = get_var(Ctx0, IndexVar),
    Q0 = Query,
    case Index of
        undefined ->
            Ctx0#{fail => <<"Index var not set">>};
        _ ->
            Q = to_bin(Q0),
            case query_index(Index, Q) of
                {ok, Res} ->
                    Ctx0#{to_bin(Var) => Res, ecai_sbrm_last_query => #{q => Q, res => Res}};
                {error, Why} ->
                    Ctx0#{fail => to_bin(io_lib:format("query failed: ~p", [Why]))}
            end
    end;
%% Query default index
step(_Cfg, Ctx0, <<"When">>, _N, ?STEP_QUERY_DEFAULT_INDEX_STORE, _Body) ->
    Index = maps:get(ecai_sbrm_index, Ctx0, undefined),
    Q = to_bin(Query),
    case Index of
        undefined ->
            Ctx0#{fail => <<"Default index not set">>};
        _ ->
            case query_index(Index, Q) of
                {ok, Res} ->
                    Ctx0#{to_bin(Var) => Res, ecai_sbrm_last_query => #{q => Q, res => Res}};
                {error, Why} ->
                    Ctx0#{fail => to_bin(io_lib:format("query failed: ~p", [Why]))}
            end
    end;
%% Store last ingest
step(_Cfg, Ctx0, <<"Then">>, _N, ?STEP_STORE_LAST_INGEST_RESULT_IN, _Body) ->
    Ctx0#{to_bin(Var) => maps:get(ecai_sbrm_last_ingest, Ctx0, undefined)};
step(_Cfg, Ctx0, <<"And">>, _N, ?STEP_STORE_LAST_INGEST_RESULT_IN, _Body) ->
    Ctx0#{to_bin(Var) => maps:get(ecai_sbrm_last_ingest, Ctx0, undefined)}.

%% ------------------------------------------------------------------
%% Ingestion pipeline
%% ------------------------------------------------------------------

do_ingest_ipfs_jsonl(Ctx0, Ipfs, Index) ->
    case damage_ipfs:cat(Ipfs) of
        {ok, Bin} when is_binary(Bin) ->
            ingest_jsonl_binary(Ctx0, Bin, Index, Ipfs);
        Bin when is_binary(Bin) ->
            ingest_jsonl_binary(Ctx0, Bin, Index, Ipfs);
        Error ->
            ?LOG_ERROR("ipfs cat failed for ~p: ~p", [Ipfs, Error]),
            Ctx0#{fail => <<"ipfs cat failed">>}
    end.

ingest_jsonl_binary(Ctx0, Bin, Index, Ipfs) ->
    Lines = jsonl_lines(Bin),
    {Ok, Bad} =
        lists:foldl(
            fun(Line, {OkAcc, BadAcc}) ->
                case decode_json(Line) of
                    {ok, JsonMap} ->
                        IngestRes = ingest_report_into_index(JsonMap, Index),
                        {[#{line => Line, result => IngestRes} | OkAcc], BadAcc};
                    {error, Why} ->
                        {OkAcc, [#{line => Line, error => Why} | BadAcc]}
                end
            end,
            {[], []},
            Lines
        ),

    Summary = #{
        ipfs => to_bin(Ipfs),
        ok_lines => length(Ok),
        bad_lines => length(Bad),
        ok => lists:reverse(Ok),
        bad => lists:reverse(Bad)
    },

    RespBody = jsx:encode(#{ok => (Bad =:= []), ingest => Summary}),

    Ctx0#{
        ecai_sbrm_last_ingest => Summary,
        response_status => 200,
        response_body => RespBody
    }.

%% Accept both JSONL (\n-delimited objects) and a single JSON object/array.
jsonl_lines(Bin0) ->
    Bin = trim_bin(Bin0),
    case Bin of
        <<>> ->
            [];
        <<"[", _/binary>> ->
            %% It's a JSON array (not JSONL). We will decode the array and then
            %% encode each element back to a compact line for consistent handling.
            case decode_json(Bin) of
                {ok, L} when is_list(L) ->
                    [jsx:encode(Elem) || Elem <- L];
                _ ->
                    [Bin]
            end;
        _ ->
            %% JSONL
            Raw = binary:split(Bin, <<"\n">>, [global]),
            [trim_bin(L) || L <- Raw, trim_bin(L) =/= <<>>]
    end.

trim_bin(B) ->
    %% strip \r and surrounding whitespace
    B1 = binary:replace(B, <<"\r">>, <<>>, [global]),
    iolist_to_binary(string:trim(binary_to_list(B1))).

%% Decode JSON (jsx)
decode_json(Bin) ->
    try
        {ok, jsx:decode(Bin, [return_maps])}
    catch
        _:Err -> {error, Err}
    end.

%% Ingest one report JSON map into the index
ingest_report_into_index(JsonMap, Index) ->
    %% We piggy-back the existing ingestor which calls ecai_named_set_index:ingest/1
    %% for each fact. If your index module supports explicit handles, we try to
    %% route ingestion through it.
    Facts = ecai_sbrm_financial_statement_ingestor:ingest_report(JsonMap),
    case maybe_tag_index(Index) of
        {tagged, TaggedIndex} -> #{index => TaggedIndex, facts => Facts};
        _ -> #{facts => Facts}
    end.

%% ------------------------------------------------------------------
%% Index handle discovery (NO guards)
%% ------------------------------------------------------------------

new_index_handle() ->
    %% Prefer explicit constructor APIs if they exist.
    case erlang:function_exported(ecai_named_set_index, new, 0) of
        true ->
            ecai_named_set_index:new();
        false ->
            case erlang:function_exported(ecai_named_set_index, start_link, 0) of
                true ->
                    case ecai_named_set_index:start_link() of
                        {ok, Pid} -> Pid;
                        Other -> Other
                    end;
                false ->
                    %% fallback: opaque token (global index)
                    global
            end
    end.

load_index_handle(Path) ->
    case erlang:function_exported(ecai_named_set_index, load, 1) of
        true ->
            safe_call(fun() -> ecai_named_set_index:load(Path) end);
        false ->
            case erlang:function_exported(ecai_named_set_index, open, 1) of
                true ->
                    safe_call(fun() -> ecai_named_set_index:open(Path) end);
                false ->
                    case erlang:function_exported(ecai_named_set_index, from_file, 1) of
                        true ->
                            safe_call(fun() -> ecai_named_set_index:from_file(Path) end);
                        false ->
                            {error, {unsupported, load_index}}
                    end
            end
    end.

%% IMPORTANT:
%% Your current runtime query path for disk-backed search is:
%%   ecai_disk_search:term_postings(BaseDir, HotTab, Term)
%% so we implement query_index/2 to use that when Index is a disk context.
%%
%% Expected Index shape (BDD-friendly):
%%   #{base_dir := "/path", hot_tab := HotTab}
%% or
%%   #{base_dir := "/path"}  (we'll create a hot tab lazily if possible)

query_index(Index, QueryBin) when is_map(Index) ->
    case maps:get(base_dir, Index, undefined) of
        undefined ->
            %% Not a disk ctx; fall back to ecai_search if present.
            query_via_ecai_search(Index, QueryBin);
        BaseDir0 ->
            BaseDir = to_list(BaseDir0),
            HotTab =
                case maps:get(hot_tab, Index, undefined) of
                    undefined -> ensure_hot_tab(Index);
                    T -> T
                end,
            Term = QueryBin,
            try
                Docs = ecai_disk_search:term_postings(BaseDir, HotTab, Term),
                {ok, Docs}
            catch
                _:Err -> {error, Err}
            end
    end;
query_index(Index, QueryBin) ->
    %% Non-map: just try ecai_search fallbacks
    query_via_ecai_search(Index, QueryBin).

query_via_ecai_search(Ctx, Q) ->
    %% No guards, probe normally.
    case erlang:function_exported(ecai_search, query, 2) of
        true ->
            safe_call(fun() -> ecai_search:query(Ctx, Q) end);
        false ->
            case erlang:function_exported(ecai_search, search, 2) of
                true ->
                    safe_call(fun() -> ecai_search:search(Ctx, Q) end);
                false ->
                    case erlang:function_exported(ecai_search, find, 2) of
                        true ->
                            safe_call(fun() -> ecai_search:find(Ctx, Q) end);
                        false ->
                            case erlang:function_exported(ecai_search, query, 1) of
                                true ->
                                    safe_call(fun() -> ecai_search:query(Q) end);
                                false ->
                                    case erlang:function_exported(ecai_search, search, 1) of
                                        true -> safe_call(fun() -> ecai_search:search(Q) end);
                                        false -> {error, {unsupported, query}}
                                    end
                            end
                    end
            end
    end.

ensure_hot_tab(_Index) ->
    %% If you have a hot-terms table creator, use it; else just use 'undefined'
    %% and let ecai_hot_terms handle it (if it can).
    case erlang:function_exported(ecai_hot_terms, new, 0) of
        true ->
            ecai_hot_terms:new();
        false ->
            case erlang:function_exported(ecai_hot_terms, new, 1) of
                true -> ecai_hot_terms:new(ecai_sbrm_hot_terms);
                false -> ecai_sbrm_hot_terms
            end
    end.

maybe_tag_index(global) ->
    none;
maybe_tag_index(Index) ->
    {tagged, Index}.

safe_call(Fun) ->
    try
        {ok, Fun()}
    catch
        _:Err -> {error, Err}
    end.

%% ------------------------------------------------------------------
%% Context helpers
%% ------------------------------------------------------------------

get_var(Context, Name0) ->
    Name = to_bin(Name0),
    maps:get(Name, Context, maps:get(Name0, Context, undefined)).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(I) when is_integer(I) -> integer_to_list(I);
to_list(Other) -> io_lib:format("~p", [Other]).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).
