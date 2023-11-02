%generate an erlang genserver module that pools connections to each member in a riak cluster, expose the riak crud functions through public interfaces
-module(damage_riak).

-behaviour(gen_server).
-behaviour(poolboy_worker).

-export([start_link/1, get_connection/0, get/2, put/3, delete/2]).
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

-include_lib("eunit/include/eunit.hrl").

-record(state, {connections = []}).

%% Public API functions

start_link(Members) -> gen_server:start_link(?MODULE, Members, []).

get_connection() -> gen_server:call(?MODULE, get_connection).

get(Bucket, Key) -> gen_server:call(?MODULE, {get, Bucket, Key}).

put(Bucket, Key, Value) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {put, {<<"Default">>, Bucket}, Key, Value})
    end
  ).

delete(Bucket, Key) -> gen_server:call(?MODULE, {delete, Bucket, Key}).

%% GenServer callbacks

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

              {error, econnrefused} -> false;
              _ -> false
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
  case lists:any(
    fun
      (Pid) ->
        case riakc_pb_socket:get(Pid, Bucket, Key) of
          ok -> true;
          _ -> false
        end
    end,
    Connections
  ) of
    {ok, Object} -> {reply, Object, State};
    _ -> {reply, error, State}
  end;

handle_call(
  {put, Bucket, Key, Value},
  _From,
  #state{connections = Connections} = State
) ->
  % Perform put operation using the Riak connection
  Object = riakc_obj:new(Bucket, Key, Value),
  Res =
    lists:any(
      fun
        (Pid) ->
          case catch riakc_pb_socket:put(Pid, Object) of
            ok -> true;
            Ret -> Ret
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
            _ -> false
          end
      end,
      Connections
    ),
  {reply, ok, State};

handle_call(_Request, _From, State) -> {reply, {error, unknown_request}, State}.


handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

test() ->
  logger:error("riak put data: ", []),
  {ok, _Obj} = damage_riak:put(<<"TestBucket">>, <<"Key">>, <<"Value">>).
