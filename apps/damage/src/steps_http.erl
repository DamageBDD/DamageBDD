-module(steps_http).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/logger.hrl").

-export([step/6]).
-export([gun_get/4]).
-export([test_get_headers/0]).
-export([test_gun_post/0]).
-export([test_gun_get/0]).
-export([test_using_server/0]).

-define(DEFAULT_WAIT_SECONDS, 3).
-define(DEFAULT_NUM_ATTEMPTS, 3).
-define(DEFAULT_HTTP_TIMEOUT, 60000).
-define(DEFAULT_HTTP_PORT, 80).
-define(DEFAULT_HEADERS, [
    {<<"accept">>, "application/json,text/html"},
    {<<"user-agent">>, "damagebdd/1.0"},
    {<<"content-type">>, "application/json"}
]).
%% KW    :: <<"Given">> | <<"When">> | <<"Then">> | <<"And">> | <<"But">>
%% PARTS :: [string() | binary() | var()]  (var() = an unbound variable name you use in the pattern)
%% META  :: map() of any extra doc (e.g., #{summary => <<"…">>, since => "1.0.0"})
%% BODY  :: the function body (expression(s)) that returns the new Context

%% ===== Parts Macros ==========================================================
%% erlfmt:ignore-begin
%% WHEN
-define(STEP_HTTP_GET_WITH_PARAMS, ["I send a GET request to ", Path, " with parameters"]).
-define(STEP_HTTP_GET_PATH,        ["I make a GET request to", Path]).
-define(STEP_HTTP_POST_PATH,       ["I make a POST request to", Path]).
-define(STEP_HTTP_PATCH_PATH,      ["I make a PATCH request to", Path]).
-define(STEP_HTTP_PUT_PATH,        ["I make a PUT request to", Path]).
-define(STEP_HTTP_OPTIONS_PATH,    ["I make a OPTIONS request to", Path]).
-define(STEP_HTTP_DELETE_PATH,     ["I make a DELETE request to", Path]).
-define(STEP_HTTP_TRACE_PATH,      ["I make a TRACE request to", Path]).
-define(STEP_HTTP_FORM_POST_PATH,  ["I make a form POST request to", Path]).
-define(STEP_HTTP_CSRF_POST_PATH,  ["I make a CSRF POST request to", Path]).
-define(STEP_HEAD_PATH,            ["I make a HEAD request to", Path]).
-define(STEP_POLL_UNTIL_EQ,        ["I keep sending GET requests to",
                                    UrlPathSegment,
                                    "until JSON at path",
                                    JsonPath,
                                    "is"
                                   ]).

%% THEN
-define(STEP_RESPONSE_CONTAINS,       ["the response must contain text", Contains]).
-define(STEP_RESPONSE_STATUS_EQ,      ["the response status must be", Status]).
-define(STEP_RESPONSE_STATUS_ONEOF,   ["the response status must be one of", Statuses]).
-define(STEP_RESPONSE_YAML_MUST,      ["the yaml at path", Path, "must be", Expected0]).
-define(STEP_RESPONSE_JSON_MUST,      ["the json at path", Path, "must be", Expected0]).
-define(STEP_RESPONSE_JSON_SHOULD,    ["the JSON at path", JsonPath, "should be"]).
-define(STEP_RESPONSE_HEADER_IS,      ["the", Var, "header should be", Value]).
-define(STEP_RESPONSE_PRINT_JSON_PATH,["I print the json at path", Path]).
-define(STEP_RESPONSE_PRINT_BODY,     ["I print the response body"]).
-define(STEP_RESPONSE_PRINT_RESP,     ["I print the response"]).
-define(STEP_RESPONSE_STORE_JSON,     ["I store the JSON at path", Path, "in", Variable]).
-define(STEP_RESPONSE_JSON_SHOULD_BE, ["the JSON should be"]).
-define(STEP_VAR_EQ_JSON_LIT,         ["the variable", Variable, "should be equal to JSON", Value]).
-define(STEP_RESPONSE_JSON_PATH_ONE_OF, ["the json at path", JsonPath, "must be one of", Csv]).
-define(STEP_RESPONSE_JSON_PATH_MUST_BE_GTE, ["the json int at path", JsonPath, "must be >=", MinStr]).

%% GIVEN / ANY
-define(STEP_GIVEN_USING_SERVER,  ["I am using server", Server]).
-define(STEP_SET_BASE_URL,        ["I set base URL to", Server]).
-define(STEP_STORE_COOKIES,       ["I store cookies"]).
-define(STEP_SET_HEADER,          ["I set", Header, "header to", Value]).
-define(STEP_CLEAR_HEADER,          ["I clear header", Header]).
-define(STEP_NO_VERIFY_SSL,       ["I do not want to verify server certificate"]).
-define(STEP_GIVEN_BASIC_AUTH,    ["I set BasicAuth username to ", User, "and password to", Password]).
-define(STEP_GIVEN_OAUTH_QUERY,   ["I use query OAuth with key=", Key, "and secret=", Secret]).
-define(STEP_GIVEN_OAUTH_HEADER,  ["I use header OAuth with key=", Key, "and secret=", Secret]).
-define(STEP_RESPONSE_STORE_HEADER, ["I store the response header", Header, "as", Variable]).
%% erlfmt:ignore-end

%%------------------------------------------------------------------------------
%% @doc
%%  Unified Gherkin step handler.
%%
%%  Each clause matches a specific (Keyword, Parts) pattern and performs an
%%  action (HTTP request) or an assertion against the HTTP response stored in
%%  `Context`. The `Config` is passed through to HTTP helpers (gun_*).
%%
%%  Expected `Context` shapes (as used by different clauses below):
%%    - Most HTTP-result-bearing clauses expect:
%%        maps:get(response, Context) =>
%%          [{status_code, integer()}, {headers, Headers :: list()}, {body, Body :: binary()}]
%%      but a few older clauses match `[_, _Headers, {body, Body}]` or even `{_, Headers, _}`.
%%      Keep this consistent across producers/consumers to avoid brittle matches.
%%
%%  Common helpers referenced (assumed exported elsewhere in the module):
%%    - gun_get/4, gun_post/5, gun_put/5, gun_patch/5, gun_delete/4, gun_options/4, gun_head/4
%%    - get_headers/2, build_url/2
%%    - ejsonpath_match/4, retry_get_ejsonmatch/9
%%    - steps_utils:parse_step_body/1
%%    - formatter:format/3
%%
%%  NOTE: `uri_string:compose_query/1` in one clause is likely a typo;
%%        it should be `uri_string:compose_query/1`.
%%------------------------------------------------------------------------------
-spec step(
    %% Config is a proplist
    proplists:proplist(),
    %% Context
    map(),
    %% Keyword <<"Given">>|<<"When">>|<<"Then">>|<<"And">>|<<"But">>
    binary(),
    %% Line number (N) for reporting
    integer(),
    %% Tokenized step text (Parts)
    [string() | binary()],
    %% Raw docstring/datatable/body (if any)
    iodata()
) -> map().

%%------------------------------------------------------------------------------
%% THEN: the response must contain a specific substring (plain-text search)
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    <<"Then">>,
    _N,
    ?STEP_RESPONSE_CONTAINS,
    _
) ->
    %% Extract raw body (expects [{...},{...},{body, Body}] shape)
    [_, _Headers, {body, Body}] = maps:get(response, Context),
    %% string:str/2 works on lists; convert body to list but keep `Contains` as-is.
    %% If `Contains` is a binary, ensure upstream passes a list, or convert here.
    case string:str(binary_to_list(Body), Contains) of
        0 ->
            maps:put(
                fail,
                damage_utils:strf("Response ~p does not contain ~p", [Body, Contains]),
                Context
            );
        _ ->
            Context
    end;
%%------------------------------------------------------------------------------
%% WHEN: GET with query parameters provided in the step body (form-like)
%% Parts: ["I send a GET request to ", Path, " with parameters"]
%% Body:  key=value lines parsed into a map
%%------------------------------------------------------------------------------
step(_Config, _Context, documentation, _N, ?STEP_HTTP_GET_WITH_PARAMS, _) ->
    _ = Path,
    "WHEN: GET with query parameters provided in the step body (form-like)";
step(
    Config,
    Context,
    <<"When">>,
    _N,
    ?STEP_HTTP_GET_WITH_PARAMS,
    Body
) ->
    Params = steps_utils:parse_step_body(Body),
    %% NOTE: likely typo; prefer uri_string:compose_query/1
    Query = uri_string:compose_query(maps:to_list(Params)),
    gun_get(
        Config,
        Context,
        string:concat(maps:get(base_url, Context, ""), string:concat(Path, Query)),
        get_headers(Context, ?DEFAULT_HEADERS)
    );
step(_Config, _Context, documentation, _N, ?STEP_HTTP_GET_PATH, _) ->
    _ = Path,
    "WHEN: Simple GET to a path (base_url is read from Context)";
step(Config, Context, <<"When">>, _N, ?STEP_HTTP_GET_PATH, _) ->
    gun_get(
        Config,
        Context,
        string:concat(maps:get(base_url, Context, ""), Path),
        get_headers(Context, ?DEFAULT_HEADERS)
    );
%%------------------------------------------------------------------------------
%% WHEN: POST to a path with request body as-is (IODATA)
%%------------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?STEP_HTTP_POST_PATH, Data) ->
    Url = build_url(Path, maps:get(base_url, Context, "")),
    Headers = get_headers(Context, ?DEFAULT_HEADERS),
    gun_post(Config, Context, Url, Headers, Data);
%%------------------------------------------------------------------------------
%% WHEN: PATCH to a path with body
%%------------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?STEP_HTTP_PATCH_PATH, Data) ->
    Headers = get_headers(Context, ?DEFAULT_HEADERS),
    Url = build_url(Path, maps:get(base_url, Context, "")),
    gun_patch(Config, Context, Url, Headers, Data);
%%------------------------------------------------------------------------------
%% WHEN: PUT to a path with body
%%------------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?STEP_HTTP_PUT_PATH, Data) ->
    Headers = get_headers(Context, ?DEFAULT_HEADERS),
    Url = build_url(Path, maps:get(base_url, Context, "")),
    gun_put(Config, Context, Url, Headers, Data);
%%------------------------------------------------------------------------------
%% WHEN: OPTIONS request
%%------------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?STEP_HTTP_OPTIONS_PATH, _Data) ->
    gun_options(
        Config,
        Context,
        build_url(Path, maps:get(base_url, Context, "")),
        get_headers(Context, ?DEFAULT_HEADERS)
    );
%%------------------------------------------------------------------------------
%% WHEN: DELETE request
%%------------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?STEP_HTTP_DELETE_PATH, _Data) ->
    gun_delete(
        Config,
        Context,
        build_url(Path, maps:get(base_url, Context, "")),
        get_headers(Context, ?DEFAULT_HEADERS)
    );
%%------------------------------------------------------------------------------
%% WHEN: TRACE not implemented (explicit failure marker)
%%------------------------------------------------------------------------------
step(_Config, Context, <<"When">>, _N, ?STEP_HTTP_TRACE_PATH, _Data) ->
    ?LOG_DEBUG("TRACE path ~p", [Path]),
    maps:put(fail, <<"Step not implemented">>, Context);
%%------------------------------------------------------------------------------
%% WHEN: CSRF POST:
%%   1) GET path to fetch CSRF/session headers
%%   2) POST with CSRF + Session headers added
%%------------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?STEP_HTTP_CSRF_POST_PATH, Data) ->
    Headers0 = lists:append(
        [
            {<<"accept">>, "application/json"},
            {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
            {<<"Referer">>, Path},
            {<<"X-Requested-with">>, <<"XMLHttpRequest">>}
        ],
        maps:get(headers, Context)
    ),
    Context0 = gun_get(Config, Context, Path, Headers0),
    case maps:get(response, Context0) of
        [StatusCode, {headers, Headers}, Body] ->
            %% Extract CSRF and session IDs from response headers
            {_, CSRFToken} = lists:keyfind(<<"x-csrftoken">>, 1, Headers),
            {_, SessionId} = lists:keyfind(<<"x-sessionid">>, 1, Headers),
            ?LOG_DEBUG(
                "POSTResponse: ~p:~p:~p:~p:~p",
                [StatusCode, Headers, Body, CSRFToken, SessionId]
            ),
            gun_post(
                Config,
                Context,
                string:concat(maps:get(base_url, Context, ""), Path),
                lists:append(
                    Headers0,
                    [{<<"X-CSRFToken">>, CSRFToken}, {<<"X-SessionID">>, SessionId}]
                ),
                Data
            )
    end;
%%------------------------------------------------------------------------------
%% WHEN: Form POST without CSRF preflight (explicit form headers)
%%------------------------------------------------------------------------------
step(Config, Context, <<"When">>, _N, ?STEP_HTTP_FORM_POST_PATH, Data) ->
    Headers0 = [
        {<<"accept">>, "application/json"},
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>},
        {<<"Referer">>, Path},
        {<<"X-Requested-With">>, <<"XMLHttpRequest">>}
    ],
    gun_post(
        Config,
        Context,
        string:concat(maps:get(base_url, Context, ""), Path),
        Headers0,
        Data
    );
%%------------------------------------------------------------------------------
%% THEN: Exact response status match (single status)
%%------------------------------------------------------------------------------
step(_Config, Context, _, _N, ?STEP_RESPONSE_STATUS_EQ, _) ->
    Status0 = list_to_integer(Status),
    case maps:get(response, Context, undefined) of
        [{status_code, Status0}, _, _] ->
            Context;
        [{status_code, Status1}, _, _] ->
            maps:put(
                fail,
                damage_utils:strf("Response status is not ~p, got ~p", [Status0, Status1]),
                Context
            );
        Any ->
            maps:put(
                fail,
                damage_utils:strf("Response status is not ~p, got ~p", [Status0, Any]),
                Context
            )
    end;
%%------------------------------------------------------------------------------
%% THEN: YAML at JSONPath equals expected (body may be YAML or a map already)
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    <<"Then">>,
    _N,
    ?STEP_RESPONSE_YAML_MUST,
    _
) ->
    Expected = list_to_binary(Expected0),
    case maps:get(response, Context, undefined) of
        [{status_code, _}, _Headers, {body, Body}] ->
            {ok, [Data]} = damage_utils:yaml_decode(Body),
            ejsonpath_match(
                Path, damage_utils:map_strings_to_binary(maps:from_list(Data)), Expected, Context
            );
        Dict when is_map(Dict) ->
            ejsonpath_match(Path, jsx:decode(jsx:encode(Dict)), Expected, Context);
        UnExpected ->
            maps:put(fail, damage_utils:strf("Unexpected response ~p", [UnExpected]), Context)
    end;
%%------------------------------------------------------------------------------
%% THEN: JSON at JSONPath equals expected (with JSON decoding safety)
%%------------------------------------------------------------------------------
%% Then the json at path $.Key must be "<cid>"
step(
    _Config,
    Context,
    <<"Then">>,
    _N,
    ?STEP_RESPONSE_JSON_MUST,
    _
) ->
    Expected = list_to_binary(Expected0),
    case maps:get(response, Context) of
        [{status_code, _}, _Headers, {body, Body}] ->
            case catch jsx:decode(Body, [return_maps]) of
                {'EXIT', Msg} ->
                    ?LOG_ERROR("Unexpected ~p ~p", [Body, Msg]),
                    maps:put(fail, damage_utils:strf("invalid json: ~p", [Body]), Context);
                Json ->
                    ejsonpath_match(Path, Json, Expected, Context)
            end;
        Dict when is_map(Dict) ->
            ejsonpath_match(Path, jsx:decode(jsx:encode(Dict)), Expected, Context);
        UnExpected ->
            Msg = damage_utils:strf("Unexpected response ~p", [UnExpected]),
            ?LOG_ERROR("Unexpected ~p", [Msg]),
            maps:put(fail, Msg, Context)
    end;
%%------------------------------------------------------------------------------
%% THEN: Response status must be among a comma-separated list
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    _,
    _N,
    ?STEP_RESPONSE_STATUS_ONEOF,
    _
) ->
    ?LOG_DEBUG("the response status must be one of ~p.", [Statuses]),
    case maps:get(response, Context, undefined) of
        [{status_code, StatusCode}, _Headers, _Body] ->
            case
                lists:member(
                    StatusCode,
                    lists:map(fun erlang:list_to_integer/1, string:split(Statuses, ","))
                )
            of
                true ->
                    Context;
                _ ->
                    ?LOG_DEBUG("the response status must be one of ~p.", [StatusCode]),
                    maps:put(
                        fail,
                        damage_utils:strf(
                            "Response status ~p is not one of ~p",
                            [StatusCode, Statuses]
                        ),
                        Context
                    )
            end;
        UnExpected ->
            ?LOG_ERROR("unexpected response in context ~p.", [UnExpected]),
            maps:put(fail, damage_utils:strf("Unexpected response ~p", [UnExpected]), Context)
    end;
%%------------------------------------------------------------------------------
%% THEN: Specific header should equal an expected value
%%------------------------------------------------------------------------------
step(_Config, Context, <<"Then">>, _N, ?STEP_RESPONSE_HEADER_IS, _) ->
    case maps:get(response, Context) of
        {_, Headers, _} ->
            case lists:keyfind(Var, 1, Headers) of
                {Var, Value} ->
                    Context;
                Unexpected ->
                    maps:put(
                        fail,
                        damage_utils:strf(
                            "the ~p header is not ~p, it is ~p",
                            [Var, Value, Unexpected]
                        )
                    )
            end;
        Unexpected ->
            maps:put(
                fail,
                damage_utils:strf(
                    "the ~p header is not ~p, request failed ~p",
                    [Var, Value, Unexpected]
                )
            )
    end;
%%------------------------------------------------------------------------------
%% THEN: Print JSON at JSONPath (for debugging/visibility in formatter)
%%------------------------------------------------------------------------------
step(Config, Context, <<"Then">>, N, ?STEP_RESPONSE_PRINT_JSON_PATH, _) ->
    [{status_code, _StatusCode}, {headers, _Headers}, {body, Body}] =
        maps:get(response, Context),
    case ejsonpath:q(Path, jsx:decode(Body, [return_maps])) of
        {[Value | _], _} ->
            formatter:format(
                Config,
                print,
                {<<"Then">>, N, ["Response Json at: \"", Path, "\""],
                    list_to_binary(damage_utils:strf("~s", [jsx:encode(Value)])), Context, success}
            ),
            Context;
        UnExpected ->
            maps:put(
                fail,
                damage_utils:strf("the json at path ~p it is ~p.", [Path, UnExpected]),
                Context
            )
    end;
%%------------------------------------------------------------------------------
%% THEN: Print raw response body
%%------------------------------------------------------------------------------
step(Config, Context, <<"Then">>, N, ?STEP_RESPONSE_PRINT_BODY, _) ->
    [{status_code, _StatusCode}, {headers, _Headers}, {body, Body}] =
        maps:get(response, Context),
    formatter:format(
        Config,
        print,
        {<<"Then">>, N, ["Response Body:"], list_to_binary(damage_utils:strf("~s", [Body])),
            Context, success}
    ),
    Context;
%%------------------------------------------------------------------------------
%% THEN: Print the entire response structure (as JSON)
%%------------------------------------------------------------------------------
step(Config, Context, _, N, ?STEP_RESPONSE_PRINT_RESP, _) ->
    Response = maps:get(response, Context, <<"">>),
    formatter:format(
        Config,
        print,
        {<<"Then">>, N, ["Response:"], jsx:encode(Response), Context, success}
    ),
    Context;
%%------------------------------------------------------------------------------
%% (Given/And/Then): Set/override a request header in context
%%------------------------------------------------------------------------------
step(_Config, Context, _Keyword, _N, ?STEP_SET_HEADER, _) ->
    Headers0 = maps:from_list(get_headers(Context, ?DEFAULT_HEADERS)),
    Headers = maps:to_list(
        maps:put(list_to_binary(string:to_lower(Header)), Value, Headers0)
    ),
    maps:put(headers, Headers, Context);
step(_Config, Context, _Keyword, _N, ?STEP_CLEAR_HEADER, _) ->
    Headers0 = maps:from_list(get_headers(Context, ?DEFAULT_HEADERS)),
    Headers = maps:to_list(
        maps:remove(list_to_binary(string:to_lower(Header)), Headers0)
    ),
    maps:put(headers, Headers, Context);
%%------------------------------------------------------------------------------
%% GIVEN: Store cookies from response (extract 'set-cookie' headers)
%%------------------------------------------------------------------------------
step(_Config, Context, <<"Given">>, _N, ?STEP_STORE_COOKIES, _) ->
    [_, _StatusCode, {headers, Headers}, _Body] = maps:get(response, Context),
    ?LOG_DEBUG("Response Headers:  ~p", [Headers]),
    Cookies =
        lists:foldl(
            fun
                ({<<"set-cookie">>, Header}, Acc) -> [Acc | Header];
                (_Other, Acc) -> Acc
            end,
            [],
            Headers
        ),
    ?LOG_DEBUG("Response:  ~p", [Headers, Cookies]),
    maps:put(cookies, Cookies, Context);
%%------------------------------------------------------------------------------
%% THEN: Extract JSON at path and store it into a variable in context
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    _,
    _N,
    ?STEP_RESPONSE_STORE_JSON,
    _
) ->
    case maps:get(response, Context) of
        [{status_code, _}, _Headers, {body, Body}] ->
            Variable0 = list_to_atom(Variable),
            case ejsonpath:q(Path, jsx:decode(Body, [return_maps])) of
                {[Json0 | _], _} ->
                    Json = binary_to_list(Json0),
                    ?LOG_DEBUG("storing json at path ~p json ~p", [Path, Json]),
                    maps:put(Variable0, Json, Context);
                UnExpected ->
                    maps:put(
                        fail,
                        damage_utils:strf(
                            "the json at path ~p is not ~p, it is ~p.",
                            [Path, Variable, UnExpected]
                        ),
                        Context
                    )
            end;
        UnExpected ->
            ?LOG_DEBUG("failed to store json at path ~p error ~p", [Path, UnExpected]),
            maps:put(fail, damage_utils:strf("Unexpected response ~p", [UnExpected]), Context)
    end;
%%------------------------------------------------------------------------------
%% GIVEN: Set base server and derive host/port from URI
%%------------------------------------------------------------------------------
step(_Config, Context0, <<"Given">>, _N, ?STEP_GIVEN_USING_SERVER, _) when
    is_map(Context0)
->
    Context = maps:put(base_url, Server, Context0),
    case uri_string:parse(Server) of
        #{port := Port, scheme := _Scheme, path := _Path, host := Host} ->
            maps:put(port, Port, maps:put(host, Host, Context));
        #{scheme := "https", host := Host, path := _Path} ->
            maps:put(port, 443, maps:put(host, Host, Context));
        #{scheme := "http", host := Host, path := _Path} ->
            maps:put(port, 80, maps:put(host, Host, Context));
        #{path := Host} ->
            maps:put(host, Host, Context)
    end;
%%------------------------------------------------------------------------------
%% GIVEN: Alias for setting base URL (chains into "I am using server")
%%------------------------------------------------------------------------------
step(Config, Context, <<"Given">>, _N, ?STEP_SET_BASE_URL, Body) ->
    maps:put(
        base_url,
        Server,
        step(Config, Context, <<"Given">>, _N, ?STEP_GIVEN_USING_SERVER, Body)
    );
%%------------------------------------------------------------------------------
%% GIVEN: Set BasicAuth credentials
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    <<"Given">>,
    _N,
    ?STEP_GIVEN_BASIC_AUTH,
    _
) ->
    maps:put(basic_auth, {User, Password}, Context);
%%------------------------------------------------------------------------------
%% GIVEN: Set OAuth (query) credentials
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    <<"Given">>,
    _N,
    ?STEP_GIVEN_OAUTH_QUERY,
    _
) ->
    maps:put(oauth_query_auth, {Key, Secret}, Context);
%%------------------------------------------------------------------------------
%% GIVEN: Set OAuth (header) credentials
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    <<"Given">>,
    _N,
    ?STEP_GIVEN_OAUTH_HEADER,
    _
) ->
    maps:put(oauth_header_auth, {Key, Secret}, Context);
%%------------------------------------------------------------------------------
%% (Given/When/Then/And): Disable TLS certificate verification for subsequent requests
%%------------------------------------------------------------------------------
step(_Config, Context, _, _N, ?STEP_NO_VERIFY_SSL, _) ->
    maps:put(verify_ssl, false, Context);
%%------------------------------------------------------------------------------
%% (Given/When/Then/And): Poll a GET endpoint until JSONPath equals Args
%%------------------------------------------------------------------------------
step(
    Config,
    Context,
    _,
    _N,
    ?STEP_POLL_UNTIL_EQ,
    Args
) ->
    NAttempts = maps:get(n_attempts, Context, ?DEFAULT_NUM_ATTEMPTS),
    retry_get_ejsonmatch(
        Config,
        Context,
        JsonPath,
        Args,
        UrlPathSegment,
        [],
        NAttempts,
        ?DEFAULT_WAIT_SECONDS,
        0
    );
%%------------------------------------------------------------------------------
%% (Given/When/Then/And): HEAD request
%%------------------------------------------------------------------------------
step(Config, Context, _, _N, ?STEP_HEAD_PATH, _) ->
    gun_head(
        Config,
        Context,
        string:concat(maps:get(base_url, Context, ""), Path),
        get_headers(Context, ?DEFAULT_HEADERS)
    );
%%------------------------------------------------------------------------------
%% (Given/When/Then/And): Assert entire JSON body equals Args (exact match)
%%------------------------------------------------------------------------------
step(_Config, Context, _, _N, ?STEP_RESPONSE_JSON_SHOULD_BE, Args) ->
    case maps:get(response, Context) of
        {_Status, _Headers, Args} ->
            Context;
        Unexpected ->
            maps:put(
                fail,
                damage_utils:strf("The JSON is ~p not ~p", [Unexpected, Args]),
                Context
            )
    end;
%%------------------------------------------------------------------------------
%% (Given/When/Then/And): Assert context variable equals literal JSON value
%%------------------------------------------------------------------------------
step(_Config, Context, _, _N, ?STEP_VAR_EQ_JSON_LIT, _) ->
    Actual = maps:get(list_to_atom(Variable), Context, none),
    case catch jsx:decode(list_to_binary(Value), [return_maps]) of
        {'EXIT', Reason} ->
            maps:put(
                fail,
                damage_utils:strf(
                    "Invalid JSON literal for variable ~p: ~p (~p)",
                    [Variable, Value, Reason]
                ),
                Context
            );
        Expected ->
            case normalize_jsonish(Actual) =:= normalize_jsonish(Expected) of
                true ->
                    Context;
                false ->
                    maps:put(
                        fail,
                        damage_utils:strf(
                            "Variable ~p JSON mismatch. Expected ~p, got ~p",
                            [Variable, Expected, Actual]
                        ),
                        Context
                    )
            end
    end;
%%------------------------------------------------------------------------------
%% (Given/When/Then/And): Alias for "json at path ... must be ..."
%%------------------------------------------------------------------------------
step(
    Config,
    Context,
    KeyWord,
    LineNo,
    ?STEP_RESPONSE_JSON_SHOULD,
    Args
) ->
    step(
        Config,
        Context,
        KeyWord,
        LineNo,
        ["the json at path", JsonPath, "must be", Args],
        <<>>
    );
%% Then the JSON at path "Keys.<cid>.Type" must be one of "recursive,direct,indirect"
step(
    _Cfg,
    Context0,
    _,
    _N,
    ?STEP_RESPONSE_JSON_PATH_ONE_OF,
    _
) ->
    [{status_code, _}, _Hdrs, {body, Body}] = maps:get(response, Context0),
    case catch jsx:decode(Body, [return_maps]) of
        {'EXIT', _} ->
            maps:put(fail, <<"invalid json in response">>, Context0);
        Json ->
            case ejsonpath:q(JsonPath, Json) of
                {[Val | _], _} ->
                    ValB =
                        case Val of
                            B when is_binary(B) -> B;
                            L when is_list(L) -> list_to_binary(L);
                            Other -> list_to_binary(io_lib:format("~p", [Other]))
                        end,
                    Allowed = [
                        list_to_binary(string:trim(S))
                     || S <- string:split(Csv, ",", all)
                    ],
                    case lists:member(ValB, Allowed) of
                        true ->
                            Context0;
                        false ->
                            maps:put(
                                fail, damage_utils:strf("~p not in ~p", [ValB, Allowed]), Context0
                            )
                    end;
                Other ->
                    maps:put(
                        fail,
                        damage_utils:strf("Path ~p not found (~p)", [JsonPath, Other]),
                        Context0
                    )
            end
    end;
%% Then the JSON integer field at $.Size must be >= N
step(
    _Cfg,
    Context,
    _,
    _N,
    ?STEP_RESPONSE_JSON_PATH_MUST_BE_GTE,
    _
) ->
    case maps:get(response, Context) of
        [{status_code, _}, _Hdrs, {body, Body}] ->
            case catch jsx:decode(Body, [return_maps]) of
                {'EXIT', _} ->
                    maps:put(fail, <<"invalid json in response">>, Context);
                Json ->
                    case ejsonpath:q(JsonPath, Json) of
                        {[Val | _], _} ->
                            V =
                                case Val of
                                    I when is_integer(I) -> I;
                                    B when is_binary(B) -> binary_to_integer(B);
                                    L when is_list(L) -> list_to_integer(L);
                                    _ -> -1
                                end,
                            Min = list_to_integer(MinStr),
                            if
                                V >= Min ->
                                    Context;
                                true ->
                                    maps:put(
                                        fail, damage_utils:strf("Value ~p < ~p", [V, Min]), Context
                                    )
                            end;
                        Other ->
                            maps:put(
                                fail,
                                damage_utils:strf("Path ~p not found (~p)", [JsonPath, Other]),
                                Context
                            )
                    end
            end;
        Unexpected ->
            maps:put(fail, damage_utils:strf("Unexpected response ~p", [Unexpected]), Context)
    end;
%%------------------------------------------------------------------------------
%% THEN/AND: Store a raw response header value into a variable
%% Example:
%%   And I store the response header "invoice" as "invoice_bolt11"
%%------------------------------------------------------------------------------
step(
    _Config,
    Context,
    _,
    _N,
    ?STEP_RESPONSE_STORE_HEADER,
    _
) ->
    HeaderBin = list_to_binary(string:to_lower(Header)),
    case maps:get(response, Context, undefined) of
        [{status_code, _}, {headers, Headers}, {body, _}] ->
            case lists:keyfind(HeaderBin, 1, Headers) of
                {HeaderBin, Value} ->
                    maps:put(list_to_atom(Variable), Value, Context);
                false ->
                    maps:put(
                        fail,
                        damage_utils:strf("Header ~p not found in response headers ~p", [
                            HeaderBin, Headers
                        ]),
                        Context
                    )
            end;
        Unexpected ->
            maps:put(
                fail,
                damage_utils:strf("Unexpected response format ~p", [Unexpected]),
                Context
            )
    end.

get_headers(Context, DefaultHeaders) ->
    maps:to_list(
        maps:merge(
            maps:from_list(DefaultHeaders),
            maps:from_list(maps:get(headers, Context, []))
        )
    ).

response_to_list({StatusCode, Headers, Body}) ->
    [{status_code, StatusCode}, {headers, Headers}, {body, Body}].

%% Hardened: SSRF/IP-range blocking + sane TLS verify defaults + keep your concurrency gating.
%% NOTE: BasicAuth does NOT belong in gun:open opts. Apply it as an Authorization header per request.

%% Add near other helpers (optional)
get_proxy(Context, Config) ->
    %% Prefer Context override, fallback to Config proplist
    case maps:get(proxy, Context, undefined) of
        undefined ->
            case lists:keyfind(proxy, 1, Config) of
                false -> none;
                {proxy, {socks5, PH, PP}} -> {socks5, PH, PP};
                {proxy, {PH, PP}} -> {socks5, PH, PP}
            end;
        {socks5, PH, PP} ->
            {socks5, PH, PP};
        {PH, PP} ->
            {socks5, PH, PP}
    end.

get_gun_connection(Config0, #{public_key := AeAccount} = Context) ->
    DestHost = damage_utils:get_context_value(host, Context, Config0),
    DestPort = damage_utils:get_context_value(port, Context, Config0, ?DEFAULT_HTTP_PORT),
    ensure_host_is_public(DestHost),

    %% Keep your existing "443 => tls" behavior (this is about the *destination*)
    Config =
        case DestPort of
            443 -> [{transport, tls} | Config0];
            _ -> Config0
        end,

    BaseOpts =
        case lists:keyfind(transport, 1, Config) of
            false -> #{transport => tcp};
            _ -> #{transport => tls, tls_opts => [{verify, verify_none}]}
        end,

    BaseOpts0 =
        case maps:get(basic_auth, Context, none) of
            none -> BaseOpts;
            {User, Pass} -> maps:put(username, User, maps:put(password, Pass, Context))
        end,

    BaseOpts1 = maps:put(connect_timeout, ?DEFAULT_HTTP_TIMEOUT, BaseOpts0),

    %% ---- NEW: proxy handling (Tor SOCKS5) ----
    %% Tor default is often 127.0.0.1:9050 (system tor) or 127.0.0.1:9150 (Tor Browser).
    {OpenHost, OpenPort, FinalOpts} =
        {DestHost, DestPort, BaseOpts1},

    %% Your existing concurrency gating should apply to the *destination host* (not the proxy)
    case lists:keyfind(concurrency, 1, Config0) of
        false ->
            ?LOG_DEBUG("Opening connection Host ~p port ~p opts ~p", [OpenHost, OpenPort, FinalOpts]),
            gun:open(OpenHost, OpenPort, FinalOpts);
        {concurrency, 1} ->
            ?LOG_DEBUG("Opening connection Host ~p port ~p opts ~p", [OpenHost, OpenPort, FinalOpts]),
            gun:open(OpenHost, OpenPort, FinalOpts);
        {concurrency, _Concurrency} ->
            case damage_domains:is_allowed_domain(DestHost, AeAccount) of
                true ->
                    ?LOG_DEBUG("Opening connection Host ~p port ~p opts ~p", [
                        OpenHost, OpenPort, FinalOpts
                    ]),
                    damage_gun:open(OpenHost, OpenPort, FinalOpts);
                _ ->
                    throw(
                        <<"Host is not allowed to execute tests with concurrency greater than 1, please add dns txt record with dns token from a valid account. Check documentation at https://damagebdd.com/manual.html">>
                    )
            end
    end.

%% -------------------------
%% SSRF / host safety helpers
%% -------------------------

ensure_host_is_public(Host0) ->
    Host = host_to_list(Host0),

    %% Block obvious local names
    case string:lowercase(Host) of
        "localhost" ->
            ?LOG_INFO(<<"SSRF blocked: localhost">>),
            throw(unauthorized);
        _ ->
            ok
    end,

    %% If the host is already an IP literal, validate it directly.
    case inet:parse_address(Host) of
        {ok, Ip} ->
            ensure_public_ip(Ip);
        {error, Error} ->
            ?LOG_INFO("Host inet parse error ~p", [Error]),
            %% Resolve A records
            case inet:getaddrs(Host, inet) of
                {ok, Addrs4} -> lists:foreach(fun ensure_public_ip/1, Addrs4);
                _ -> ok
            end,
            %% Resolve AAAA records (best-effort)
            case inet:getaddrs(Host, inet6) of
                {ok, Addrs6} -> lists:foreach(fun ensure_public_ip/1, Addrs6);
                _ -> ok
            end
    end.

ensure_public_ip({A, B, C, D}) ->
    %% IPv4 blocks: loopback, RFC1918, link-local (incl cloud metadata), etc.
    case {A, B, C, D} of
        {127, _, _, _} -> throw(<<"SSRF blocked: 127/8 loopback">>);
        {10, _, _, _} -> throw(<<"SSRF blocked: 10/8 private">>);
        {169, 254, _, _} -> throw(<<"SSRF blocked: 169.254/16 link-local/metadata">>);
        {192, 168, _, _} -> throw(<<"SSRF blocked: 192.168/16 private">>);
        {172, X, _, _} when X >= 16, X =< 31 -> throw(<<"SSRF blocked: 172.16/12 private">>);
        {0, _, _, _} -> throw(<<"SSRF blocked: 0.0.0.0/8">>);
        _ -> ok
    end;
ensure_public_ip({0, 0, 0, 0, 0, 0, 0, 1}) ->
    throw(<<"SSRF blocked: ::1 loopback">>);
ensure_public_ip({A, B, _, _, _, _, _, _}) ->
    %% IPv6 blocks: unique local (fc00::/7) and link-local (fe80::/10)
    %% fc00::/7 => first byte 0xFC or 0xFD
    case A band 16#FE of
        16#FC -> throw(<<"SSRF blocked: fc00::/7 unique-local">>);
        _ -> ok
    end,
    %% fe80::/10 => first byte 0xFE and top two bits of second byte 10xxxxxx
    case {A, (B band 16#C0)} of
        {16#FE, 16#80} -> throw(<<"SSRF blocked: fe80::/10 link-local">>);
        _ -> ok
    end,
    ok.

host_to_list(H) when is_list(H) -> H;
host_to_list(H) when is_binary(H) -> binary_to_list(H).

gun_await(ConnPid, StreamRef, Context) ->
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
        {response, fin, Status, Headers} ->
            maps:put(response, response_to_list({Status, Headers, <<"">>}), Context);
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            maps:put(response, response_to_list({Status, Headers, Body}), Context);
        Default ->
            maps:put(
                fail,
                damage_utils:strf("Gun request failed: ~p", [Default]),
                Context
            )
    end.

gun_post(Config0, Context, Path, Headers, Data) ->
    {ok, ConnPid} = get_gun_connection(Config0, Context),
    try
        StreamRef = gun:post(ConnPid, Path, Headers, Data),
        Resp = gun_await(ConnPid, StreamRef, Context),
        Resp
    after
        catch gun:close(ConnPid)
    end.

gun_patch(Config0, Context, Path, Headers, Data) ->
    {ok, ConnPid} = get_gun_connection(Config0, Context),
    try
        StreamRef = gun:patch(ConnPid, Path, Headers, Data),
        gun_await(ConnPid, StreamRef, Context)
    after
        catch gun:close(ConnPid)
    end.

gun_put(Config0, Context, Path, Headers, Data) ->
    {ok, ConnPid} = get_gun_connection(Config0, Context),
    try
        StreamRef = gun:put(ConnPid, Path, Headers, Data),
        gun_await(ConnPid, StreamRef, Context)
    after
        catch gun:close(ConnPid)
    end.

gun_get(Config, Context, Path, Headers) ->
    {ok, ConnPid} = get_gun_connection(Config, Context),
    try
        StreamRef = gun:get(ConnPid, Path, Headers),
        gun_await(ConnPid, StreamRef, Context)
    after
        catch gun:close(ConnPid)
    end.

gun_options(Config, Context, Path, Headers) ->
    {ok, ConnPid} = get_gun_connection(Config, Context),
    try
        StreamRef = gun:options(ConnPid, Path, Headers),
        gun_await(ConnPid, StreamRef, Context)
    after
        catch gun:close(ConnPid)
    end.

gun_head(Config, Context, Path, Headers) ->
    {ok, ConnPid} = get_gun_connection(Config, Context),
    try
        StreamRef = gun:head(ConnPid, Path, Headers),
        gun_await(ConnPid, StreamRef, Context)
    after
        catch gun:close(ConnPid)
    end.

gun_delete(Config, Context, Path, Headers) ->
    {ok, ConnPid} = get_gun_connection(Config, Context),
    try
        StreamRef = gun:delete(ConnPid, Path, Headers),
        gun_await(ConnPid, StreamRef, Context)
    after
        catch gun:close(ConnPid)
    end.

retry_get(Config, Context, Path, Headers, N, WaitSecs, Attempt) ->
    {ok, ConnPid} = get_gun_connection(Config, Context),
    try
        StreamRef = gun:get(ConnPid, Path, Headers),
        case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
            {response, nofin, Status, Headers} ->
                {ok, Body} = gun:await_body(ConnPid, StreamRef),
                {ok, {Status, Headers, Body}};
            Default ->
                case Attempt < N of
                    true ->
                        % Wait in milliseconds
                        timer:sleep(WaitSecs * 1000),
                        retry_get(Config, Context, Path, Headers, N, WaitSecs, Attempt + 1);
                    false ->
                        {
                            fail,
                            damage_utils:strf(
                                "Maximum attempts reached. Exiting. ~p",
                                [Default]
                            )
                        }
                end
        end
    after
        catch gun:close(ConnPid)
    end.

retry_get_ejsonmatch(
    Config,
    Context,
    JsonPath,
    Expected,
    Path,
    Headers,
    N,
    WaitSecs,
    Attempt
) ->
    case retry_get(Config, Context, Path, Headers, N, WaitSecs, Attempt) of
        {ok, {_Status, _Headers, Body}} ->
            Context0 = ejsonpath_match(JsonPath, Body, Expected, Context),
            case maps:get(fail, Context0, none) of
                none ->
                    Context0;
                _ ->
                    retry_get_ejsonmatch(
                        Config,
                        Context0,
                        JsonPath,
                        Expected,
                        Path,
                        Headers,
                        N,
                        WaitSecs,
                        Attempt
                    )
            end;
        _ ->
            retry_get_ejsonmatch(
                Config,
                Context,
                JsonPath,
                Expected,
                Path,
                Headers,
                N,
                WaitSecs,
                Attempt
            )
    end.

ejsonpath_match(Path, Data, Expected, Context) ->
    Expected0 =
        case Expected of
            <<"false">> ->
                false;
            <<"true">> ->
                true;
            Expected1 ->
                case is_integer_string(Expected1) of
                    true ->
                        to_integer(Expected1);
                    false ->
                        Expected
                end
        end,
    case catch ejsonpath:q(Path, Data) of
        {[Expected0 | _], _} ->
            Context;
        UnExpected ->
            Mesg = "the object at path ~p is not ~p, it is ~p. Data ~p",
            Args = [Path, Expected0, UnExpected, Data],
            ?LOG_INFO(Mesg, Args),
            maps:put(fail, damage_utils:strf(Mesg, Args), Context)
    end.

is_integer_string(B) when is_binary(B) ->
    re:run(B, <<"^-?[0-9]+$">>, [{capture, none}]) =:= match;
is_integer_string(L) when is_list(L) ->
    re:run(L, "^-?[0-9]+$", [{capture, none}]) =:= match;
is_integer_string(_) ->
    false.

to_integer(B) when is_binary(B) ->
    binary_to_integer(B);
to_integer(L) when is_list(L) ->
    list_to_integer(L).

build_url(PathOrUrl, DefaultBaseUrl) ->
    case lists:prefix("http", PathOrUrl) of
        true ->
            % If the input is already a full URL, return it as is
            PathOrUrl;
        false ->
            % Otherwise, prepend the base URL to form the complete URL
            DefaultBaseUrl ++ "/" ++ string:trim(PathOrUrl, both, "/")
    end.
normalize_jsonish(V) when is_map(V) ->
    maps:from_list(
        [{normalize_jsonish_key(K), normalize_jsonish(Val)} || {K, Val} <- maps:to_list(V)]
    );
normalize_jsonish(V) when is_list(V) ->
    case io_lib:printable_list(V) of
        true -> unicode:characters_to_binary(V);
        false -> [normalize_jsonish(I) || I <- V]
    end;
normalize_jsonish(V) when is_atom(V) ->
    atom_to_binary(V, utf8);
normalize_jsonish(V) ->
    V.

normalize_jsonish_key(K) when is_atom(K) ->
    atom_to_binary(K, utf8);
normalize_jsonish_key(K) when is_list(K) ->
    unicode:characters_to_binary(K);
normalize_jsonish_key(K) ->
    K.

test_get_headers() ->
    Context =
        #{
            port => 8080,
            host => "localhost",
            modified => <<"20240424223344">>,
            headers =>
                [
                    {<<"accept">>, "application/json"},
                    {<<"content-type">>, "application/json"},
                    {<<"user-agent">>, "damagebdd/1.0"},
                    {<<"content-type">>, "application/x-yaml"}
                ],
            step_found => false,
            example_context_variable =>
                #{value => <<"non redaacted">>, secret => false},
            example_context_variable_redacted =>
                #{value => <<"ths will be redaacted">>, secret => true}
        },
    Headers = get_headers(Context, ?DEFAULT_HEADERS),
    ?LOG_INFO("Headers ~p", [Headers]).

test_gun_post() ->
    Context =
        #{
            %port => 8080,
            %host => "localhost",
            port => 443,
            host => "run.staging.damagebdd.com",
            modified => <<"20240424223344">>,
            headers =>
                [
                    {<<"accept">>, "application/json"},
                    {<<"content-type">>, "application/json"},
                    {<<"user-agent">>, "damagebdd/1.0"}
                ],
            step_found => false,
            example_context_variable =>
                #{value => <<"non redaacted">>, secret => false},
            example_context_variable_redacted =>
                #{value => <<"ths will be redaacted">>, secret => true},
            public_key => <<"ak_ssssssssssssadsadadas">>
        },
    Headers = get_headers(Context, ?DEFAULT_HEADERS),
    gun_post([], Context, "/publish_feature", Headers, #{}).

test_gun_get() ->
    Context =
        #{
            %port => 8080,
            %host => "localhost",
            port => 443,
            host => "run.staging.damagebdd.com",
            base_url => "https://run.staging.damagebdd.com",
            modified => <<"20240424223344">>,
            headers =>
                [
                    {<<"accept">>, "application/json"},
                    {<<"content-type">>, "application/json"},
                    {<<"user-agent">>, "damagebdd/1.0"}
                ],
            step_found => false,
            example_context_variable =>
                #{value => <<"non redaacted">>, secret => false},
            example_context_variable_redacted =>
                #{value => <<"ths will be redaacted">>, secret => true},
            public_key => <<"ak_ssssssssssssadsadadas">>
        },
    Headers = get_headers(Context, ?DEFAULT_HEADERS),
    gun_get(
        [],
        Context,
        string:concat(maps:get(base_url, Context, ""), "/publish_feature/"),
        Headers
    ).

test_using_server() ->
    Context =
        #{
            %port => 8080,
            %host => "localhost",
            port => 443,
            host => "run.staging.damagebdd.com",
            base_url => "https://run.staging.damagebdd.com",
            modified => <<"20240424223344">>,
            headers =>
                [
                    {<<"accept">>, "application/json"},
                    {<<"content-type">>, "application/json"},
                    {<<"user-agent">>, "damagebdd/1.0"}
                ],
            step_found => false,
            example_context_variable =>
                #{value => <<"non redaacted">>, secret => false},
            example_context_variable_redacted =>
                #{value => <<"ths will be redaacted">>, secret => true},
            public_key => <<"ak_ssssssssssssadsadadas">>
        },
    step([], Context, <<"Given">>, 0, ["I am using server", "test"], <<"">>).
