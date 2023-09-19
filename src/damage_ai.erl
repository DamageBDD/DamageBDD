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
-export([generate_code/2]).

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
  try egherkin:parse_file(FeatureFilename) of
    {failed, LineNo, Message} ->
      logger:error("FAIL ~p +~p ~n     ~p.", [FeatureFilename, LineNo, Message]);

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
            model => <<"codellama/CodeLlama-34b-Instruct-hf">>,
            messages => Messages ++ [[{role, <<"user">>}, {content, Prompt0}]],
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
            #{choices := Choices, usage := _Usage} = _Response -> Choices;

            NoChoice ->
              ?debugFmt("Got unexpected response ~p.", [NoChoice]),
              logger:debug("POST Response: ~p", [NoChoice]),
              notok
          end;

        Default ->
          ?debugFmt("Got unexpected response ~p.", [Default]),
          logger:debug("POST Response: ~p", [Default]),
          notok
      end
  catch
    {error, enont} ->
      logger:error("Feature file ~p not found.", [FeatureFilename])
  end.
