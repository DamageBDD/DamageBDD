-module(ecai_chat).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

%% API
-export([
    start_link/1,
    store_message/4,
    get_reply/2,
    get_reply/3,
    find_nearest/3,
    test/0
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(KNOWLEDGE_POINTS_TABLE, ecai_knowledge_points).
-define(KNOWLEDGE_MESSAGES_TABLE, ecai_knowledge_messages).
-define(KNOWLEDGE_EDGES_TABLE, ecai_knowledge_edges).
-define(DEFAULT_TIMEOUT, 60000).

-define(DEFAULT_OLLAMA_HOST, "localhost").
-define(DEFAULT_OLLAMA_PORT, 11434).
-define(DEFAULT_OLLAMA_MODEL, <<"DamageSales">>).
-define(DEFAULT_TOP_K, 5).

-record(state, {
    points,
    messages,
    edges,
    ollama_host = ?DEFAULT_OLLAMA_HOST,
    ollama_port = ?DEFAULT_OLLAMA_PORT,
    ollama_model = ?DEFAULT_OLLAMA_MODEL,
    top_k = ?DEFAULT_TOP_K,
    system_prompt = default_system_prompt()
}).

%%====================================================================
%% API
%%====================================================================

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

store_message(SessionID, UserID, UserMessage, AIReply) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {store, SessionID, UserID, UserMessage, AIReply},
                ?DEFAULT_TIMEOUT
            )
        end
    ).

get_reply(SessionID, UserMessage) ->
    get_reply(SessionID, undefined, UserMessage).

get_reply(SessionID, UserID, UserMessage) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {infer, SessionID, UserID, UserMessage},
                ?DEFAULT_TIMEOUT
            )
        end
    ).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Opts) ->
    Points =
        ets:new(?KNOWLEDGE_POINTS_TABLE, [
            named_table,
            public,
            set,
            {read_concurrency, true},
            {write_concurrency, true}
        ]),
    Messages =
        ets:new(?KNOWLEDGE_MESSAGES_TABLE, [
            named_table,
            public,
            set,
            {read_concurrency, true},
            {write_concurrency, true}
        ]),
    Edges =
        ets:new(?KNOWLEDGE_EDGES_TABLE, [
            named_table,
            public,
            bag,
            {read_concurrency, true},
            {write_concurrency, true}
        ]),

    Host = proplists:get_value(ollama_host, Opts, ?DEFAULT_OLLAMA_HOST),
    Port = proplists:get_value(ollama_port, Opts, ?DEFAULT_OLLAMA_PORT),
    Model = to_bin(proplists:get_value(ollama_model, Opts, ?DEFAULT_OLLAMA_MODEL)),
    TopK = proplists:get_value(top_k, Opts, ?DEFAULT_TOP_K),
    SystemPrompt = to_bin(proplists:get_value(system_prompt, Opts, default_system_prompt())),

    {ok, #state{
        points = Points,
        messages = Messages,
        edges = Edges,
        ollama_host = Host,
        ollama_port = Port,
        ollama_model = Model,
        top_k = TopK,
        system_prompt = SystemPrompt
    }}.

handle_call(
    {store, SessionID, UserID, Question0, Answer0},
    _From,
    State = #state{points = Points, messages = Messages, edges = Edges}
) ->
    Question = normalize_text(Question0),
    Answer = normalize_text(Answer0),

    MessageID = erlang:unique_integer([monotonic, positive]),
    QuestionPoint = text_to_point(Question),
    AnswerPoint = text_to_point(Answer),

    {QuestionCID, AnswerCID} = maybe_store_ipfs(Question, Answer),

    Meta = #{
        id => MessageID,
        session_id => SessionID,
        user_id => UserID,
        question => Question,
        answer => Answer,
        question_point => QuestionPoint,
        answer_point => AnswerPoint,
        question_cid => QuestionCID,
        answer_cid => AnswerCID,
        inserted_at => erlang:system_time(second)
    },

    true = ets:insert(Messages, {MessageID, Meta}),
    true = ets:insert(Points, {QuestionPoint, {question, MessageID}}),
    true = ets:insert(Points, {AnswerPoint, {answer, MessageID}}),

    true = ets:insert(Edges, {QuestionPoint, asks, AnswerPoint}),
    true = ets:insert(Edges, {AnswerPoint, answers, QuestionPoint}),
    true = ets:insert(Edges, {QuestionPoint, message_id, MessageID}),
    true = ets:insert(Edges, {AnswerPoint, message_id, MessageID}),

    {reply, {ok, MessageID}, State};
handle_call(
    {infer, SessionID, UserID, Query0},
    _From,
    State = #state{
        points = Points,
        messages = Messages,
        ollama_host = Host,
        ollama_port = Port,
        ollama_model = Model,
        top_k = TopK,
        system_prompt = SystemPrompt
    }
) ->
    Query = normalize_text(Query0),
    QueryPoint = text_to_point(Query),

    %% -------------------------
    %% 1. CHAT MEMORY RETRIEVAL
    %% -------------------------
    Nearest = find_nearest(Points, QueryPoint, TopK),
    ChatContext = resolve_context(Messages, Nearest, SessionID, UserID),

    %% -------------------------
    %% 2. DISK + IPFS RETRIEVAL
    %% -------------------------
    %% Uses your new disk index + docstore
    DiskContext =
        case catch ecai_ollama_rag:retrieve_sources("ecai_index", Query, TopK) of
            Sources when is_list(Sources) -> Sources;
            _ -> []
        end,

    %% -------------------------
    %% 3. MERGE CONTEXTS
    %% -------------------------
    Context = merge_contexts(ChatContext, DiskContext),

    %% -------------------------
    %% 4. DIRECT MATCH FAST PATH
    %% -------------------------
    case maybe_direct_answer(Context) of
        {ok, Answer} ->
            {reply, {ok, Answer}, State};
        not_found ->
            %% -------------------------
            %% 5. BUILD RAG PROMPT
            %% -------------------------
            Prompt = build_rag_prompt_full(SessionID, UserID, Query, Context),

            %% -------------------------
            %% 6. OLLAMA CALL
            %% -------------------------
            Reply =
                call_ollama(
                    Host,
                    Port,
                    Model,
                    SystemPrompt,
                    Prompt
                ),

            case Reply of
                {ok, AIReply} ->
                    _ = maybe_self_store(SessionID, UserID, Query, AIReply, State),
                    {reply, {ok, AIReply}, State};
                {error, _} = Err ->
                    {reply, Err, State}
            end
    end;
handle_call(Request, _From, State) ->
    ?LOG_WARNING("Unhandled call ~p", [Request]),
    {reply, {error, unhandled_call}, State}.

handle_cast(Msg, State) ->
    ?LOG_DEBUG("Ignoring cast ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG_DEBUG("ecai_chat handle_info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Retrieval
%%====================================================================

find_nearest(Table, {X0, Y0}, K) ->
    ets:foldl(
        fun({{X, Y} = XY, Ref}, Acc) ->
            Dist = euclidean_dist_sq({X, Y}, {X0, Y0}),
            update_nearest(K, {XY, Ref, Dist}, Acc)
        end,
        [],
        Table
    ).

resolve_context(MessagesTab, Nearest, SessionID, UserID) ->
    Raw =
        lists:foldl(
            fun({_Point, {_Type, MessageID}, _Dist}, Acc) ->
                case ets:lookup(MessagesTab, MessageID) of
                    [{_, Meta}] -> [Meta | Acc];
                    [] -> Acc
                end
            end,
            [],
            Nearest
        ),
    Deduped = dedupe_by_id(Raw),
    prefer_session_user(Deduped, SessionID, UserID).

maybe_direct_answer(Context) ->
    case Context of
        [#{type := chat, question := Q, answer := A} | _] ->
            case fuzzy_match(Q, Context) of
                true -> {ok, A};
                false -> not_found
            end;
        _ ->
            not_found
    end.

fuzzy_match(Q, Context) ->
    %% simple heuristic (can upgrade later)
    lists:any(
        fun(#{type := chat, question := Q2}) ->
            similarity(Q, Q2) > 0.9
        end,
        Context
    ).

similarity(A, B) ->
    %% placeholder – replace with token overlap later
    if
        A =:= B -> 1.0;
        true -> 0.0
    end.

prefer_session_user(Messages, SessionID, UserID) ->
    SessionMatches =
        [
            M
         || M <- Messages,
            maps:get(session_id, M, undefined) =:= SessionID orelse SessionID =:= undefined
        ],
    UserMatches =
        [
            M
         || M <- SessionMatches,
            UserID =:= undefined orelse maps:get(user_id, M, undefined) =:= UserID
        ],
    case UserMatches of
        [] -> lists:sublist(Messages, ?DEFAULT_TOP_K);
        _ -> lists:sublist(UserMatches, ?DEFAULT_TOP_K)
    end.

dedupe_by_id(Messages) ->
    lists:reverse(
        maps:values(
            lists:foldl(
                fun(M, Acc) ->
                    ID = maps:get(id, M),
                    maps:put(ID, M, Acc)
                end,
                #{},
                Messages
            )
        )
    ).

update_nearest(K, Entry = {_XY, _Ref, _Dist}, Nearest) ->
    Sorted =
        lists:sort(
            fun({_, _, D1}, {_, _, D2}) -> D1 =< D2 end,
            [Entry | Nearest]
        ),
    lists:sublist(Sorted, K).

euclidean_dist_sq({X1, Y1}, {X2, Y2}) ->
    DX = X2 - X1,
    DY = Y2 - Y1,
    DX * DX + DY * DY.

%%====================================================================
%% Prompt building
%%====================================================================

build_rag_prompt_full(SessionID, UserID, Query, Context) ->
    Sources =
        lists:flatten(
            lists:map(
                fun({Idx, Item}) ->
                    case maps:get(type, Item) of
                        chat ->
                            io_lib:format(
                                "[S~p][CHAT]\nQ: ~s\nA: ~s\n\n",
                                [
                                    Idx,
                                    maps:get(question, Item, <<>>),
                                    maps:get(answer, Item, <<>>)
                                ]
                            );
                        doc ->
                            io_lib:format(
                                "[S~p][DOC cid=~s]\n~s\n\n",
                                [
                                    Idx,
                                    maps:get(cid, Item, <<>>),
                                    maps:get(text, Item, <<>>)
                                ]
                            )
                    end
                end,
                lists:zip(lists:seq(1, length(Context)), Context)
            )
        ),

    list_to_binary(
        io_lib:format(
            "SESSION: ~p USER: ~p\n\n"
            "RULES:\n"
            "- Only use SOURCES\n"
            "- If missing say: Not in sources\n"
            "- Cite like [S1]\n"
            "- If BDD requested output valid Gherkin only\n\n"
            "SOURCES:\n~s\n"
            "QUESTION:\n~s\n",
            [SessionID, UserID, Sources, Query]
        )
    ).

default_system_prompt() ->
    <<
        "You are an ECAI-backed assistant for DamageBDD.\n"
        "Rules:\n"
        "- Prefer grounded answers from retrieved source messages.\n"
        "- Be concise, concrete, and technically accurate.\n"
        "- If the user asks for BDD or Gherkin, output valid Gherkin only.\n"
        "- If the sources are weak or missing, say what is missing instead of inventing facts.\n"
    >>.

%%====================================================================
%% Ollama
%%====================================================================

%%====================================================================
%% Ollama
%%====================================================================

call_ollama(Host, Port, Model, SystemPrompt, Prompt) ->
    Body =
        jsx:encode(#{
            <<"model">> => Model,
            <<"system">> => SystemPrompt,
            <<"prompt">> => Prompt,
            %% Let Ollama return one JSON object.
            %% damage_gun already waits for the full body.
            <<"stream">> => false
        }),

    case
        damage_gun:post(
            Host,
            Port,
            "/api/generate",
            [{<<"content-type">>, <<"application/json">>}],
            Body,
            #{
                timeout => ?DEFAULT_TIMEOUT,
                connect_timeout => 5000,
                decode => json,
                proxy => direct,
                transport => tcp
            }
        )
    of
        {ok, #{status := Status, json := Json, body := RawBody}} when
            Status >= 200, Status < 300
        ->
            decode_ollama_generate(Json, RawBody);
        {ok, #{status := Status, json := Json, body := RawBody}} ->
            {error, {ollama_http_status, Status, ollama_error(Json, RawBody)}};
        {ok, #{status := Status, body := RawBody}} ->
            {error, {ollama_http_status, Status, RawBody}};
        {error, Reason} ->
            {error, {ollama_request_failed, Reason}}
    end.

decode_ollama_generate(Json, RawBody) when is_map(Json) ->
    case maps:get(response, Json, undefined) of
        Reply when is_binary(Reply) ->
            {ok, Reply};
        undefined ->
            %% damage_gun decodes with atom labels, but keep binary-label fallback.
            case maps:get(<<"response">>, Json, undefined) of
                Reply when is_binary(Reply) ->
                    {ok, Reply};
                _ ->
                    {error, {ollama_missing_response, Json, RawBody}}
            end;
        Other ->
            {error, {ollama_bad_response_field, Other, Json}}
    end;
decode_ollama_generate(Json, RawBody) ->
    {error, {ollama_bad_json, Json, RawBody}}.

ollama_error(Json, RawBody) when is_map(Json) ->
    case maps:get(error, Json, undefined) of
        undefined ->
            maps:get(<<"error">>, Json, RawBody);
        Err ->
            Err
    end;
ollama_error(_Json, RawBody) ->
    RawBody.

%%====================================================================
%% Utilities
%%====================================================================

normalize_text(Text) when is_binary(Text) ->
    binary:replace(Text, <<"\r\n">>, <<"\n">>, [global]);
normalize_text(Text) when is_list(Text) ->
    normalize_text(list_to_binary(Text));
normalize_text(Other) ->
    to_bin(io_lib:format("~p", [Other])).

text_to_point(Text0) ->
    Text = normalize_text(Text0),
    case ecai:hash_to_curve_point(Text) of
        #{x := X, y := Y} when is_integer(X), is_integer(Y) ->
            {X, Y};
        Other ->
            erlang:error({bad_ecai_point, Other})
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> list_to_binary(io_lib:format("~p", [Other])).

maybe_store_ipfs(Question, Answer) ->
    QCID =
        case catch damage_ipfs:add({data, Question}) of
            {ok, CID} -> CID;
            _ -> undefined
        end,
    ACID =
        case catch damage_ipfs:add({data, Answer}) of
            {ok, CID0} -> CID0;
            _ -> undefined
        end,
    {QCID, ACID}.

maybe_self_store(SessionID, UserID, Query, AIReply, State) ->
    case AIReply of
        <<>> ->
            ok;
        _ ->
            _ = handle_call({store, SessionID, UserID, Query, AIReply}, self(), State),
            ok
    end.
merge_contexts(Chat, Disk) ->
    %% Normalize both to same shape
    ChatNorm =
        [
            #{
                type => chat,
                question => maps:get(question, M, <<>>),
                answer => maps:get(answer, M, <<>>)
            }
         || M <- Chat
        ],

    DiskNorm =
        [
            #{
                type => doc,
                cid => maps:get(cid, M, <<>>),
                text => maps:get(text, M, <<>>)
            }
         || M <- Disk
        ],

    ChatNorm ++ DiskNorm.

%%====================================================================
%% Tests
%%====================================================================

test() ->
    {ok, Pid} = ecai_chat:start_link([{top_k, 3}]),
    unlink(Pid),

    {ok, _} = ecai_chat:store_message(sessionid, userid, <<"hello steven">>, <<"Hi ecai">>),
    {ok, _} = ecai_chat:store_message(
        sessionid,
        userid,
        <<"what is damagebdd">>,
        <<"DamageBDD is behaviour verification infrastructure.">>
    ),

    %% This depends on nearest retrieval and optionally Ollama fallback.
    Reply = ecai_chat:get_reply(sessionid, userid, <<"what is damagebdd">>),
    ?assertMatch({ok, _}, Reply),

    ok.
