-module(damage_ai).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("reporting/formatter.hrl").

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

start_link(_Args) -> gen_server:start_link(?MODULE, [], []).

init([]) ->
  logger:info("Damage AI ~p starting.~n", [self()]),
  process_flag(trap_exit, true),
  {ok, undefined}.


handle_call({generate_code, Config, FeatureName}, _From, State) ->
  logger:debug("handle_call execute/1 : ~p", [FeatureName]),
  generate_code(Config, FeatureName),
  {reply, ok, State}.


handle_cast(_Event, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
  logger:info("Server ~p terminating with reason ~p~n", [self(), Reason]),
  ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.

generate_code(Config, FeatureFilename) ->
  ?debugFmt("Generating python code from feature file ~p.", [FeatureFilename]),
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
            logger:debug("POST Response: ~p", [Body]),
            case jsx:decode(Body, [{labels, atom}, return_maps]) of
              #{choices := [#{message := Message} | _], usage := _Usage} =
                _Response ->
                #{
                  function_call
                  :=
                  #{name := <<"generate_python_code">>, arguments := Arguments}
                } = Message,
                logger:debug("Function Response: ~p", [Arguments]),
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
                    logger:debug(
                      "POST Response Arguments: ~p",
                      [InvalidArguments]
                    ),
                    notok
                end;

              #{choices := Choices, usage := _Usage} = _Response -> Choices;

              NoChoice ->
                ?debugFmt("Got function response ~p.", [NoChoice]),
                logger:debug("POST Response: ~p", [NoChoice]),
                notok
            end;

          Default ->
            ?debugFmt("Got unexpected response ~p.", [Default]),
            logger:debug("POST Response: ~p", [Default]),
            notok
        end
    end
  catch
    {error, enont} ->
      logger:error("Feature file ~p not found.", [FeatureFilename])
  end.


run_python_server(Config, Context, Code) ->
  {data_dir, DataDir} = lists:keyfind(data_dir, 1, Config),
  {account, Account} = lists:keyfind(account, 1, Config),
  ServerPy = "server.py",
  AccountDir = filename:join(DataDir, Account),
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
      logger:debug("Got  unexpected: ~p", [Err]),
      notok
  end,
  ok.
