-module(ecai_chat).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

%% API
-export([
    store_message/4,
    get_reply/2,
    get_reply/3
]).

-export([find_nearest/3]).
%% GenServer Callbacks
-export(
    [
        init/1,
        start_link/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3,
        test/0
    ]
).
-define(KNOWLEDGE_POINTS_TABLE, ecai_knowledge).
-define(KNOWLEDGE_EDGES_TABLE, ecai_knowledge_edges).
-define(DEFAULT_TIMEOUT, 60000).

%% Start the GenServer
start_link([]) -> gen_server:start_link(?MODULE, [], []).

%% Initialize state
init([]) ->
    Points = ets:new(?KNOWLEDGE_POINTS_TABLE, [bag]),
    Edges = ets:new(?KNOWLEDGE_EDGES_TABLE, [named_table, set, public]),
    {ok, #{points => Points, edges => Edges}}.

store_message(
    SessionID, UserID, UserMessage, AIReply
) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:cast(
                Worker,
                {store, SessionID, UserID, UserMessage, AIReply}
            )
        end
    ).
get_reply(SessionID, UserMessage) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {infer, SessionID, undefined, UserMessage},
                ?DEFAULT_TIMEOUT
            )
        end
    ).
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

handle_call(
    {store, _SessionID, _UserId, Question, Answer},
    _From,
    #{points := Points, edges := Edges} = State
) ->
    % hash and store the question
    QuestionPoint = ecai:hash_to_curve(Question),
    {ok, {QX, QY} = QuestionHash} = damage_ipfs:add({data, Question}),
    true = ets:insert(Points, {QuestionPoint, QuestionHash}),

    % hash and store the answer
    AnswerPoint = ecai:hash_to_curve(Answer),
    {ok, {AX, AY} = AnswerHash} = damage_ipfs:add({data, Answer}),
    true = ets:insert(Points, {AnswerPoint, AnswerHash}),

    % generate derived point
    DerivedPoint = ecai:curve_add(QX, QY, AX, AY),

    % hash and store the relationship
    true = ets:insert(Edges, {QuestionPoint, "question-answer", [AnswerPoint, DerivedPoint]}),
    true = ets:insert(Edges, {AnswerPoint, "answer-question", [QuestionPoint, DerivedPoint]}),
    true = ets:insert(Edges, {DerivedPoint, "semantic-link", [QuestionPoint, AnswerPoint]}),

    {reply, ok, State};
handle_call(
    {infer, _SessionID, _UserId, Query}, _From, #{points := Points, edges := _Edges} = State
) ->
    QueryPoint = ecai:hash_to_curve(Query),
    Response = find_nearest(Points, QueryPoint),
    {reply, Response, State}.

handle_info(Info, State) ->
    ?LOG_DEBUG("ecai_chat handle_info ~p", [Info]),
    {noreply, State}.
handle_cast(_, State) -> {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

find_nearest(Table, {X0, Y0}) ->
    find_nearest(Table, {X0, Y0}, 1).
find_nearest(Table, {X0, Y0}, K) ->
    ets:foldl(
        fun({{X, Y} = XY, _Hash}, Acc) ->
            Dist = euclidean_dist_sq({X, Y}, {X0, Y0}),
            update_nearest(K, {XY, Dist}, Acc)
        end,
        [],
        Table
    ).

update_nearest(K, {XY, Dist}, Nearest) ->
    Sorted = lists:sort(fun({_, D1}, {_, D2}) -> D1 =< D2 end, [{XY, Dist} | Nearest]),
    lists:sublist(Sorted, K).

euclidean_dist_sq({X1, Y1}, {X2, Y2}) ->
    (X2 - X1) * (X2 - X1) + (Y2 - Y1) * (Y2 - Y1).

spell_correct(Text) ->
    case sheldon:check(Text) of
        ok ->
            Text;
        #{
            bazinga := Bazinga,
            misspelled_words := Misspelled
        } ->
            ?LOG_DEBUG("bazinga ~p", Bazinga),
            ?LOG_DEBUG("Spell correction ~p", Misspelled)
        %[#{candidates => ["misspeed","misspelled"],
        %line_number => 1,
        %word => "misspeled"}]}
    end.

test() ->
    ecai_chat:store_message(sessionid, userid, "hello steven", "Hi ecai"),
    ecai_chat:store_message(sessionid, userid, "hello blah", "Hi hi"),
    spell_correct("helo crul wlrd"),
    "Hi" = ecai_chat:get_reply(sessionid, userid, "hello ecai"),
    "Hi ecai" = ecai_chat:get_reply(sessionid, userid, "hello steve jose").
