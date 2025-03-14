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
    store_message/4,
    get_reply/2
]).

%% GenServer Callbacks
-export(
    [
        init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3,
        test/0
    ]
).

%% Start the GenServer
start_link([]) -> gen_server:start_link(?MODULE, [], []).

%% Initialize state
init([]) ->
    {ok, #{}}.

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

handle_call({get_reply, {_SessionID, Query}}, _From, State) ->
    Reply = ecai:infer_knowledge(Query),
        {reply, Reply, State}.

%% Store a user message into the conversation memory
handle_cast({store_message, _SessionID, _UserID, UserMessage, AIReply}, State) ->
    ok = ecai:store_knowledge(UserMessage, AIReply),
    ?LOG_DEBUG("stored encoded message ~p", [AIReply]),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG_DEBUG("ecai_chat handle_info ~p", [Info]),
    {noreply, State}.

terminate(Reason, _State) ->
    logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

test() ->
    ecai_chat:store_message("test", "user", "hello ecai", "Hi"),
    ecai_chat:get_reply("test", "hello ecai").
