-module(damage_ipfs).

-behaviour(gen_server).
-behaviour(poolboy_worker).

-export([start_link/1]).
-export(
  [
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    test/0,
    add/1,
    get/2,
    cat/1,
    ls/1
  ]
).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-define(DEFAULT_IPFS_TIMEOUT, 5000).

%% Public API functions

start_link(Members) -> gen_server:start_link(?MODULE, Members, []).

% Entry function to select a server
select_server(Servers) when is_list(Servers) ->
  select_server(Servers, length(Servers)).

% Internal function to handle selection and connection attempts
select_server([], _Length) -> {error, no_available_servers};

select_server(Servers, Length) ->
  % Select a random server
  RandomIndex = rand:uniform(Length),
  SelectedServer = lists:nth(RandomIndex, Servers),
  % Attempt to connect to the selected server
  case catch ipfs:start_link(SelectedServer) of
    {ok, Pid} ->
      case catch ipfs:version(Pid) of
        {ok, _VersionInfo} -> Pid;

        Err ->
          logger:info(
            "Error connecting to ipfs node ~p, index ~p",
            [Err, RandomIndex]
          ),
          % If connection fails, retry with the remaining servers
          RemainingServers = Servers -- [SelectedServer],
          select_server(RemainingServers, Length - 1)
      end;

    Err ->
      logger:info(
        "Error connecting to ipfs node ~p, index ~p",
        [Err, RandomIndex]
      ),
      % If connection fails, retry with the remaining servers
      RemainingServers = Servers -- [SelectedServer],
      select_server(RemainingServers, Length - 1)
  end.


init(Members) ->
  logger:info("initializing ipfs cluster ~p", [Members]),
  Connection =
    select_server([#{ip => Host, port => Port} || {Host, Port} <- Members]),
  {ok, #{connection => Connection}}.


handle_call(
  {add, {data, Data, FileName}},
  _From,
  #{connection := Connection} = State
) ->
  Resp = ipfs:add(Connection, {data, Data, FileName}, ?DEFAULT_IPFS_TIMEOUT),
  logger:info("added data to ipfs node ~p", [Resp]),
  {reply, Resp, State};

handle_call({add, {file, File}}, _From, #{connection := Connection} = State) ->
  Resp = ipfs:add(Connection, {file, File}, ?DEFAULT_IPFS_TIMEOUT),
  logger:info("added data to ipfs node ~p", [Resp]),
  {reply, Resp, State};

handle_call(
  {add, {directory, DirectoryPath}},
  _From,
  #{connection := Connection} = State
) ->
  Resp =
    ipfs:add(Connection, {directory, DirectoryPath}, ?DEFAULT_IPFS_TIMEOUT),
  %?LOG_DEBUG("added data to ipfs node ~p", [Resp]),
  {reply, Resp, State};

handle_call({get, Hash, FileName}, _From, #{connection := Connection} = State) ->
  Resp = ipfs:get(Connection, Hash, FileName, ?DEFAULT_IPFS_TIMEOUT),
  logger:info("get data from ipfs node ~p", [Resp]),
  {reply, Resp, State};

handle_call({cat, Hash}, _From, #{connection := Connection} = State) ->
  Resp = ipfs:cat(Connection, Hash, ?DEFAULT_IPFS_TIMEOUT),
  logger:info("cat data from ipfs node ~p", [Resp]),
  {reply, Resp, State};

handle_call({ls, Hash}, _From, #{connection := Connection} = State) ->
  Resp = ipfs:ls(Connection, Hash, ?DEFAULT_IPFS_TIMEOUT),
  logger:info("get data from ipfs node ~p", [Resp]),
  {reply, Resp, State};

handle_call(Request, _From, State) ->
  logger:error("unknown_request ~p", [Request]),
  {reply, {error, unknown_request}, State}.


handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

add({data, Data, FileName}) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {add, {data, Data, FileName}},
          ?DEFAULT_IPFS_TIMEOUT
        )
    end
  );

add({file, FileName}) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {add, {file, FileName}}, ?DEFAULT_IPFS_TIMEOUT)
    end
  );

add({directory, DirectoryPath}) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {add, {directory, DirectoryPath}},
          ?DEFAULT_IPFS_TIMEOUT
        )
    end
  ).

ls(Hash) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) -> gen_server:call(Worker, {ls, Hash}, ?DEFAULT_IPFS_TIMEOUT)
    end
  ).

get(Hash, FileName) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(Worker, {get, Hash, FileName}, ?DEFAULT_IPFS_TIMEOUT)
    end
  ).

cat(Hash) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) -> gen_server:call(Worker, {cat, Hash}, ?DEFAULT_IPFS_TIMEOUT)
    end
  ).

test() ->
  logger:info("ipfs add directory", []),
  {ok, HashList} = damage_ipfs:add({directory, "features"}),
  [#{<<"Hash">> := Hash}] =
    lists:filter(
      fun
        (I) ->
          #{<<"Hash">> := _Hash, <<"Name">> := Dir} = I,
          string:equal(Dir, "features")
      end,
      HashList
    ),
  logger:info("ipfs add directory hash ~p", [Hash]),
  damage_ipfs:ls(Hash).
