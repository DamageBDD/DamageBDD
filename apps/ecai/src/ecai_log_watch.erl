%%--------------------------------------------------------------------
%% ecai_log_watch.erl
%%
%% Watches one or more log files, chunks lines into events, indexes them
%% into ECAI, retrieves similar prior events, then asks Ollama to explain.
%%
%% Intended flow:
%%   file tail -> normalize -> fingerprint -> ECAI index -> similarity retrieval
%%   -> Ollama prompt with deterministic evidence only
%%--------------------------------------------------------------------
-module(ecai_log_watch).

-behaviour(gen_server).

-export([
    start_link/1,
    stop/1,
    watch_file/2,
    unwatch_file/2,
    analyze_now/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/file.hrl").

-record(state, {
    base_dir,
    poll_ms = 1000,
    %% #{Path => #{offset => non_neg_integer(), inode => term()}}
    files = #{},
    model = <<"DamageSales">>,
    top_k = 8
}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

stop(Pid) ->
    gen_server:call(Pid, stop).

watch_file(Pid, Path) ->
    gen_server:call(Pid, {watch_file, Path}).

unwatch_file(Pid, Path) ->
    gen_server:call(Pid, {unwatch_file, Path}).

analyze_now(Pid, Text) ->
    gen_server:call(Pid, {analyze_now, Text}, 60000).

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    BaseDir = maps:get(base_dir, Opts),
    PollMs = maps:get(poll_ms, Opts, 1000),
    Model = maps:get(model, Opts, <<"DamageSales">>),
    TopK = maps:get(top_k, Opts, 8),
    Files0 = maps:get(files, Opts, []),

    Files =
        lists:foldl(
            fun(Path, Acc) ->
                case file:read_file_info(Path) of
                    {ok, FI} ->
                        Acc#{
                            Path => #{
                                offset => FI#file_info.size,
                                inode => file_identity(FI)
                            }
                        };
                    _ ->
                        Acc
                end
            end,
            #{},
            Files0
        ),

    erlang:send_after(PollMs, self(), poll),
    {ok, #state{
        base_dir = BaseDir,
        poll_ms = PollMs,
        files = Files,
        model = Model,
        top_k = TopK
    }}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call({watch_file, Path}, _From, State = #state{files = Files}) ->
    Reply =
        case file:read_file_info(Path) of
            {ok, _FI} ->
                ok;
            Error ->
                Error
        end,
    NewFiles =
        case Reply of
            ok ->
                {ok, FI2} = file:read_file_info(Path),
                Files#{
                    Path => #{
                        offset => FI2#file_info.size,
                        inode => file_identity(FI2)
                    }
                };
            _ ->
                Files
        end,
    {reply, Reply, State#state{files = NewFiles}};
handle_call({unwatch_file, Path}, _From, State = #state{files = Files}) ->
    {reply, ok, State#state{files = maps:remove(Path, Files)}};
handle_call({analyze_now, Text0}, _From, State) ->
    Text = to_bin(Text0),
    Reply = analyze_event(Text, manual, State),
    {reply, Reply, State};
handle_call(_Msg, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(poll, State0 = #state{poll_ms = PollMs}) ->
    State1 = poll_files(State0),
    erlang:send_after(PollMs, self(), poll),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Polling / file reading
%%%===================================================================

poll_files(State = #state{files = Files}) ->
    NewFiles =
        maps:fold(
            fun(Path, Meta, Acc) ->
                case poll_one_file(Path, Meta, State) of
                    {ok, Meta1} ->
                        Acc#{Path => Meta1};
                    {remove, _Reason} ->
                        maps:remove(Path, Acc);
                    {error, Reason} ->
                        ?LOG_WARNING("ecai_log_watch poll failed path=~p reason=~p", [Path, Reason]),
                        Acc
                end
            end,
            Files,
            Files
        ),
    State#state{files = NewFiles}.

poll_one_file(Path, _Meta = #{offset := Offset, inode := Inode0}, State) ->
    case file:read_file_info(Path) of
        {ok, FI} ->
            Inode1 = file_identity(FI),
            Size = FI#file_info.size,
            case rotation_state(Inode0, Inode1, Offset, Size) of
                rotated ->
                    read_from(Path, 0, State);
                truncated ->
                    read_from(Path, 0, State);
                same ->
                    read_from(Path, Offset, State)
            end;
        {error, enoent} ->
            {remove, enoent};
        Error ->
            {error, Error}
    end.

rotation_state(Inode, Inode, Offset, Size) when Size < Offset ->
    truncated;
rotation_state(Inode, Inode, _Offset, _Size) ->
    same;
rotation_state(_Old, _New, _Offset, _Size) ->
    rotated.

read_from(Path, Offset, State) ->
    case file:open(Path, [read, binary, raw]) of
        {ok, FD} ->
            _ = file:position(FD, Offset),
            case slurp_new(FD, []) of
                {ok, Bin} ->
                    ok = file:close(FD),
                    NewOffset = Offset + byte_size(Bin),
                    process_new_bytes(Path, Bin, State),
                    case file:read_file_info(Path) of
                        {ok, FI} ->
                            {ok, #{
                                offset => NewOffset,
                                inode => file_identity(FI)
                            }};
                        _ ->
                            {ok, #{offset => NewOffset, inode => undefined}}
                    end;
                Error ->
                    ok = file:close(FD),
                    {error, Error}
            end;
        Error ->
            {error, Error}
    end.

slurp_new(FD, Acc) ->
    case file:read(FD, 65536) of
        eof ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {ok, Bin} ->
            slurp_new(FD, [Bin | Acc]);
        Error ->
            Error
    end.

process_new_bytes(_Path, <<>>, _State) ->
    ok;
process_new_bytes(Path, Bin, State) ->
    Lines0 = binary:split(Bin, <<"\n">>, [global]),
    Lines = [L || L <- Lines0, L =/= <<>>],
    lists:foreach(
        fun(Line) ->
            Event = enrich_line(Path, Line),
            _ = maybe_index_event(Event, State),
            case should_analyze(Event) of
                true ->
                    _ = analyze_event(maps:get(text, Event), Path, State),
                    ok;
                false ->
                    ok
            end
        end,
        Lines
    ).

%%%===================================================================
%%% Event shaping / indexing
%%%===================================================================

enrich_line(Path, Line0) ->
    Line = binary:replace(Line0, <<"\r">>, <<>>, [global]),
    Norm = normalize_log(Line),
    #{
        path => to_bin(Path),
        ts => system_time_bin(),
        text => Line,
        norm => Norm,
        level => detect_level(Norm),
        fingerprint => fingerprint(Norm)
    }.

normalize_log(Bin) ->
    B1 = re:replace(Bin, <<"\\b[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.+-Z]+\\b">>, <<" <TS> ">>, [
        global, {return, binary}
    ]),
    B2 = re:replace(B1, <<"\\b[0-9]+\\b">>, <<" <NUM> ">>, [global, {return, binary}]),
    B3 = re:replace(B2, <<"(0x[0-9a-fA-F]+)">>, <<" <HEX> ">>, [global, {return, binary}]),
    binary:lowercase(B3).

detect_level(Bin) ->
    case has(Bin, <<"fatal">>) orelse has(Bin, <<"panic">>) of
        true ->
            fatal;
        false ->
            case has(Bin, <<"error">>) of
                true ->
                    error;
                false ->
                    case has(Bin, <<"warn">>) orelse has(Bin, <<"timeout">>) of
                        true ->
                            warning;
                        false ->
                            case has(Bin, <<"fail">>) of
                                true -> error;
                                false -> info
                            end
                    end
            end
    end.

has(Bin, Needle) ->
    binary:match(binary:lowercase(Bin), binary:lowercase(Needle)) =/= nomatch.
fingerprint(Bin) ->
    crypto:hash(sha256, Bin).

should_analyze(#{level := fatal}) ->
    true;
should_analyze(#{level := error}) ->
    true;
should_analyze(#{level := warning, text := T}) ->
    binary:match(T, <<"exception">>) =/= nomatch orelse
        binary:match(T, <<"crash">>) =/= nomatch orelse
        binary:match(T, <<"refused">>) =/= nomatch;
should_analyze(_) ->
    false.

maybe_index_event(Event, _State = #state{base_dir = BaseDir}) ->
    %% Hook point:
    %% Convert each log event into an indexable document/chunk for your ECAI store.
    %%
    %% For now we assume a helper exists:
    %%   ecai_log_index:add_doc(BaseDir, MetaMap)
    %%
    %% Meta should preserve both raw text and normalized text.
    Meta = #{
        cid => maps:get(fingerprint, Event),
        title => <<"log_event">>,
        heading => atom_to_binary(maps:get(level, Event)),
        text => maps:get(text, Event),
        norm => maps:get(norm, Event),
        path => maps:get(path, Event),
        ts => maps:get(ts, Event)
    },
    case catch ecai_log_index:add_doc(BaseDir, Meta) of
        ok -> ok;
        {'EXIT', _} -> ok;
        _ -> ok
    end.

%%%===================================================================
%%% Analysis
%%%===================================================================

analyze_event(Text, Source, _State = #state{base_dir = BaseDir, top_k = TopK, model = Model}) ->
    Query = normalize_log(Text),
    Sources = retrieve_log_sources(BaseDir, Query, TopK),
    Prompt = build_log_prompt(Text, Source, Sources),
    ollama_generate(Model, Prompt, log_system_prompt()).

retrieve_log_sources(BaseDir, QueryBin, K) ->
    %% Uses your same ECAI retrieval style.
    %%
    %% If you already index logs into ecai_disk_docstore, this works naturally.
    %% Otherwise swap this call out for a log-specific retriever.
    try
        ecai_ollama_rag:retrieve_sources(BaseDir, QueryBin, K)
    catch
        _:_ -> []
    end.

build_log_prompt(Text, Source, Sources) ->
    SrcTxt =
        lists:flatten(
            [
                io_lib:format(
                    "[S~p] doc=~p title=~s heading=~s path=~s~nts=~s~n~s~n~n",
                    [
                        I,
                        maps:get(docint, S, 0),
                        maps:get(title, S, <<>>),
                        maps:get(heading, S, <<>>),
                        maps:get(path, S, <<>>),
                        maps:get(ts, S, <<>>),
                        maps:get(text, S, <<>>)
                    ]
                )
             || {I, S} <- lists:zip(lists:seq(1, length(Sources)), Sources)
            ]
        ),
    list_to_binary(
        io_lib:format(
            "CURRENT LOG EVENT (source=~p):~n~s~n~nRETRIEVED RELATED EVENTS:~n~s",
            [Source, Text, SrcTxt]
        )
    ).

log_system_prompt() ->
    <<
        "You are an application incident analyst.\n"
        "Rules:\n"
        "- Use the CURRENT LOG EVENT and RETRIEVED RELATED EVENTS only.\n"
        "- Do not invent causes not supported by evidence.\n"
        "- Output four sections exactly:\n"
        "  1. Classification\n"
        "  2. Likely Cause\n"
        "  3. Evidence\n"
        "  4. Immediate Action\n"
        "- Cite retrieved evidence as [S1], [S2], etc.\n"
        "- If evidence is insufficient, say so explicitly.\n"
        "- Prefer deterministic patterns over speculation.\n"
    >>.

ollama_generate(Model, Prompt, System) ->
    Host = "localhost",
    Port = 11434,
    {ok, ConnPid} = gun:open(Host, Port),
    {ok, _} = gun:await_up(ConnPid),

    Body =
        jsx:encode(#{
            <<"model">> => Model,
            <<"system">> => System,
            <<"prompt">> => Prompt,
            <<"stream">> => true
        }),

    Ref = gun:post(
        ConnPid,
        "/api/generate",
        [{<<"content-type">>, <<"application/json">>}],
        Body
    ),

    Res = recv_answer(ConnPid, Ref, <<>>, []),
    gun:close(ConnPid),

    case Res of
        {ok, Reply} ->
            ?LOG_WARNING("ECAI LOG ANALYSIS~n~s", [Reply]),
            {ok, Reply};
        Error ->
            Error
    end.

recv_answer(ConnPid, Ref, Buf, Acc) ->
    receive
        {gun_response, ConnPid, Ref, nofin, 200, _Headers} ->
            recv_body(ConnPid, Ref, Buf, Acc);
        {gun_response, ConnPid, Ref, fin, Status, _Headers} ->
            {error, {http_status, Status}}
    after 30000 ->
        {error, timeout_headers}
    end.

recv_body(ConnPid, Ref, Buf, Acc) ->
    receive
        {gun_data, ConnPid, Ref, fin, Data} ->
            parse_jsonl_finish(<<Buf/binary, Data/binary>>, Acc);
        {gun_data, ConnPid, Ref, nofin, Data} ->
            {Buf1, Acc1, Done} = parse_jsonl_stream(<<Buf/binary, Data/binary>>, Acc),
            case Done of
                true -> {ok, iolist_to_binary(lists:reverse(Acc1))};
                false -> recv_body(ConnPid, Ref, Buf1, Acc1)
            end
    after 30000 ->
        {error, timeout_body}
    end.

parse_jsonl_finish(Bin, Acc) ->
    {_Buf, Acc1, _Done} = parse_jsonl_stream(Bin, Acc),
    {ok, iolist_to_binary(lists:reverse(Acc1))}.

parse_jsonl_stream(Bin, Acc) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    case Lines of
        [] ->
            {<<>>, Acc, false};
        _ ->
            Remainder = lists:last(Lines),
            FullLines = lists:sublist(Lines, length(Lines) - 1),
            {Acc2, Done} =
                lists:foldl(
                    fun(Line, {A, D}) ->
                        case {Line, D} of
                            {<<>>, _} ->
                                {A, D};
                            {_, true} ->
                                {A, true};
                            _ ->
                                case safe_decode(Line) of
                                    {ok, M} ->
                                        Chunk = maps:get(<<"response">>, M, <<"">>),
                                        D1 = maps:get(<<"done">>, M, false),
                                        {[Chunk | A], D1 orelse D};
                                    _ ->
                                        {A, D}
                                end
                        end
                    end,
                    {Acc, false},
                    FullLines
                ),
            {Remainder, Acc2, Done}
    end.

safe_decode(Line) ->
    try
        {ok, jsx:decode(Line, [return_maps])}
    catch
        _:_ -> {error, badjson}
    end.

file_identity(FI) ->
    {FI#file_info.inode, FI#file_info.major_device, FI#file_info.minor_device}.

system_time_bin() ->
    integer_to_binary(erlang:system_time(millisecond)).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(I) when is_integer(I) -> integer_to_binary(I).
