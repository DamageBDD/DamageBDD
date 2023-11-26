%generate an erlang genserver module that pools connections to each member in a riak cluster, expose the riak crud functions through public interfaces
-module(damage_riak).

-behaviour(gen_server).
-behaviour(poolboy_worker).

-export(
  [
    start_link/1,
    get_connection/0,
    get/2,
    put/3,
    put/4,
    delete/2,
    list_keys/1,
    get_index/3,
    get_index_range/4
  ]
).
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
-export([find_active_connection/4]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {connections = []}).

% Define the function find_active_connection
find_active_connection(Connections, Bucket, Fun, Args) ->
  find_active_connection_helper(Connections, Bucket, Fun, Args).

% Helper function to iterate through the connections
find_active_connection_helper([Connection | Rest], Bucket, Fun, Args) ->
  case apply(riakc_pb_socket, Fun, [Connection, Bucket] ++ Args) of
    {ok, Results} -> Results;

    Err ->
      logger:error("Unexpected riak error ~p trying next", [Err]),
      find_active_connection_helper(Rest, Bucket, Fun, Args)
  end;

find_active_connection_helper([], _, _, _) ->
  logger:error("Unexpected riak error not trying next", []),
  false.


% Return none if no active connections are found

%% Public API functions

start_link(Members) -> gen_server:start_link(?MODULE, Members, []).

get_connection() -> gen_server:call(?MODULE, get_connection).

get(Bucket, Key) ->
  poolboy:transaction(
    ?MODULE,
    fun (Worker) -> gen_server:call(Worker, {get, Bucket, Key}) end
  ).

put(Bucket, Key, Value) -> put(Bucket, Key, Value, []).

put({Type, Bucket}, Key, Value, Index) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {put, {Type, Bucket}, Key, Value, Index})
    end
  ).

delete(Bucket, Key) -> gen_server:call(?MODULE, {delete, Bucket, Key}).

list_keys({Type, Bucket}) ->
  poolboy:transaction(
    ?MODULE,
    fun (Worker) -> gen_server:call(Worker, {list_keys, {Type, Bucket}}) end
  ).

get_index({Type, Bucket}, Index, Key) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {get_index_eq, {Type, Bucket}, Index, Key, []})
    end
  ).

get_index_range({Type, Bucket}, Index, StartKey, EndKey) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {get_index_range, {Type, Bucket}, Index, StartKey, EndKey}
        )
    end
  ).

%% GenServer callbacks

init([]) ->
  {ok, Members} = application:get_env(damage, riak),
  init(Members);

init(Members) ->
  logger:info("initializing riak cluster ~p", [Members]),
  Connections =
    lists:filtermap(
      fun
        ({Host, Port}) ->
          try
            case
            riakc_pb_socket:start_link(
              Host,
              Port,
              [{keepalive, true}, {auto_reconnect, true}]
            ) of
              {ok, Pid} ->
                logger:info("connected to riak node ~p ~p", [Host, Port]),
                {true, Pid};

              {error, econnrefused} ->
                logger:info("disconnected riak node ~p ~p", [Host, Port]),
                false;

              _ ->
                logger:info("disconnected riak node ~p ~p", [Host, Port]),
                false
            end
          catch
            {error, {tcp, econnrefused}} -> false;
            _ -> false
          end
      end,
      Members
    ),
  {ok, #state{connections = Connections}}.


handle_call(get_connection, _From, #state{connections = Connections} = State) ->
  case Connections of
    [] -> {reply, {error, no_connection_available}, State};

    [Connection | Rest] ->
      {reply, {ok, Connection}, State#state{connections = Rest}}
  end;

handle_call(
  {get, Bucket, Key},
  _From,
  #state{connections = Connections} = State
) ->
  % Perform get operation using the Riak connection
  Object = find_active_connection(Connections, Bucket, get, [Key]),
  {reply, Object, State};

handle_call(
  {put, Bucket, Key, Value, Index},
  _From,
  #state{connections = Connections} = State
) ->
  % Perform put operation using the Riak connection
  Object0 = riakc_obj:new(Bucket, Key, Value),
  Object =
    case Index of
      [] -> Object0;

      Index0 ->
        MD0 = riakc_obj:get_update_metadata(Object0),
        MD1 = riakc_obj:set_secondary_index(MD0, Index0),
        riakc_obj:update_metadata(Object0, MD1)
    end,
  Res =
    lists:any(
      fun
        (Pid) ->
          case catch riakc_pb_socket:put(Pid, Object) of
            ok -> true;
            {error, disconnected} -> false;

            Err ->
              logger:error("Unexpected riak error ~p", [Err]),
              false
          end
      end,
      Connections
    ),
  {reply, {ok, Res}, State};

handle_call(
  {delete, Bucket, Key},
  _From,
  #state{connections = Connections} = State
) ->
  % Perform delete operation using the Riak connection
  ok =
    lists:any(
      fun
        (Pid) ->
          case riakc_pb_socket:delete(Pid, Bucket, Key) of
            ok -> true;

            Err ->
              logger:error("Unexpected riak error ~p", [Err]),
              false
          end
      end,
      Connections
    ),
  {reply, ok, State};

handle_call(
  {list_keys, Bucket},
  _From,
  #state{connections = Connections} = State
) ->
  Res = find_active_connection(Connections, Bucket, list_keys, []),
  {reply, Res, State};

handle_call(
  {get_index_eq, Bucket, Index, Key, Opts},
  _From,
  #state{connections = Connections} = State
) ->
  {index_results_v1, Res, _, _} =
    find_active_connection(
      Connections,
      Bucket,
      get_index_eq,
      [Index, Key, Opts]
    ),
  {reply, Res, State};

handle_call(_Request, _From, State) -> {reply, {error, unknown_request}, State}.


handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

test() ->
  logger:error("riak put data: ", []),
  Bucket = {<<"Default">>, <<"TestBucket">>},
  {ok, true} = damage_riak:put(Bucket, <<"Key2">>, <<"Value">>),
  {ok, true} =
    damage_riak:put(
      Bucket,
      <<"Key3">>,
      <<"Value">>,
      [{{binary_index, "key1index"}, [<<"bbb">>, <<"aaa">>, <<"ccc">>]}]
    ),
  Obj = damage_riak:get(Bucket, <<"Key3">>),
  logger:info("riak get data: ~p", [Obj]),
  Keys = damage_riak:list_keys(Bucket),
  Keys2 = damage_riak:get_index(Bucket, <<"key1index_bin">>, <<"bbb">>),
  2 = length(Keys2),
  2 = length(Keys).
