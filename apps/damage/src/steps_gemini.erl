-module(steps_gemini).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).
-export([generate_content/3]).
-export([generate_content/4]).
-export([test_generate_content/0]).
-export([test_chat/0]).

-define(GEMINI_API_BASE, "https://generativelanguage.googleapis.com/v1beta").
-define(DEFAULT_MODEL, "gemini-3-flash-preview").
-define(DEFAULT_HTTP_TIMEOUT, 60000).
-define(DEFAULT_HEADERS, [
    {<<"content-type">>, "application/json"},
    {<<"accept">>, "application/json"},
    {<<"user-agent">>, "damagebdd/1.0"}
]).

%% ===== Step Pattern Macros ====================================================
%% erlfmt:ignore-begin

%% GIVEN
-define(STEP_SET_GEMINI_API_KEY,    ["I set the Gemini API key to", ApiKey]).
-define(STEP_STORE_GEMINI_API_KEY,  ["I store the Gemini API key", ApiKey]).
-define(STEP_LOAD_GEMINI_SECRET,    ["I load the Gemini API key from secret", SecretName]).
-define(STEP_SET_GEMINI_MODEL,      ["I use Gemini model", Model]).
-define(STEP_SET_GEMINI_SYSTEM,     ["I set the Gemini system instruction to", Instruction]).
-define(STEP_SET_GEMINI_TEMP,       ["I set the Gemini temperature to", Temperature]).
-define(STEP_SET_THINKING_LEVEL,    ["I set the Gemini thinking level to", Level]).

%% WHEN
-define(STEP_GEMINI_GENERATE,       ["I send a prompt to Gemini", Prompt]).
-define(STEP_GEMINI_GENERATE_BODY,  ["I send a prompt to Gemini"]).
-define(STEP_GEMINI_CHAT,           ["I continue the Gemini conversation with", Message]).
-define(STEP_GEMINI_STORE_RESP,     ["I store the Gemini response in", Variable]).
-define(STEP_GEMINI_WITH_SEARCH,    ["I send a prompt to Gemini with Google Search", Prompt]).
-define(STEP_GEMINI_WITH_CODE_EXEC, ["I send a prompt to Gemini with code execution", Prompt]).

%% THEN
-define(STEP_GEMINI_RESP_CONTAINS,  ["the Gemini response must contain", Expected]).
-define(STEP_GEMINI_RESP_NOT_EMPTY, ["the Gemini response must not be empty"]).
-define(STEP_GEMINI_RESP_JSON_PATH, ["the Gemini response JSON at path", Path, "must be", Value]).
-define(STEP_GEMINI_PRINT_RESP,     ["I print the Gemini response"]).
-define(STEP_GEMINI_STATUS_OK,      ["the Gemini request must have succeeded"]).

%% erlfmt:ignore-end

%%------------------------------------------------------------------------------
%% @doc Unified Gherkin step handler for Google Gemini API interactions.
%%
%% Context keys used/produced:
%%   gemini_api_key   - binary(), REQUIRED. Resolution order:
%%                      1. context key gemini_api_key (set via STEP_SET_GEMINI_API_KEY
%%                         or pre-loaded via STEP_LOAD_GEMINI_SECRET)
%%                      2. secrets:retrieve_decrypt(gemini_api_key) – encrypted at rest
%%                         (atom overridable via context key gemini_secret_name)
%%                      3. GEMINI_API_KEY OS environment variable (dev/CI fallback)
%%   gemini_model     - binary(), optional. Defaults to ?DEFAULT_MODEL.
%%   gemini_system    - binary(), optional system instruction.
%%   gemini_temp      - float(), optional temperature (0.0–2.0).
%%   gemini_thinking  - binary(), optional: <<"low">>|<<"medium">>|<<"high">>.
%%   gemini_history   - list(), accumulated conversation turns (for multi-turn).
%%   gemini_response  - binary(), the last model text response.
%%   gemini_raw       - map(), the last decoded JSON response body.
%%   fail             - binary(), set if any step fails.
%%------------------------------------------------------------------------------
-spec step(
    proplists:proplist(),
    map(),
    binary() | documentation,
    integer(),
    [string() | binary()],
    iodata()
) -> map().

%%------------------------------------------------------------------------------
%% GIVEN: Set API key in context (session-scoped, not persisted to secrets)
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_SET_GEMINI_API_KEY, _) ->
    _ = ApiKey,
    "GIVEN: Store the Gemini API key in context for this session only (not persisted)";
step(_Config, Context, _Kw, _N, ?STEP_SET_GEMINI_API_KEY, _) ->
    maps:put(gemini_api_key, ensure_binary(ApiKey), Context);
%%------------------------------------------------------------------------------
%% GIVEN: Persist API key to secrets store (encrypt_store) and put in context
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_STORE_GEMINI_API_KEY, _) ->
    _ = ApiKey,
    "GIVEN: Encrypt and persist the Gemini API key in the secrets store, then load into context";
step(_Config, Context, _Kw, _N, ?STEP_STORE_GEMINI_API_KEY, _) ->
    Key = ensure_binary(ApiKey),
    case catch secrets:encrypt_store(gemini_api_key, Key) of
        ok ->
            ?LOG_INFO("Gemini API key stored in secrets store", []),
            maps:put(gemini_api_key, Key, Context);
        Error ->
            maps:put(
                fail,
                damage_utils:strf("Failed to store Gemini API key in secrets: ~p", [Error]),
                Context
            )
    end;
%%------------------------------------------------------------------------------
%% GIVEN: Load API key from secrets store by name
%%
%% SecretName is the atom key used when the secret was stored via
%% secrets:encrypt_store/2.  Example Gherkin:
%%   Given I load the Gemini API key from secret gemini_api_key
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_LOAD_GEMINI_SECRET, _) ->
    _ = SecretName,
    "GIVEN: Retrieve and decrypt the Gemini API key from the secrets DETS store";
step(_Config, Context, _Kw, _N, ?STEP_LOAD_GEMINI_SECRET, _) ->
    Atom =
        case SecretName of
            A when is_atom(A) -> A;
            B when is_binary(B) -> binary_to_atom(B, utf8);
            L when is_list(L) -> list_to_atom(L)
        end,
    case secrets:retrieve_decrypt(Atom) of
        {ok, Key} ->
            maps:put(gemini_api_key, ensure_binary(Key), Context);
        error ->
            maps:put(
                fail,
                damage_utils:strf(
                    "Could not retrieve Gemini API key from secrets store (name=~p). "
                    "Ensure the secret was stored with secrets:encrypt_store/2 and "
                    "the node is unlocked.",
                    [Atom]
                ),
                Context
            )
    end;
%%------------------------------------------------------------------------------
%% GIVEN: Select a specific Gemini model
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_SET_GEMINI_MODEL, _) ->
    _ = Model,
    "GIVEN: Choose which Gemini model to use (e.g. gemini-3-flash-preview)";
step(_Config, Context, _Kw, _N, ?STEP_SET_GEMINI_MODEL, _) ->
    maps:put(gemini_model, Model, Context);
%%------------------------------------------------------------------------------
%% GIVEN: Set system instruction
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_SET_GEMINI_SYSTEM, _) ->
    _ = Instruction,
    "GIVEN: Set a system-level instruction that guides all subsequent Gemini turns";
step(_Config, Context, _Kw, _N, ?STEP_SET_GEMINI_SYSTEM, _) ->
    maps:put(gemini_system, Instruction, Context);
%%------------------------------------------------------------------------------
%% GIVEN: Set generation temperature
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_SET_GEMINI_TEMP, _) ->
    _ = Temperature,
    "GIVEN: Set temperature for generation (float 0.0-2.0 as string, e.g. '0.7')";
step(_Config, Context, _Kw, _N, ?STEP_SET_GEMINI_TEMP, _) ->
    Temp =
        case Temperature of
            T when is_float(T) -> T;
            T when is_list(T) -> list_to_float(T);
            T when is_binary(T) -> binary_to_float(T)
        end,
    maps:put(gemini_temp, Temp, Context);
%%------------------------------------------------------------------------------
%% GIVEN: Set thinking level
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_SET_THINKING_LEVEL, _) ->
    _ = Level,
    "GIVEN: Set thinking level: low | medium | high | minimal";
step(_Config, Context, _Kw, _N, ?STEP_SET_THINKING_LEVEL, _) ->
    maps:put(gemini_thinking, Level, Context);
%%------------------------------------------------------------------------------
%% WHEN: Send a prompt inline in the step text
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_GENERATE, _) ->
    _ = Prompt,
    "WHEN: Send the given prompt string to Gemini and store the response";
step(Config, Context, <<"When">>, _N, ?STEP_GEMINI_GENERATE, _) ->
    call_gemini(Config, Context, Prompt, []);
%%------------------------------------------------------------------------------
%% WHEN: Send a prompt from the docstring body
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_GENERATE_BODY, _) ->
    "WHEN: Send the docstring body as a prompt to Gemini";
step(Config, Context, <<"When">>, _N, ?STEP_GEMINI_GENERATE_BODY, Body) ->
    Prompt = iolist_to_binary(Body),
    call_gemini(Config, Context, Prompt, []);
%%------------------------------------------------------------------------------
%% WHEN: Continue a multi-turn conversation
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_CHAT, _) ->
    _ = Message,
    "WHEN: Append Message as a user turn to conversation history and call Gemini";
step(Config, Context, <<"When">>, _N, ?STEP_GEMINI_CHAT, _) ->
    History = maps:get(gemini_history, Context, []),
    UserTurn = #{
        <<"role">> => <<"user">>, <<"parts">> => [#{<<"text">> => ensure_binary(Message)}]
    },
    call_gemini_with_history(Config, Context, [UserTurn | History]);
%%------------------------------------------------------------------------------
%% WHEN: Generate with Google Search grounding
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_WITH_SEARCH, _) ->
    _ = Prompt,
    "WHEN: Send prompt to Gemini with Google Search grounding tool enabled";
step(Config, Context, <<"When">>, _N, ?STEP_GEMINI_WITH_SEARCH, _) ->
    call_gemini(Config, Context, Prompt, [#{<<"google_search">> => #{}}]);
%%------------------------------------------------------------------------------
%% WHEN: Generate with code execution tool
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_WITH_CODE_EXEC, _) ->
    _ = Prompt,
    "WHEN: Send prompt to Gemini with the code_execution tool enabled";
step(Config, Context, <<"When">>, _N, ?STEP_GEMINI_WITH_CODE_EXEC, _) ->
    call_gemini(Config, Context, Prompt, [#{<<"code_execution">> => #{}}]);
%%------------------------------------------------------------------------------
%% WHEN: Store last Gemini response text into a named variable
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_STORE_RESP, _) ->
    _ = Variable,
    "WHEN: Store the last Gemini text response into context variable Variable";
step(_Config, Context, _Kw, _N, ?STEP_GEMINI_STORE_RESP, _) ->
    Response = maps:get(gemini_response, Context, <<"">>),
    maps:put(Variable, Response, Context);
%%------------------------------------------------------------------------------
%% THEN: Assert response contains a substring
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_RESP_CONTAINS, _) ->
    _ = Expected,
    "THEN: Fail if the Gemini response text does not contain Expected substring";
step(_Config, Context, <<"Then">>, _N, ?STEP_GEMINI_RESP_CONTAINS, _) ->
    Response = maps:get(gemini_response, Context, <<"">>),
    RespStr = binary_to_list(ensure_binary(Response)),
    ExpStr = ensure_list(Expected),
    case string:str(RespStr, ExpStr) of
        0 ->
            maps:put(
                fail,
                damage_utils:strf(
                    "Gemini response does not contain ~p. Got: ~p",
                    [Expected, Response]
                ),
                Context
            );
        _ ->
            Context
    end;
%%------------------------------------------------------------------------------
%% THEN: Assert response is not empty
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_RESP_NOT_EMPTY, _) ->
    "THEN: Fail if the Gemini response is empty or missing";
step(_Config, Context, <<"Then">>, _N, ?STEP_GEMINI_RESP_NOT_EMPTY, _) ->
    case maps:get(gemini_response, Context, <<"">>) of
        <<"">> ->
            maps:put(fail, <<"Gemini response is empty">>, Context);
        "" ->
            maps:put(fail, <<"Gemini response is empty">>, Context);
        undefined ->
            maps:put(fail, <<"Gemini response is missing from context">>, Context);
        _ ->
            Context
    end;
%%------------------------------------------------------------------------------
%% THEN: Assert JSON path in raw response
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_RESP_JSON_PATH, _) ->
    _ = Path,
    _ = Value,
    "THEN: Assert ejsonpath Path in the raw Gemini JSON response equals Value";
step(_Config, Context, <<"Then">>, _N, ?STEP_GEMINI_RESP_JSON_PATH, _) ->
    Raw = maps:get(gemini_raw, Context, #{}),
    case catch ejsonpath:q(Path, Raw) of
        {[Value | _], _} ->
            Context;
        Other ->
            maps:put(
                fail,
                damage_utils:strf(
                    "Gemini JSON at ~p expected ~p, got ~p",
                    [Path, Value, Other]
                ),
                Context
            )
    end;
%%------------------------------------------------------------------------------
%% THEN: Print Gemini response to output
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_PRINT_RESP, _) ->
    "THEN: Print the last Gemini response text";
step(Config, Context, Kw, N, ?STEP_GEMINI_PRINT_RESP, _) ->
    Response = maps:get(gemini_response, Context, <<"(no response)">>),
    formatter:format(
        Config,
        print,
        {Kw, N, ["Gemini response:"], ensure_binary(Response), Context, success}
    ),
    Context;
%%------------------------------------------------------------------------------
%% THEN: Assert request succeeded (no fail key set)
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_GEMINI_STATUS_OK, _) ->
    "THEN: Fail if a previous Gemini step has set the fail key in context";
step(_Config, Context, <<"Then">>, _N, ?STEP_GEMINI_STATUS_OK, _) ->
    case maps:get(fail, Context, none) of
        none -> Context;
        Reason -> maps:put(fail, Reason, Context)
    end.

%%==============================================================================
%% Public API helpers
%%==============================================================================

%% @doc Call Gemini generateContent with a plain text prompt and optional tools.
-spec generate_content(ApiKey :: binary(), Model :: string(), Prompt :: binary()) ->
    {ok, binary()} | {error, term()}.
generate_content(ApiKey, Model, Prompt) ->
    generate_content(ApiKey, Model, Prompt, #{}).

-spec generate_content(
    ApiKey :: binary(),
    Model :: string(),
    Prompt :: binary(),
    Opts :: map()
) -> {ok, binary()} | {error, term()}.
generate_content(ApiKey, Model, Prompt, Opts) ->
    Url = build_url(Model),
    Body = build_request_body(Prompt, [], Opts),
    Headers = auth_headers(ApiKey),
    case httpc_post(Url, Headers, Body) of
        {ok, RespBody} ->
            extract_text(RespBody);
        {error, _} = Err ->
            Err
    end.

%%==============================================================================
%% Internal helpers
%%==============================================================================

%% Build the API URL for generateContent
build_url(Model) ->
    ModelStr = ensure_list(Model),
    ?GEMINI_API_BASE ++ "/models/" ++ ModelStr ++ ":generateContent".

%% Resolve the Gemini API key using a three-level priority chain:
%%
%%   1. Context key `gemini_api_key` – set inline via STEP_SET_GEMINI_API_KEY
%%      or pre-loaded via STEP_LOAD_GEMINI_SECRET.  This is always preferred so
%%      that a test scenario can override the node-wide default.
%%
%%   2. secrets:retrieve_decrypt(Atom) – the encrypted-at-rest secret stored at
%%      node start via secrets:encrypt_store(Atom, <<"sk-...">>).
%%      The atom defaults to `gemini_api_key` but can be overridden by setting
%%      `gemini_secret_name` in the context (binary, atom, or list accepted).
%%
%%   3. OS env var GEMINI_API_KEY – convenient for local dev / CI pipelines.
%%
%% Returns a binary key or raises error(gemini_api_key_not_set).
resolve_api_key(Context) ->
    case maps:get(gemini_api_key, Context, undefined) of
        undefined ->
            resolve_api_key_from_secrets(Context);
        Key ->
            ensure_binary(Key)
    end.

resolve_api_key_from_secrets(Context) ->
    Atom = secret_name_atom(maps:get(gemini_secret_name, Context, gemini_api_key)),
    case catch secrets:retrieve_decrypt(Atom) of
        {ok, Key} when is_binary(Key), byte_size(Key) > 0 ->
            Key;
        {ok, Key} when is_list(Key), Key =/= [] ->
            list_to_binary(Key);
        _ ->
            ?LOG_DEBUG(
                "Gemini API key not found in secrets store (name=~p), "
                "trying GEMINI_API_KEY env var",
                [Atom]
            ),
            resolve_api_key_from_env()
    end.

resolve_api_key_from_env() ->
    case os:getenv("GEMINI_API_KEY") of
        false -> error(gemini_api_key_not_set);
        Key -> list_to_binary(Key)
    end.

%% Coerce secret name to atom for secrets:retrieve_decrypt/1
secret_name_atom(A) when is_atom(A) -> A;
secret_name_atom(B) when is_binary(B) -> binary_to_atom(B, utf8);
secret_name_atom(L) when is_list(L) -> list_to_atom(L).

%% Build auth headers including x-goog-api-key
auth_headers(ApiKey) ->
    [
        {<<"x-goog-api-key">>, ensure_binary(ApiKey)}
        | ?DEFAULT_HEADERS
    ].

%% Build the generateContent JSON request body
build_request_body(Prompt, Tools, Opts) ->
    Contents = [
        #{
            <<"parts">> => [#{<<"text">> => ensure_binary(Prompt)}]
        }
    ],
    Base = #{<<"contents">> => Contents},
    WithTools =
        case Tools of
            [] -> Base;
            _ -> Base#{<<"tools">> => Tools}
        end,
    WithSystem =
        case maps:get(system, Opts, undefined) of
            undefined ->
                WithTools;
            Sys ->
                WithTools#{
                    <<"system_instruction">> => #{
                        <<"parts">> => [#{<<"text">> => ensure_binary(Sys)}]
                    }
                }
        end,
    GenConfig0 = #{},
    GenConfig1 =
        case maps:get(temperature, Opts, undefined) of
            undefined -> GenConfig0;
            T -> GenConfig0#{<<"temperature">> => T}
        end,
    GenConfig2 =
        case maps:get(thinking_level, Opts, undefined) of
            undefined -> GenConfig1;
            L -> GenConfig1#{<<"thinking_level">> => ensure_binary(L)}
        end,
    WithGen =
        case map_size(GenConfig2) of
            0 -> WithSystem;
            _ -> WithSystem#{<<"generation_config">> => GenConfig2}
        end,
    jsone:encode(WithGen).

%% Build request body for multi-turn (history already includes latest user turn)
build_history_body(History, Opts) ->
    %% History is newest-first; reverse for the API
    Contents = lists:reverse(History),
    Base = #{<<"contents">> => Contents},
    WithSystem =
        case maps:get(system, Opts, undefined) of
            undefined ->
                Base;
            Sys ->
                Base#{
                    <<"system_instruction">> => #{
                        <<"parts">> => [#{<<"text">> => ensure_binary(Sys)}]
                    }
                }
        end,
    jsone:encode(WithSystem).

%% Execute HTTP POST using httpc
httpc_post(Url, Headers, Body) ->
    UrlStr = ensure_list(Url),
    HeadersList = [{binary_to_list(K), binary_to_list(ensure_binary(V))} || {K, V} <- Headers],
    Request = {UrlStr, HeadersList, "application/json", Body},
    case httpc:request(post, Request, [{timeout, ?DEFAULT_HTTP_TIMEOUT}], []) of
        {ok, {{_, 200, _}, _RespHeaders, RespBody}} ->
            {ok, list_to_binary(RespBody)};
        {ok, {{_, Status, Reason}, _RespHeaders, RespBody}} ->
            ?LOG_ERROR(
                "Gemini API error: status=~p reason=~p body=~p",
                [Status, Reason, RespBody]
            ),
            {error, {http_error, Status, RespBody}};
        {error, Reason} ->
            ?LOG_ERROR("Gemini HTTP request failed: ~p", [Reason]),
            {error, Reason}
    end.

%% Extract the first text response from the Gemini JSON body
extract_text(Body) ->
    try
        Decoded = jsone:decode(Body),
        Candidates = maps:get(<<"candidates">>, Decoded, []),
        case Candidates of
            [] ->
                {error, no_candidates};
            [First | _] ->
                Content = maps:get(<<"content">>, First, #{}),
                Parts = maps:get(<<"parts">>, Content, []),
                Texts = [
                    maps:get(<<"text">>, P, <<"">>)
                 || P <- Parts,
                    maps:get(<<"text">>, P, undefined) =/= undefined
                ],
                {ok, iolist_to_binary(Texts)}
        end
    catch
        _:Err ->
            {error, {decode_failed, Err}}
    end.

%% High-level: call Gemini from a step, updating context
call_gemini(_Config, Context, Prompt, Tools) ->
    ApiKey = resolve_api_key(Context),
    Model = maps:get(gemini_model, Context, ?DEFAULT_MODEL),
    Opts = build_opts_from_context(Context),
    Url = build_url(Model),
    Body = build_request_body(Prompt, Tools, Opts),
    Headers = auth_headers(ApiKey),
    ?LOG_DEBUG("Gemini request url=~p body=~p", [Url, Body]),
    case httpc_post(Url, Headers, Body) of
        {ok, RespBody} ->
            Decoded = jsone:decode(RespBody),
            case extract_text(RespBody) of
                {ok, Text} ->
                    %% Update conversation history
                    UserTurn = #{
                        <<"role">> => <<"user">>,
                        <<"parts">> => [#{<<"text">> => ensure_binary(Prompt)}]
                    },
                    ModelTurn = #{
                        <<"role">> => <<"model">>,
                        <<"parts">> => [#{<<"text">> => Text}]
                    },
                    OldHistory = maps:get(gemini_history, Context, []),
                    NewHistory = [ModelTurn, UserTurn | OldHistory],
                    Context#{
                        gemini_response => Text,
                        gemini_raw => Decoded,
                        gemini_history => NewHistory
                    };
                {error, Reason} ->
                    maps:put(
                        fail,
                        damage_utils:strf("Gemini extract_text failed: ~p", [Reason]),
                        Context
                    )
            end;
        {error, Reason} ->
            maps:put(
                fail,
                damage_utils:strf("Gemini request failed: ~p", [Reason]),
                Context
            )
    end.

%% High-level: multi-turn call using conversation history
call_gemini_with_history(_Config, Context, History) ->
    ApiKey = resolve_api_key(Context),
    Model = maps:get(gemini_model, Context, ?DEFAULT_MODEL),
    Opts = build_opts_from_context(Context),
    Url = build_url(Model),
    Body = build_history_body(History, Opts),
    Headers = auth_headers(ApiKey),
    ?LOG_DEBUG("Gemini chat request url=~p", [Url]),
    case httpc_post(Url, Headers, Body) of
        {ok, RespBody} ->
            Decoded = jsone:decode(RespBody),
            case extract_text(RespBody) of
                {ok, Text} ->
                    ModelTurn = #{
                        <<"role">> => <<"model">>,
                        <<"parts">> => [#{<<"text">> => Text}]
                    },
                    NewHistory = [ModelTurn | History],
                    Context#{
                        gemini_response => Text,
                        gemini_raw => Decoded,
                        gemini_history => NewHistory
                    };
                {error, Reason} ->
                    maps:put(
                        fail,
                        damage_utils:strf("Gemini chat extract_text failed: ~p", [Reason]),
                        Context
                    )
            end;
        {error, Reason} ->
            maps:put(
                fail,
                damage_utils:strf("Gemini chat request failed: ~p", [Reason]),
                Context
            )
    end.

%% Build Opts map from context keys
build_opts_from_context(Context) ->
    Opts0 = #{},
    Opts1 =
        case maps:get(gemini_system, Context, undefined) of
            undefined -> Opts0;
            Sys -> Opts0#{system => Sys}
        end,
    Opts2 =
        case maps:get(gemini_temp, Context, undefined) of
            undefined -> Opts1;
            T -> Opts1#{temperature => T}
        end,
    case maps:get(gemini_thinking, Context, undefined) of
        undefined -> Opts2;
        L -> Opts2#{thinking_level => L}
    end.

%% Type coercion helpers
ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
ensure_binary(V) when is_integer(V) -> integer_to_binary(V);
ensure_binary(V) when is_float(V) -> float_to_binary(V, [{decimals, 6}]).

ensure_list(V) when is_list(V) -> V;
ensure_list(V) when is_binary(V) -> binary_to_list(V);
ensure_list(V) when is_atom(V) -> atom_to_list(V).

%%==============================================================================
%% Tests
%%==============================================================================

test_generate_content() ->
    %% resolve_api_key/1 checks secrets → env var automatically
    ApiKey = resolve_api_key(#{}),
    case generate_content(ApiKey, ?DEFAULT_MODEL, <<"Explain how AI works in a few words">>) of
        {ok, Text} ->
            ?LOG_INFO("Gemini response: ~p", [Text]),
            Text;
        {error, Reason} ->
            error({gemini_failed, Reason})
    end.

test_chat() ->
    Context0 = #{
        gemini_model => ?DEFAULT_MODEL,
        gemini_system => <<"You are a helpful assistant.">>
    },
    Context1 = step(
        [], Context0, <<"When">>, 0, ["I send a prompt to Gemini", "Hello, who are you?"], <<"">>
    ),
    ?LOG_INFO("Turn 1 response: ~p", [maps:get(gemini_response, Context1)]),
    Context2 = step(
        [],
        Context1,
        <<"When">>,
        1,
        ["I continue the Gemini conversation with", "What can you help me with?"],
        <<"">>
    ),
    ?LOG_INFO("Turn 2 response: ~p", [maps:get(gemini_response, Context2)]),
    Context2.
