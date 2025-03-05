-module(ecai_chat).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("damage.hrl").

-behaviour(gen_server).

%% API
-export([
    start_link/1,
    encode_knowledge/2,
    query_subfield/2,
    get_all_mappings/0,
    store_message/4,
    get_reply/2,
    get_conversation/1,
    get_all_replies/1,
    batch_encode/1
]).

%% GenServer Callbacks
-export(
    [
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
    ]
).

%% Start the GenServer
start_link([]) -> gen_server:start_link(?MODULE, [], []).

%% Initialize state
init([]) ->
    {ok, #{}}.

encode_knowledge(Key, Data) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {encode_knowledge, {Key, Data}},
                ?DEFAULT_TIMEOUT
            )
        end
    ).
query_subfield(Key, Field) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {query_subfield, {Key, Field}},
                ?DEFAULT_TIMEOUT
            )
        end
    ).
get_all_mappings() ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                get_all_mappings,
                ?DEFAULT_TIMEOUT
            )
        end
    ).
store_message(
    SessionID, UserID, UserMessage, AIReply
) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:cast(
                Worker,
                {store_message, SessionID, UserID, UserMessage, AIReply}
            )
        end
    ).
get_reply(SessionID, UserMessage) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {get_reply, {SessionID, UserMessage}},
                ?DEFAULT_TIMEOUT
            )
        end
    ).
get_conversation(SessionID) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {get_all_conversations, {SessionID}},
                ?DEFAULT_TIMEOUT
            )
        end
    ).
get_all_replies(SessionID) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {get_all_replies, {SessionID}},
                ?DEFAULT_TIMEOUT
            )
        end
    ).
batch_encode(Messages) ->
    poolboy:transaction(
        ?MODULE,
        fun(Worker) ->
            gen_server:call(
                Worker,
                {batch_encode, {Messages}},
                ?DEFAULT_TIMEOUT
            )
        end
    ).

%% Encode a knowledge string onto the curve
handle_call({encode_knowledge, Key, Data}, _From, State) ->
    {X, Y} = ecai:hash_to_point(Data),
    NewState = maps:put(Key, {X, Y}, State),
    {reply, {ok, {X, Y}}, NewState};
%% Query subfields of an existing curve mapping
handle_call({query_subfield, Key, Field}, _From, State) ->
    case maps:find(Key, State) of
        {ok, {X, Y}} ->
            case Field of
                x -> {reply, {ok, X}, State};
                y -> {reply, {ok, Y}, State};
                full -> {reply, {ok, {X, Y}}, State};
                _ -> {reply, {error, invalid_field}, State}
            end;
        error ->
            {reply, {error, not_found}, State}
    end;
%% Get all stored mappings
handle_call(get_all_mappings, _From, State) ->
    {reply, {ok, State}, State};
%% Retrieve an AI reply from the conversation context
handle_call({get_reply, {SessionID, UserMessage}}, _From, State) ->
    case maps:find(SessionID, State) of
        {ok, Conversation} ->
            EncodedUser = ecai:hash_to_point(UserMessage),
            case lists:keyfind(EncodedUser, 3, Conversation) of
                {_, _, _, EncodedReply} -> {reply, {ok, EncodedReply}, State};
                false -> {reply, {error, no_matching_reply}, State}
            end;
        error ->
            {reply, {error, no_conversation}, State}
    end;
%% Retrieve all AI replies in a session
handle_call({get_all_replies, SessionID}, _From, State) ->
    case maps:find(SessionID, State) of
        {ok, Conversation} ->
            Replies = [Reply || {_, _, _, Reply} <- Conversation],
            {reply, {ok, Replies}, State};
        error ->
            {reply, {error, not_found}, State}
    end;
%% Batch encode multiple knowledge entries
handle_call({batch_encode, Messages}, _From, State) ->
    Encoded = ecai:batch_hash_to_point(Messages),
    {reply, {ok, Encoded}, State}.

%% Store a user message into the conversation memory
handle_cast({store_message, SessionID, UserID, UserMessage, AIReply}, State) ->
    Timestamp = erlang:system_time(millisecond),
    EncodedUser = ecai:hash_to_point(UserMessage),
    EncodedReply = ecai:hash_to_point(AIReply),
    ?LOG_DEBUG("encoded message ~p", [EncodedReply]),
    UpdatedSession =
        case maps:find(SessionID, State) of
            {ok, Conversation} ->
                [{UserID, Timestamp, EncodedUser, EncodedReply} | Conversation];
            error ->
                [{UserID, Timestamp, EncodedUser, EncodedReply}]
        end,
    NewState = maps:put(SessionID, UpdatedSession, State),
    ?LOG_DEBUG("stored message ~p", [NewState]),
    {noreply, NewState}.

handle_info(Info, State) ->
    ?LOG_DEBUG("ecai_chat handle_info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
