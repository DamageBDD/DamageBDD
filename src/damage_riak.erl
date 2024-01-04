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
    get_index_range/4,
    update_hll/3,
    hll_value/2
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
-export([find_active_connection/3]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {connections = []}).

% Define the function find_active_connection
find_active_connection(Connections, Fun, Args) ->
  find_active_connection_helper(Connections, Fun, Args).

% Helper function to iterate through the connections
find_active_connection_helper([Connection | Rest], Fun, Args) ->
  case apply(riakc_pb_socket, Fun, [Connection] ++ Args) of
    {ok, Results} -> {ok, Results};

    Err ->
      logger:error("Unexpected riak error ~p trying next", [Err]),
      find_active_connection_helper(Rest, Fun, Args)
  end;

find_active_connection_helper([], _, _) ->
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

delete(Bucket, Key) ->
  poolboy:transaction(
    ?MODULE,
    fun (Worker) -> gen_server:call(Worker, {delete, Bucket, Key}) end
  ).

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

update_hll(Bucket, Key, Elements) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) -> gen_server:call(Worker, {update_hll, Bucket, Key, Elements})
    end
  ).

hll_value(Bucket, Key) ->
  poolboy:transaction(
    ?MODULE,
    fun (Worker) -> gen_server:call(Worker, {hll_value, Bucket, Key}) end
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
  {hll_value, Bucket, Key},
  _From,
  #state{connections = Connections} = State
) ->
  {ok, Res} = find_active_connection(Connections, fetch_type, [Bucket, Key]),
  {reply, riakc_hll:value(Res), State};

handle_call(
  {update_hll, Bucket, Key, Elements},
  _From,
  #state{connections = Connections} = State
) ->
  Res =
    lists:any(
      fun
        (Pid) ->
          case riakc_pb_socket:get_bucket(Pid, Bucket) of
            {ok, _} ->
              Hll0 = riakc_hll:new(),
              HllOp0 = riakc_hll:to_op(riakc_hll:add_elements(Elements, Hll0)),
              ok = riakc_pb_socket:update_type(Pid, Bucket, Key, HllOp0),
              true;

            {error, disconnected} -> false;

            Err ->
              logger:error("Unexpected riak error ~p", [Err]),
              false
          end
      end,
      Connections
    ),
  {reply, Res, State};

handle_call(
  {get, Bucket, Key},
  _From,
  #state{connections = Connections} = State
) ->
  % Perform get operation using the Riak connection
  case find_active_connection(Connections, get, [Bucket, Key]) of
    false -> {reply, notfound, State};
    {error, {notfound, _Type = map}} -> {error, notfound, State};
    {error, Error} -> {error, Error, State};
    undef -> {error, undef, State};

    {ok, RiakObject} ->
          Value = check_resolve_siblings(RiakObject, Connections),
      case
      catch
      jsx:decode(
        Value,
        [{labels, atom}, return_maps]
      ) of
        {ok, Result} -> {ok, Result};

        {badarg, Error} ->
          logger:error("Unexpected riak error ~p", [Value]),
          {error, Error, State}
      end
  end;

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
  true =
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
  {ok, Res} = find_active_connection(Connections, list_keys, [Bucket]),
  {reply, Res, State};

handle_call(
  {get_index_eq, Bucket, Index, Key, Opts},
  _From,
  #state{connections = Connections} = State
) ->
  {ok, {index_results_v1, Res, _, _}} =
    find_active_connection(
      Connections,
      get_index_eq,
      [Bucket, Index, Key, Opts]
    ),
  {reply, Res, State};

handle_call(_Request, _From, State) -> {reply, {error, unknown_request}, State}.


handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

check_resolve_siblings(RiakObject, Connections) ->
  {riakc_obj, {_BucketType, _Bucket}, _Key, _Context, _, _, _} = RiakObject,
  case riakc_obj:get_contents(RiakObject) of
    [] -> throw(no_value);
    [{_MD, V}] -> V;

    Siblings ->
      {MD, V} = conflict_resolver(Siblings),
      Obj =
        riakc_obj:update_value(riakc_obj:update_metadata(RiakObject, MD), V),
      {ok, ok} = find_active_connection(Connections, put, [Obj]),
      V
  end.


resolver_function({_MA, A}, {_MB, B}) ->
  logger:debug("Generic json resolver ~p:~p", [A, B]),
  A0 = jsx:decode(A, [{labels, atom}, return_maps]),
  B0 = jsx:decode(B, [{labels, atom}, return_maps]),
  maps:get(
    modified,
    A0,
       maps:get(created, A0)
  )
  <
  maps:get(
      modified,
      B0,
       maps:get(created, B0)
  ).


conflict_resolver(Siblings) ->
  lists:nth(1, lists:sort(fun resolver_function/2, Siblings)).

test() ->
  test_crud(),
  test_hlls().


test_crud() ->
  logger:error("riak put data: ", []),
  {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
  TimestampBin = list_to_binary(Timestamp),
  Bucket = {<<"Default">>, <<"TestBucket", TimestampBin/binary>>},
  Key1 = <<"Key1", TimestampBin/binary>>,
  {ok, true} = damage_riak:put(Bucket, Key1, <<"Value">>),
  Key2 = <<"Key2", TimestampBin/binary>>,
  {ok, true} =
    damage_riak:put(
      Bucket,
      Key2,
      <<"Value">>,
      [
        {
          {binary_index, "key1index"},
          [
            <<"bbb", TimestampBin/binary>>,
            <<"aaa", TimestampBin/binary>>,
            <<"ccc", TimestampBin/binary>>
          ]
        }
      ]
    ),
  Obj = damage_riak:get(Bucket, Key2),
  logger:info("riak get data: ~p", [Obj]),
  Keys = damage_riak:list_keys(Bucket),
  Keys2 =
    damage_riak:get_index(
      Bucket,
      <<"key1index_bin">>,
      <<"bbb", TimestampBin/binary>>
    ),
  1 = length(Keys2),
  2 = length(Keys),
  damage_riak:delete(Bucket, Key2).


test_hlls() ->
  {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
  TimestampBin = list_to_binary(Timestamp),
  Bucket = {<<"hlls">>, <<"TestBucket", TimestampBin/binary>>},
  Key = <<"Key1", TimestampBin/binary>>,
  true = damage_riak:update_hll(Bucket, Key, [<<"Value1">>, <<"value2">>]),
  true = damage_riak:update_hll(Bucket, Key, [<<"value2">>]),
  Value = damage_riak:hll_value(Bucket, Key),
  ?assertEqual(2, Value).
