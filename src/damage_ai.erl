-module(damage_ai).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").
-include_lib("damage.hrl").

-export([init/2]).

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
    code_change/3
  ]
).
-export([run_python_server/3, generate_code/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_html/2]).
-export([to_json/2]).
-export([to_text/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([is_authorized/2]).
-export([trails/0]).
-export([test_generate_bdd/0]).
-export([test_create_bddmodel/0]).

-define(TRAILS_TAG, ["AI functions."]).

start_link(_Args) -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  logger:info("Damage AI ~p starting.~n", [self()]),
  process_flag(trap_exit, true),
  {ok, undefined}.


create_model(Name) ->
  {ok, Host} = application:get_env(damage, openai_bdd_api_host),
  {ok, Port} = application:get_env(damage, openai_bdd_api_port),
  Messages = [],
  Prompt0 = <<"TEst">>,
  PostData =
    jsx:encode(
      #{
        name => Name,
        messages => Messages ++ [[{role, <<"user">>}, {content, Prompt0}]],
        temperature => 0.7
      }
    ),
  Headers =
    [
      {
        <<"Authorization">>,
        list_to_binary("Bearer " ++ os:getenv("OPENAI_API_KEY"))
      },
      {<<"content-type">>, <<"application/json">>}
    ],
  {ok, ConnPid} = gun:open(Host, Port, #{tls_opts => [{verify, verify_none}]}),
  StreamRef = gun:post(ConnPid, <<"/api/create">>, Headers, PostData),
  Resp = read_stream(ConnPid, StreamRef),
  Resp.


read_stream(ConnPid, StreamRef) ->
  case gun:await(ConnPid, StreamRef, 600000) of
    {response, nofin, Status, _Headers0} ->
      {ok, Body} = gun:await_body(ConnPid, StreamRef),
      ?debugFmt("Got response ~p: ~p.", [Status, Body]),
      ?LOG_DEBUG("POST Response: ~p", [Body]),
      case jsx:decode(Body, [{labels, atom}, return_maps]) of
        #{response := Response} = _Response ->
          ?LOG_DEBUG("Response: ~p", [Response]),
          read_stream(ConnPid, StreamRef);

        NoChoice ->
          ?debugFmt("Got function response ~p.", [NoChoice]),
          ?LOG_DEBUG("POST Response: ~p", [NoChoice]),
          notok
      end;

    Default ->
      ?LOG_DEBUG("Got unexpected response ~p.", [Default]),
      Default
  end.


handle_call({generate_bdd, UserPrompt, _ContractAddress, _Req}, _From, State) ->
  ?LOG_DEBUG("handle_call execute/1 : ~p", [UserPrompt]),
  {ok, MessagesYaml} = application:get_env(damage, openai_bdd_messages_yaml),
  ?LOG_DEBUG("Loading messages from file ~p.", [MessagesYaml]),
  {ok, [_Messages]} =
    fast_yaml:decode_from_file(MessagesYaml, [{plain_as_atom, true}]),
  {ok, FunctionsYaml} = application:get_env(damage, openai_bdd_functions_yaml),
  {ok, [_Functions]} =
    fast_yaml:decode_from_file(FunctionsYaml, [{plain_as_atom, true}]),
  {ok, Model} = application:get_env(damage, openai_bdd_model),
  Prompt0 = <<"generate bdd for this usecase, respond in structured json. ">>,
  %Prompt0 = <<Prompt/binary, UserPrompt/binary>>,
  PostData = jsx:encode(#{model => list_to_binary(Model), prompt => Prompt0}),
  {ok, Host} = application:get_env(damage, openai_bdd_api_host),
  {ok, Path} = application:get_env(damage, openai_bdd_api_path),
  {ok, Port} = application:get_env(damage, openai_bdd_api_port),
  Headers =
    [
      {
        <<"Authorization">>,
        list_to_binary("Bearer " ++ os:getenv("OPENAI_API_KEY"))
      },
      {<<"content-type">>, <<"application/json">>}
    ],
  {ok, ConnPid} = gun:open(Host, Port, #{tls_opts => [{verify, verify_none}]}),
  StreamRef = gun:post(ConnPid, Path, Headers, PostData),
  Resp = read_stream(ConnPid, StreamRef),
  {reply, Resp, State};

handle_call({generate_code, Config, FeatureFilename}, _From, State) ->
  ?LOG_DEBUG("handle_call execute/1 : ~p", [FeatureFilename]),
  try
    case egherkin:parse_file(FeatureFilename) of
      {failed, LineNo, Message} ->
        logger:error(
          "FAIL ~p +~p ~n     ~p.",
          [FeatureFilename, LineNo, Message]
        );

      {_LineNo, _Tags, _Feature, _Description, _BackGround, _Scenarios} ->
        {ok, FeatureData} = file:read_file(FeatureFilename),
        {openai_messages_yaml, MessagesYaml} =
          lists:keyfind(openai_messages_yaml, 1, Config),
        {ok, [Messages]} =
          fast_yaml:decode_from_file(MessagesYaml, [{plain_as_atom, true}]),
        {openai_functions_yaml, FunctionsYaml} =
          lists:keyfind(openai_functions_yaml, 1, Config),
        {ok, [Functions]} =
          fast_yaml:decode_from_file(FunctionsYaml, [{plain_as_atom, true}]),
        {openai_model, Model} = lists:keyfind(openai_model, 1, Config),
        ?debugFmt(
          "Loaded messages from file ~p. Data: ~p",
          [MessagesYaml, Messages]
        ),
        Prompt =
          <<
            "generate python server code from the following bdd, respond in structured json. "
          >>,
        Prompt0 = <<Prompt/binary, FeatureData/binary>>,
        PostData =
          jsx:encode(
            #{
              model => list_to_binary(Model),
              messages
              =>
              Messages
              ++
              [[{role, <<"user">>}, {content, Prompt0}]],
              functions => Functions,
              temperature => 0.7
            }
          ),
        ?debugFmt(
          "Generating python code from feature file ~p. Prompt: ~p",
          [FeatureFilename, PostData]
        ),
        {openai_api_host, Host} = lists:keyfind(openai_api_host, 1, Config),
        {openai_api_path, Path} = lists:keyfind(openai_api_path, 1, Config),
        {openai_api_port, Port} = lists:keyfind(openai_api_port, 1, Config),
        Port = 443,
        Headers =
          [
            {
              <<"Authorization">>,
              list_to_binary("Bearer " ++ os:getenv("OPENAI_API_KEY"))
            },
            {<<"content-type">>, <<"application/json">>}
          ],
        {ok, ConnPid} =
          gun:open(Host, Port, #{tls_opts => [{verify, verify_none}]}),
        StreamRef = gun:post(ConnPid, Path, Headers, PostData),
        case gun:await(ConnPid, StreamRef, 60000) of
          {response, nofin, Status, _Headers0} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            ?debugFmt("Got response ~p: ~p.", [Status, Body]),
            ?LOG_DEBUG("POST Response: ~p", [Body]),
            case jsx:decode(Body, [{labels, atom}, return_maps]) of
              #{choices := [#{message := Message} | _], usage := _Usage} =
                _Response ->
                #{
                  function_call
                  :=
                  #{name := <<"generate_python_code">>, arguments := Arguments}
                } = Message,
                ?LOG_DEBUG("Function Response: ~p", [Arguments]),
                case jsx:decode(Arguments, [{labels, atom}, return_maps]) of
                  #{code := Code, explanation := Explanation} ->
                    ?debugFmt(
                      "Got function response ~p: ~p.",
                      [Code, Explanation]
                    ),
                    {Code, Explanation};

                  InvalidArguments ->
                    ?debugFmt(
                      "Got unexpected arguments for function call ~p.",
                      [InvalidArguments]
                    ),
                    ?LOG_DEBUG(
                      "POST Response Arguments: ~p",
                      [InvalidArguments]
                    ),
                    notok
                end;

              #{choices := Choices, usage := _Usage} = _Response -> Choices;

              NoChoice ->
                ?debugFmt("Got function response ~p.", [NoChoice]),
                ?LOG_DEBUG("POST Response: ~p", [NoChoice]),
                notok
            end;

          Default ->
            ?debugFmt("Got unexpected response ~p.", [Default]),
            ?LOG_DEBUG("POST Response: ~p", [Default]),
            notok
        end
    end
  catch
    {error, enont} ->
      logger:error("Feature file ~p not found.", [FeatureFilename])
  end,
  {reply, ok, State}.


handle_cast({run_python_server, Config, Context, Code}, State) ->
  {data_dir, DataDir} = lists:keyfind(data_dir, 1, Config),
  {contract_address, ContractAddress} =
    lists:keyfind(contract_address, 1, Config),
  ServerPy = "server.py",
  AccountDir = filename:join(DataDir, ContractAddress),
  case filelib:ensure_path(AccountDir) of
    ok ->
      CodeFile = filename:join(AccountDir, ServerPy),
      LogFile = filename:join(AccountDir, "server_log.log"),
      ?debugFmt("Codefile ~p.  DataDir ~p", [CodeFile, DataDir]),
      case file:write_file(CodeFile, Code) of
        ok ->
          logger:info("Starting server process ~p.", [CodeFile]),
          {ok, Pid, OsPid} =
            exec:run(
              "/usr/sbin/python " ++ CodeFile,
              [
                {stderr, stdout},
                {stdout, LogFile, [append, {mode, 384}]},
                monitor
              ]
            ),
          maps:put(server_os_pid, OsPid, maps:put(server_pid, Pid, Context));

        Err ->
          ?debugFmt("Got unexpected error ~p.", [Err]),
          logger:error("Error writing code to file ~p. ~p", [CodeFile, Err])
      end;

    Err ->
      ?debugFmt("Got unexpected error ~p.", [Err]),
      ?LOG_DEBUG("Got  unexpected: ~p", [Err]),
      notok
  end,
  {noreply, State}.


handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
  logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
  ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

generate_code(Config, FeatureFilename) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {generate_code, {Config, FeatureFilename}},
          ?DEFAULT_TIMEOUT
        )
    end
  ).

generate_bdd(UserPrompt, ContractAddress, Req) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:call(
          Worker,
          {generate_bdd, UserPrompt, ContractAddress, Req},
          ?DEFAULT_TIMEOUT
        )
    end
  ).

run_python_server(Config, Context, Code) ->
  poolboy:transaction(
    ?MODULE,
    fun
      (Worker) ->
        gen_server:cast(
          Worker,
          {run_python_server, {Config, Context, Code}},
          ?DEFAULT_TIMEOUT
        )
    end
  ).

% cowboy behaviour
trails() ->
  [
    trails:trail(
      "/ai/generate",
      damage_ai,
      #{},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Form to schedule a test execution.",
          produces => ["text/html"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Schedule a test on post",
          produces => ["application/json"],
          parameters
          =>
          [
            #{
              name => <<"feature">>,
              description => <<"Test feature data.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            }
          ]
        }
      }
    )
  ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
  {
    [
      {{<<"text">>, <<"html">>, '*'}, to_html},
      {{<<"application">>, <<"json">>, []}, to_json},
      {{<<"text">>, <<"plain">>, '*'}, to_text}
    ],
    Req,
    State
  }.

content_types_accepted(Req, State) ->
  {
    [
      {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
      {{<<"application">>, <<"json">>, '*'}, from_json}
    ],
    Req,
    State
  }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

to_html(Req, State) ->
  logger:error("to text ipfs hash ~p ", [Req]),
  to_text(Req, State).


%logger:error("to text ipfs hash ~p ", [Req]),
%Body = damage_utils:load_template("report.mustache", [{body, <<"Test">>}]),
%logger:info("get ipfs hash ~p ", [Body]),
%{Body, Req, State}.
to_json(Req, State) ->
  logger:error("to text ipfs hash ~p ", [Req]),
  to_text(Req, State).


to_text(Req, State) ->
  logger:error("to text ipfs hash ~p ", [Req]),
  {<<"ok">>, Req, State}.


from_json(Req, State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case jsx:decode(Data, [{labels, atom}, return_maps]) of
      #{user_prompt := UserPrompt} = _FeatureJson ->
        check_generate_bdd(UserPrompt, State, Req);

      Err ->
        logger:error("json decoding failed ~p.", [Data]),
        {400, jsx:encode(#{status => <<"notok">>, result => [Err]})}
    end,
  Resp = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


from_html(Req0, State) ->
  {ok, Body, Req} = cowboy_req:read_body(Req0),
  _UserAgent = cowboy_req:header(<<"user-agent">>, Req0, ""),
  Concurrency =
    binary_to_integer(
      cowboy_req:header(<<"x-damage-concurrency">>, Req0, <<"1">>)
    ),
  Fee =
    binary_to_integer(cowboy_req:header(<<"x-damage-fee">>, Req0, <<"4000">>)),
  {Status, Resp0} =
    check_generate_bdd(
      #{feature => Body, concurrency => Concurrency, fee => Fee},
      State,
      Req0
    ),
  Res1 = cowboy_req:set_resp_body(Resp0, Req),
  cowboy_req:reply(Status, Res1),
  {stop, Res1, State}.


check_generate_bdd(
  UserPrompt,
  #{contract_address := ContractAddress} = _State,
  Req0
) ->
  generate_bdd(UserPrompt, ContractAddress, Req0).

%  case damage_ae:balance(ContractAddress) of
%    Balance when Balance >= ?DAMAGE_AI_FEE ->
%      generate_bdd(UserPrompt, ContractAddress, Req0);
%
%    Other ->
%          Msg = <<"Insufficient balance, please top up balance: ", Other/binary>>,
%        logger:info("Damage AI ~p ", [Msg]),
%      {400, Msg}
%  end.
test_create_bddmodel() -> create_model(<<"bdd">>).

test_generate_bdd() ->
  generate_bdd(
    <<
      "generate a bdd for a simple login page hosted  on http://localhost:8000"
    >>,
    <<"test">>,
    #{}
  ).
