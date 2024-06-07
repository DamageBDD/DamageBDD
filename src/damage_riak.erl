%generate an erlang genserver module that pools connections to each member in a riak cluster, expose the riak crud functions through public interfaces
-module(damage_riak).

-behaviour(gen_server).
-behaviour(poolboy_worker).

-include_lib("kernel/include/logger.hrl").

-export(
  [
    start_link/1,
    get_connection/0,
    get/2,
    get/3,
    put/3,
    put/4,
    delete/2,
    list_keys/1,
    get_index/3,
    get_index/4,
    get_index_range/4,
    get_index_range/5,
    update_hll/3,
    hll_value/2,
    update_counter/3,
    counter_value/2
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
    test/0,
    test_conflict_resolution/0
  ]
).
-export([find_active_connection/3]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {connections = []}).

-define(RIAK_CALL_TIMEOUT, 36000).

% Define the function find_active_connection
find_active_connection(Connections, Fun, Args) ->
  find_active_connection_helper(Connections, Fun, Args).

% Helper function to iterate through the connections
find_active_connection_helper([Connection | Rest], Fun, Args) ->
  case apply(riakc_pb_socket, Fun, [Connection] ++ Args) of
    {ok, Results} -> {ok, Results};
    {error, notfound} -> {error, notfound};
    {error, {notfound, Type}} -> {error, {notfound, Type}};
    ok -> ok;

    Err ->
      logger:error(
        "Unexpected riak error ~p on connectoion ~p trying next",
        [Err, Connection]
      ),
      find_active_connection_helper(Rest, Fun, Args)
  end;

find_active_connection_helper([], _, _) ->
  logger:error("Unexpected riak error not trying next", []),
  false.


% Return none if no active connections are found

%% Public API functions

start_link(Members) -> gen_server:start_link(?MODULE, Members, []).

get_connection() -> gen_server:call(?MODULE, get_connection).

get({Type, Bucket}, Key) ->
  get({Type, Bucket}, Key, [{labels, atom}, return_maps]).

get({Type, Bucket}, Key, JsonDecodeOpts) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {get, {Type, Bucket}, Key, JsonDecodeOpts},
          ?RIAK_CALL_TIMEOUT
        )
    end
  ).

put(Bucket, Key, Value) -> put(Bucket, Key, Value, []).

put({Type, Bucket}, Key, Value, Index) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {put, {Type, Bucket}, Key, Value, Index},
          ?RIAK_CALL_TIMEOUT
        )
    end
  ).

delete(Bucket, Key) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {delete, Bucket, Key}, ?RIAK_CALL_TIMEOUT)
    end
  ).

list_keys({Type, Bucket}) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {list_keys, {Type, Bucket}}, ?RIAK_CALL_TIMEOUT)
    end
  ).

get_index({Type, Bucket}, Index, Key) ->
  get_index({Type, Bucket}, Index, Key, []).

get_index({Type, Bucket}, Index, Key, Opts) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {get_index_eq, {Type, Bucket}, Index, Key, Opts},
          ?RIAK_CALL_TIMEOUT
        )
    end
  ).

get_index_range({Type, Bucket}, Index, StartKey, EndKey) ->
  get_index_range({Type, Bucket}, Index, StartKey, EndKey, []).

get_index_range({Type, Bucket}, Index, StartKey, EndKey, Opts) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {get_index_range, {Type, Bucket}, Index, StartKey, EndKey, Opts},
          ?RIAK_CALL_TIMEOUT
        )
    end
  ).

update_hll(Bucket, Key, Elements) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {update_hll, Bucket, Key, Elements},
          ?RIAK_CALL_TIMEOUT
        )
    end
  ).

hll_value(Bucket, Key) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {hll_value, Bucket, Key}, ?RIAK_CALL_TIMEOUT)
    end
  ).

update_counter(Bucket, Key, OpVal) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {update_counter, Bucket, Key, OpVal},
          ?RIAK_CALL_TIMEOUT
        )
    end
  ).

counter_value(Bucket, Key) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {counter_value, Bucket, Key},
          ?RIAK_CALL_TIMEOUT
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
  {hll_value, Bucket, Key},
  _From,
  #state{connections = Connections} = State
) ->
  case find_active_connection(Connections, fetch_type, [Bucket, Key]) of
    {error, notfound} -> {reply, 0, State};
    {ok, Res} -> {reply, riakc_hll:value(Res), State}
  end;

handle_call(
  {update_hll, Bucket, Key, Elements},
  _From,
  #state{connections = Connections} = State
) ->
  Res =
    case find_active_connection(Connections, fetch_type, [Bucket, Key]) of
      {ok, Hll0} ->
        HllOp0 = riakc_hll:to_op(riakc_hll:add_elements(Elements, Hll0)),
        ok =
          find_active_connection(
            Connections,
            update_type,
            [Bucket, Key, HllOp0]
          ),
        true;

      {error, {notfound, hll}} ->
        Hll0 = riakc_hll:new(),
        HllOp0 = riakc_hll:to_op(riakc_hll:add_elements(Elements, Hll0)),
        ok =
          find_active_connection(
            Connections,
            update_type,
            [Bucket, Key, HllOp0]
          ),
        true;

      {error, disconnected} -> false;

      Err ->
        logger:error("Unexpected riak error ~p", [Err]),
        false
    end,
  {reply, Res, State};

handle_call(
  {counter_value, Bucket, Key},
  _From,
  #state{connections = Connections} = State
) ->
  case find_active_connection(Connections, fetch_type, [Bucket, Key]) of
    {error, notfound} -> {reply, 0, State};
    {error, {notfound, counter}} -> {reply, 0, State};
    {ok, Res} -> {reply, riakc_counter:value(Res), State}
  end;

handle_call(
  {update_counter, Bucket, Key, {Op, Value}},
  _From,
  #state{connections = Connections} = State
) ->
  Res =
    case find_active_connection(Connections, fetch_type, [Bucket, Key]) of
      {ok, Counter} ->
        CounterOp0 =
          riakc_counter:to_op(apply(riakc_counter, Op, [Value, Counter])),
        ?LOG_DEBUG("Counter op ok ~p ~p", [CounterOp0, Key]),
        ok =
          find_active_connection(
            Connections,
            update_type,
            [Bucket, Key, CounterOp0]
          ),
        true;

      {error, {notfound, counter}} ->
        Counter = riakc_counter:new(),
        CounterOp0 =
          riakc_counter:to_op(apply(riakc_counter, Op, [Value, Counter])),
        ?LOG_DEBUG("Counter op new ~p ~p", [CounterOp0, Key]),
        ok =
          find_active_connection(
            Connections,
            update_type,
            [Bucket, Key, CounterOp0]
          ),
        true;

      {error, disconnected} -> false;

      Err ->
        logger:error("Unexpected riak error ~p", [Err]),
        false
    end,
  {reply, Res, State};

handle_call(
  {get, Bucket, Key0, JsonDecodeOpts},
  _From,
  #state{connections = Connections} = State
) ->
  % Perform get operation using the Riak connection
  Key = damage_utils:encrypt(Key0),
  case catch find_active_connection(Connections, get, [Bucket, Key]) of
    false -> {reply, notfound, State};
    {error, notfound} -> {reply, notfound, State};
    {error, {notfound, _Type = map}} -> {reply, notfound, State};
    {error, Error} -> {error, Error, State};
    undef -> {error, undef, State};

    {ok, RiakObject} ->
      Value = check_resolve_siblings(RiakObject, Connections),
      %?LOG_DEBUG(
      %  "get RiakObject ~p ~p",
      %  [RiakObject, damage_utils:decrypt(Value)]
      %),
      DecValue = damage_utils:decrypt(Value),
      case catch jsx:decode(DecValue, JsonDecodeOpts) of
        {'EXIT', {badarg, _}} ->
          logger:error("Unexpected riak error ~p", [Value]),
          {reply, {decode_error, DecValue}, State};

        Result -> {reply, {ok, Result}, State}
      end
  end;

handle_call({put, Bucket, Key, Value, Index}, From, State) when is_map(Value) ->
  {ok, Modified} = datestring:format("YmdHMS", erlang:localtime()),
  handle_call(
    {
      put,
      Bucket,
      Key,
      jsx:encode(maps:put(<<"modified">>, list_to_binary(Modified), Value)),
      Index
    },
    From,
    State
  );

handle_call(
  {put, Bucket, Key, Value, Index},
  _From,
  #state{connections = Connections} = State
) ->
  % Perform put operation using the Riak connection
  Key0 = damage_utils:encrypt(Key),
  Value0 = damage_utils:encrypt(Value),
  Object0 = riakc_obj:new(Bucket, Key0, Value0),
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
          case riakc_pb_socket:delete(Pid, Bucket, damage_utils:encrypt(Key)) of
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
  {get_index_range, Bucket, Index, StartKey, EndKey, Opts},
  _From,
  #state{connections = Connections} = State
) ->
  {ok, {index_results_v1, Res, _, _}} =
    find_active_connection(
      Connections,
      get_index_range,
      [Bucket, Index, StartKey, EndKey, Opts]
    ),
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
  case riakc_obj:get_contents(RiakObject) of
    [] -> throw(no_value);

    [{_MD, V}] ->
      %?LOG_DEBUG(" resolve_siblings ~p", [V]),
      V;

    Siblings ->
      {MD, V} = conflict_resolver(Siblings),
      Obj =
        riakc_obj:update_value(riakc_obj:update_metadata(RiakObject, MD), V),
      ok = find_active_connection(Connections, put, [Obj]),
      V
  end.


resolver_function({_MA, <<>>}, {_MB, _B}) -> false;
resolver_function({_MA, _A}, {_MB, <<>>}) -> true;

resolver_function({MA, A}, {MB, B}) ->
  %?LOG_DEBUG("Generic resolver ~p:~p - ~p:~p", [MA, A, MB, B]),
  ARiakModified =
    date_util:now_to_seconds_hires(dict:fetch(<<"X-Riak-Last-Modified">>, MA)),
  BRiakModified =
    date_util:now_to_seconds_hires(dict:fetch(<<"X-Riak-Last-Modified">>, MB)),
  A1 =
    case catch jsx:decode(damage_utils:decrypt(A), [return_maps]) of
      A0 when is_map(A0) ->
        maps:get(modified, A0, maps:get(created, A0, ARiakModified));

      _ -> ARiakModified
    end,
  B1 =
    case catch jsx:decode(damage_utils:decrypt(B), [return_maps]) of
      B0 when is_map(B0) ->
        maps:get(modified, B0, maps:get(created, B0, BRiakModified));

      _ -> BRiakModified
    end,
  ?LOG_DEBUG(
    "resolution A1 ~p: ~p B1 ~p:~p",
    [A1, ARiakModified, B1, BRiakModified]
  ),
  A1 > B1.


conflict_resolver(Siblings) ->
  SortedList = lists:sort(fun resolver_function/2, Siblings),
  ?LOG_DEBUG("conflict_resolver ~p", [SortedList]),
  lists:nth(1, SortedList).


test() ->
  test_crud(),
  test_hlls(),
  test_counters().


test_conflict_resolution() ->
  {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
  TimestampBin = list_to_binary(Timestamp),
  Bucket = {<<"Default">>, <<"TestBucket", TimestampBin/binary>>},
  Key1 = <<"Key1", TimestampBin/binary>>,
  logger:info("Bucket ~p key ~p", [Bucket, Key1]),
  Obj = #{test => <<"true">>},
  {ok, true} = damage_riak:put(Bucket, Key1, Obj),
  {ok, _Obj} = damage_riak:get(Bucket, Key1),
  Obj0 = #{test => <<"true1">>},
  {ok, true} = damage_riak:put(Bucket, Key1, Obj0),
  {ok, #{modified := _, test := <<"true1">>} = _RetObj0} =
    damage_riak:get(Bucket, Key1),
  ok.


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


test_counters() ->
  {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
  TimestampBin = list_to_binary(Timestamp),
  Bucket = {<<"counters">>, <<"TestBucket", TimestampBin/binary>>},
  Key = <<"Key1", TimestampBin/binary>>,
  true = damage_riak:update_counter(Bucket, Key, {increment, 1}),
  1 = damage_riak:counter_value(Bucket, Key),
  true = damage_riak:update_counter(Bucket, Key, {increment, 3}),
  4 = damage_riak:counter_value(Bucket, Key),
  true = damage_riak:update_counter(Bucket, Key, {decrement, 1}),
  3 = damage_riak:counter_value(Bucket, Key).
