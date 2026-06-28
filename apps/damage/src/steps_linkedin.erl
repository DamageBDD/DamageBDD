%% -------------------------------------------------------------------
%% steps_linkedin.erl - DamageBDD steps for LinkedIn API verification
%% -------------------------------------------------------------------
-module(steps_linkedin).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6]).
-export([step_dry/6]).

-define(DEFAULT_HOST, "api.linkedin.com").
-define(DEFAULT_PORT, 443).
-define(DEFAULT_VERSION, <<"202606">>).
-define(DEFAULT_HTTP_TIMEOUT, 30000).

-define(STEP_SET_VERSION, ["I set LinkedIn API version to", Version]).
-define(STEP_SET_TOKEN, ["I set LinkedIn OAuth token to", Token]).
-define(STEP_SET_TOKEN_SECRET, ["I set LinkedIn OAuth token from secret", SecretName]).
-define(STEP_SET_AUTHOR, ["I set LinkedIn author URN to", AuthorUrn]).
-define(STEP_GET_USERINFO, ["I get my LinkedIn OpenID profile"]).
-define(STEP_GET_PATH, ["I GET LinkedIn path", Path]).
-define(STEP_POST_PATH, ["I POST LinkedIn path", Path]).
-define(STEP_CREATE_TEXT_POST_AUTHOR, ["I create a LinkedIn text post for author", AuthorUrn]).
-define(STEP_CREATE_TEXT_POST_CONFIGURED, ["I create a LinkedIn text post from the configured author"]).
-define(STEP_LOOKUP_ORG_VANITY, ["I lookup LinkedIn organization by vanity name", VanityName]).
-define(STEP_STATUS_MUST, ["the LinkedIn response status must be", Status]).
-define(STEP_STORE_HEADER, ["I store the LinkedIn response header", Header, "in", Variable]).
-define(STEP_STORE_JSON, ["I store the LinkedIn JSON at path", JsonPath, "in", Variable]).
-define(STEP_JSON_MUST, ["the LinkedIn JSON at path", JsonPath, "must be", Expected]).
-define(STEP_PRINT_RESPONSE, ["I print the LinkedIn response"]).

%% -------------------------------------------------------------------
%% Dry run clauses. Keep exact clauses only: no catch-all step matcher.
%% -------------------------------------------------------------------
step_dry(Config, Context, Keyword, LineNo, ?STEP_SET_VERSION = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_SET_TOKEN = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_SET_TOKEN_SECRET = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_SET_AUTHOR = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_GET_USERINFO = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_GET_PATH = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_POST_PATH = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_CREATE_TEXT_POST_AUTHOR = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_CREATE_TEXT_POST_CONFIGURED = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_LOOKUP_ORG_VANITY = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_STATUS_MUST = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_STORE_HEADER = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_STORE_JSON = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_JSON_MUST = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args);
step_dry(Config, Context, Keyword, LineNo, ?STEP_PRINT_RESPONSE = Args, Body) ->
    steps_utils:step_dry(Config, Context, Keyword, LineNo, Body, Args).

%% -------------------------------------------------------------------
%% Given: LinkedIn client configuration
%% -------------------------------------------------------------------
step(_Config, Context, _Keyword, _N, ?STEP_SET_VERSION, _Body) ->
    maps:put(linkedin_version, to_bin(Version), Context);
step(_Config, Context, _Keyword, _N, ?STEP_SET_TOKEN, _Body) ->
    maps:put(linkedin_access_token, resolve_value(Context, Token), Context);
step(_Config, Context, _Keyword, _N, ?STEP_SET_TOKEN_SECRET, _Body) ->
    case read_secret(SecretName) of
        {ok, Token} -> maps:put(linkedin_access_token, to_bin(Token), Context);
        {error, Reason} -> fail(Context, "LinkedIn OAuth token secret lookup failed: ~p", [Reason])
    end;
step(_Config, Context, _Keyword, _N, ?STEP_SET_AUTHOR, _Body) ->
    maps:put(linkedin_author_urn, to_bin(AuthorUrn), Context);

%% -------------------------------------------------------------------
%% When: LinkedIn API calls
%% -------------------------------------------------------------------
step(_Config, Context, <<"When">>, _N, ?STEP_GET_USERINFO, _Body) ->
    linkedin_get(Context, "/v2/userinfo", []);
step(_Config, Context, <<"When">>, _N, ?STEP_GET_PATH, _Body) ->
    linkedin_get(Context, Path, []);
step(_Config, Context, <<"When">>, _N, ?STEP_POST_PATH, Body) ->
    linkedin_post(Context, Path, Body, []);
step(_Config, Context, <<"When">>, _N, ?STEP_CREATE_TEXT_POST_AUTHOR, Body) ->
    create_text_post(Context, to_bin(AuthorUrn), Body);
step(_Config, Context, <<"When">>, _N, ?STEP_CREATE_TEXT_POST_CONFIGURED, Body) ->
    case maps:get(linkedin_author_urn, Context, undefined) of
        undefined -> fail(Context, "LinkedIn author URN is not configured", []);
        AuthorUrn -> create_text_post(Context, AuthorUrn, Body)
    end;
step(_Config, Context, <<"When">>, _N, ?STEP_LOOKUP_ORG_VANITY, _Body) ->
    Vanity = uri_string:quote(to_list(resolve_value(Context, VanityName))),
    Path = "/rest/organization?q=vanityName&vanityName=" ++ Vanity,
    linkedin_get(Context, Path, []);

%% -------------------------------------------------------------------
%% Then: LinkedIn assertions and extraction
%% -------------------------------------------------------------------
step(_Config, Context, <<"Then">>, _N, ?STEP_STATUS_MUST, _Body) ->
    Expected = to_int(Status),
    case maps:get(response, Context, undefined) of
        [{status_code, Expected}, _Headers, _Body] ->
            Context;
        [{status_code, Actual}, _Headers, {body, Body}] ->
            fail(Context, "LinkedIn response status is not ~p, got ~p: ~s", [Expected, Actual, Body]);
        Unexpected ->
            fail(Context, "Unexpected LinkedIn response while checking status ~p: ~p", [Expected, Unexpected])
    end;
step(_Config, Context, <<"Then">>, _N, ?STEP_STORE_HEADER, _Body) ->
    case maps:get(response, Context, undefined) of
        [{status_code, _}, {headers, Headers}, _] ->
            case get_header(Header, Headers) of
                undefined -> fail(Context, "LinkedIn response header ~p was not found", [Header]);
                Value -> store_var(Variable, to_bin(Value), Context)
            end;
        Unexpected ->
            fail(Context, "Unexpected LinkedIn response while storing header: ~p", [Unexpected])
    end;
step(_Config, Context, <<"Then">>, _N, ?STEP_STORE_JSON, _Body) ->
    case response_json(Context) of
        {ok, Json} ->
            case json_path(JsonPath, Json) of
                {ok, Value} -> store_var(Variable, json_value_to_context(Value), Context);
                {error, Reason} -> fail(Context, "LinkedIn JSON path lookup failed: ~p", [Reason])
            end;
        {error, Reason} ->
            fail(Context, "LinkedIn response JSON decode failed: ~p", [Reason])
    end;
step(_Config, Context, <<"Then">>, _N, ?STEP_JSON_MUST, _Body) ->
    case response_json(Context) of
        {ok, Json} ->
            ExpectedValue = expected_json_value(Expected),
            case json_path(JsonPath, Json) of
                {ok, ExpectedValue} -> Context;
                {ok, Actual} ->
                    fail(Context, "LinkedIn JSON at path ~p is not ~p, got ~p", [JsonPath, ExpectedValue, Actual]);
                {error, Reason} ->
                    fail(Context, "LinkedIn JSON path lookup failed: ~p", [Reason])
            end;
        {error, Reason} ->
            fail(Context, "LinkedIn response JSON decode failed: ~p", [Reason])
    end;
step(Config, Context, <<"Then">>, N, ?STEP_PRINT_RESPONSE, _Body) ->
    Response = maps:get(response, Context, undefined),
    formatter:format(
        Config,
        print,
        {<<"Then">>, N, ["LinkedIn response:"], jsx:encode(normalize_json(Response)), Context, success}
    ),
    Context.

%% -------------------------------------------------------------------
%% LinkedIn request helpers
%% -------------------------------------------------------------------
create_text_post(Context, AuthorUrn, Body) ->
    Text = to_bin(Body),
    Payload = #{
        author => AuthorUrn,
        commentary => Text,
        visibility => <<"PUBLIC">>,
        distribution => #{
            feedDistribution => <<"MAIN_FEED">>,
            targetEntities => [],
            thirdPartyDistributionChannels => []
        },
        lifecycleState => <<"PUBLISHED">>,
        isReshareDisabledByAuthor => false
    },
    linkedin_post(Context, "/rest/posts", jsx:encode(Payload), []).

linkedin_get(Context, Path, ExtraHeaders) ->
    linkedin_request(get, Context, Path, <<>>, ExtraHeaders).

linkedin_post(Context, Path, Body, ExtraHeaders) ->
    linkedin_request(post, Context, Path, Body, ExtraHeaders).

linkedin_request(Method, Context, Path0, Body, ExtraHeaders) ->
    case ensure_token(Context) of
        {ok, Token} ->
            Headers = linkedin_headers(Context, Token, ExtraHeaders),
            Path = normalize_path(Path0),
            Opts = #{
                transport => tls,
                tls_opts => damage_gun:tls_opts(?DEFAULT_HOST),
                proxy => direct,
                protocols => [http],
                connect_timeout => ?DEFAULT_HTTP_TIMEOUT,
                timeout => ?DEFAULT_HTTP_TIMEOUT,
                close => true,
                decode => raw
            },
            Result =
                case Method of
                    get -> damage_gun:get(?DEFAULT_HOST, ?DEFAULT_PORT, Path, Headers, Opts);
                    post -> damage_gun:post(?DEFAULT_HOST, ?DEFAULT_PORT, Path, Headers, Body, Opts)
                end,
            store_response(Result, Context);
        {error, Reason} ->
            fail(Context, "LinkedIn OAuth token missing: ~p", [Reason])
    end.

linkedin_headers(Context, Token, ExtraHeaders) ->
    Version = maps:get(linkedin_version, Context, ?DEFAULT_VERSION),
    Defaults = [
        {<<"Authorization">>, <<"Bearer ", (to_bin(Token))/binary>>},
        {<<"Accept">>, <<"application/json">>},
        {<<"Content-Type">>, <<"application/json">>},
        {<<"Linkedin-Version">>, to_bin(Version)},
        {<<"X-Restli-Protocol-Version">>, <<"2.0.0">>},
        {<<"User-Agent">>, <<"damagebdd/1.0">>}
    ],
    maps:to_list(
        maps:merge(
            maps:from_list(Defaults),
            maps:merge(maps:from_list(context_headers(Context)), maps:from_list(ExtraHeaders))
        )
    ).

context_headers(Context) ->
    case maps:get(headers, Context, []) of
        Map when is_map(Map) -> maps:to_list(Map);
        List when is_list(List) -> List;
        _ -> []
    end.

store_response({ok, #{status := Status, headers := Headers, body := Body}}, Context) ->
    maps:put(response, response_to_list({Status, Headers, Body}), Context);
store_response({ok, #{status := Status, headers := Headers}}, Context) ->
    maps:put(response, response_to_list({Status, Headers, <<>>}), Context);
store_response({error, Reason}, Context) ->
    fail(Context, "LinkedIn request failed: ~p", [Reason]).

response_to_list({StatusCode, Headers, Body}) ->
    [{status_code, StatusCode}, {headers, Headers}, {body, Body}].

ensure_token(Context) ->
    case maps:get(linkedin_access_token, Context, undefined) of
        undefined -> {error, not_configured};
        <<>> -> {error, empty};
        Token -> {ok, to_bin(Token)}
    end.

normalize_path(Path0) ->
    Path = to_list(Path0),
    case Path of
        [$h, $t, $t, $p | _] ->
            case uri_string:parse(Path) of
                #{path := P, query := Q} -> P ++ "?" ++ Q;
                #{path := P} -> P;
                _ -> Path
            end;
        [$/ | _] ->
            Path;
        _ ->
            "/" ++ Path
    end.

%% -------------------------------------------------------------------
%% JSON and header helpers
%% -------------------------------------------------------------------
response_json(Context) ->
    case maps:get(response, Context, undefined) of
        [{status_code, _}, _Headers, {body, Body}] ->
            try jsx:decode(Body, [return_maps]) of
                Json -> {ok, Json}
            catch
                Class:Reason -> {error, {Class, Reason, Body}}
            end;
        Unexpected ->
            {error, {unexpected_response, Unexpected}}
    end.

json_path(Path, Json) ->
    case catch ejsonpath:q(to_bin(Path), Json) of
        {[Value | _], _} -> {ok, Value};
        {[], _} -> {error, {not_found, Path}};
        {'EXIT', Reason} -> {error, Reason};
        Other -> {error, {unexpected_path_result, Other}}
    end.

expected_json_value(Value0) ->
    Value = to_bin(Value0),
    case Value of
        <<"true">> -> true;
        <<"false">> -> false;
        <<"null">> -> null;
        _ ->
            case catch jsx:decode(Value, [return_maps]) of
                {'EXIT', _} -> maybe_int(Value);
                Json -> Json
            end
    end.

maybe_int(Value) when is_binary(Value) ->
    case catch binary_to_integer(Value) of
        I when is_integer(I) -> I;
        _ -> Value
    end.

json_value_to_context(Value) when is_binary(Value) -> Value;
json_value_to_context(Value) when is_integer(Value) -> integer_to_binary(Value);
json_value_to_context(Value) when is_float(Value) -> list_to_binary(io_lib:format("~p", [Value]));
json_value_to_context(Value) when is_boolean(Value) -> atom_to_binary(Value, utf8);
json_value_to_context(null) -> <<"null">>;
json_value_to_context(Value) -> jsx:encode(Value).

get_header(Header0, Headers) ->
    Header = lower_bin(Header0),
    case [V || {K, V} <- Headers, lower_bin(K) =:= Header] of
        [Value | _] -> Value;
        [] -> undefined
    end.

normalize_json(Map) when is_map(Map) ->
    maps:from_list([{to_bin(K), normalize_json(V)} || {K, V} <- maps:to_list(Map)]);
normalize_json(List) when is_list(List) ->
    [normalize_json(V) || V <- List];
normalize_json(Tuple) when is_tuple(Tuple) ->
    normalize_json(tuple_to_list(Tuple));
normalize_json(V) ->
    V.

%% -------------------------------------------------------------------
%% Context, secret, and conversion helpers
%% -------------------------------------------------------------------
store_var(Variable0, Value, Context) ->
    Variable = to_bin(Variable0),
    maps:put(binary_to_list(Variable), Value, maps:put(Variable, Value, Context)).

resolve_value(Context, Value0) ->
    Value = to_bin(Value0),
    case Value of
        <<"{{", Inner/binary>> ->
            case binary:split(Inner, <<"}}">>, [global]) of
                [Var, _Rest] ->
                    maps:get(
                        binary_to_list(Var),
                        Context,
                        maps:get(Var, Context, Value)
                    );
                _ ->
                    Value
            end;
        _ ->
            Value
    end.

read_secret(Name0) ->
    Name = to_bin(Name0),
    Candidates =
        case existing_atom(Name) of
            {ok, Atom} -> [Atom, Name];
            error -> [Name]
        end,
    read_secret_candidates(Candidates).

read_secret_candidates([]) ->
    {error, not_found};
read_secret_candidates([Key | Rest]) ->
    case secrets:retrieve_decrypt(Key) of
        {ok, Value} -> {ok, Value};
        _ -> read_secret_candidates(Rest)
    end.

existing_atom(Bin) ->
    try
        {ok, binary_to_existing_atom(Bin, utf8)}
    catch
        _:_ -> error
    end.

fail(Context, Format, Args) ->
    maps:put(fail, damage_utils:strf(Format, Args), Context).

to_int(V) when is_integer(V) -> V;
to_int(V) when is_binary(V) -> binary_to_integer(V);
to_int(V) when is_list(V) -> list_to_integer(V).

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_integer(V) -> integer_to_binary(V);
to_bin(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])). 

to_list(V) when is_list(V) -> V;
to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) -> binary_to_list(to_bin(V)).

lower_bin(V) ->
    list_to_binary(string:lowercase(to_list(V))).
