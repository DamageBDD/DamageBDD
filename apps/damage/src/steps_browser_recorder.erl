%%%-------------------------------------------------------------------
%%% DamageBDD recorder: W3C WebDriver-backed replay steps.
%%%
%%% Configure using proplists / sys.config tuples:
%%%   {browser_recorder_webdriver_url, "http://127.0.0.1:4444"}
%%%   {browser_recorder_browser, "chrome"} %% or "firefox"
%%%
%%% A browser session is scoped to the current DamageBDD scenario context.
%%% Credentials are retrieved from secrets by key and never copied into
%%% the context, logs, Gherkin or error messages.
%%%-------------------------------------------------------------------
-module(steps_browser_recorder).
-author("DamageBDD").
-license("Apache-2.0").
-export([step/6, step_dry/6]).
-include_lib("kernel/include/logger.hrl").

-define(SESS, browser_recorder_session).
-define(START, ["I start a recorded browser at", Url]).
-define(NAVIGATE, ["I navigate the recorded browser to", Url]).
-define(CLICK, ["I click recorded element", Selector]).
-define(FILL, ["I type into recorded field", Selector]).
-define(SECRET, ["I type secret", SecretName, "into recorded field", Selector]).
-define(SELECT, ["I select recorded option in", Selector]).
-define(CHECK, ["I set recorded checkbox", Selector, "to checked"]).
-define(UNCHECK, ["I set recorded checkbox", Selector, "to unchecked"]).
-define(PRESS, ["I press Enter in recorded field", Selector]).
-define(TEXT, ["recorded element", Selector, "should contain text"]).
-define(URL, ["the recorded browser URL should start with", ExpectedUrl]).
-define(CLOSE, ["I close the recorded browser"]).
-define(ELEMENT_KEY, <<"element-6066-11e4-a52e-4f735466cecf">>).
-define(TIMEOUT_MS, 10000).

%% Dry-run clauses must match only our step vocabulary; an unconditional
%% fallback would swallow all other DamageBDD steps during dry run.
step_dry(Cfg, Ctx, K, N, ?START = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?NAVIGATE = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?CLICK = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?FILL = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?SECRET = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?SELECT = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?CHECK = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?UNCHECK = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?PRESS = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?TEXT = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?URL = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body);
step_dry(Cfg, Ctx, K, N, ?CLOSE = Parts, Body) -> dry(Cfg,Ctx,K,N,Parts,Body).

dry(Cfg, Ctx, K, N, Parts, Body) ->
    steps_utils:step_dry(Cfg, Ctx, K, N, Parts, Body).

step(Cfg, Ctx, _K, _N, ?START, _Body) ->
    handle(Ctx, fun() ->
        {ok, UrlBin} = allowed_url(Url),
        {ok, Session} = new_session(Cfg),
        case navigate(Cfg, Session, UrlBin) of
            ok -> {ok, Ctx#{?SESS => Session}};
            Error -> _ = close(Cfg, Session), Error
        end
    end);
step(Cfg, Ctx, _K, _N, ?NAVIGATE, _Body) ->
    with_session(Cfg, Ctx, fun(Session) ->
        {ok, UrlBin} = allowed_url(Url),
        navigate(Cfg, Session, UrlBin)
    end);
step(Cfg, Ctx, _K, _N, ?CLICK, _Body) ->
    with_session(Cfg, Ctx, fun(Session) ->
        with_element(Cfg, Session, Selector, fun(Element) ->
            no_value(Cfg, Session, post, ["element/", Element, "/click"], #{})
        end)
    end);
step(Cfg, Ctx, _K, _N, ?FILL, Body) ->
    with_session(Cfg, Ctx, fun(Session) ->
        fill(Cfg, Session, Selector, to_bin(Body))
    end);
step(Cfg, Ctx, _K, _N, ?SECRET, _Body) ->
    %% Return a generic error on secret failures; do not display returned data.
    with_session(Cfg, Ctx, fun(Session) ->
        case read_secret(SecretName) of
            {ok, Value} when is_binary(Value); is_list(Value) ->
                case fill(Cfg, Session, Selector, to_bin(Value)) of
                    ok -> ok;
                    _ -> {error, secret_input_failed}
                end;
            _ -> {error, missing_recorded_secret}
        end
    end);
step(Cfg, Ctx, _K, _N, ?SELECT, Body) ->
    with_session(Cfg, Ctx, fun(Session) ->
        with_element(Cfg, Session, Selector, fun(Element) ->
            select_option(Cfg, Session, Element, to_bin(Body))
        end)
    end);
step(Cfg, Ctx, _K, _N, ?CHECK, _Body) ->
    with_session(Cfg, Ctx, fun(Session) -> set_checked(Cfg, Session, Selector, true) end);
step(Cfg, Ctx, _K, _N, ?UNCHECK, _Body) ->
    with_session(Cfg, Ctx, fun(Session) -> set_checked(Cfg, Session, Selector, false) end);
step(Cfg, Ctx, _K, _N, ?PRESS, _Body) ->
    with_session(Cfg, Ctx, fun(Session) ->
        with_element(Cfg, Session, Selector, fun(Element) ->
            %% W3C WebDriver Enter key code
            no_value(Cfg, Session, post, ["element/",Element,"/value"],
                #{<<"text">> => <<16#EE,16#80,16#87>>})
        end)
    end);
step(Cfg, Ctx, _K, _N, ?TEXT, Body) ->
    with_session(Cfg, Ctx, fun(Session) ->
        with_element(Cfg, Session, Selector, fun(Element) ->
            case webdriver(Cfg, Session, get, ["element/",Element,"/text"], none) of
                {ok, Text} when is_binary(Text) ->
                    case binary:match(Text, to_bin(Body)) of
                        nomatch -> {error, recorded_text_not_found};
                        _ -> ok
                    end;
                Error -> Error
            end
        end)
    end);
step(Cfg, Ctx, _K, _N, ?URL, _Body) ->
    with_session(Cfg, Ctx, fun(Session) ->
        {ok, Prefix} = allowed_url(ExpectedUrl),
        wait_url(Cfg, Session, Prefix, erlang:monotonic_time(millisecond) + ?TIMEOUT_MS)
    end);
step(Cfg, Ctx, _K, _N, ?CLOSE, _Body) ->
    handle(Ctx, fun() ->
        case maps:find(?SESS, Ctx) of
            {ok, Session} ->
                case close(Cfg, Session) of
                    ok -> {ok, maps:remove(?SESS, Ctx)};
                    Error -> Error
                end;
            error -> {error, no_recorded_browser_session}
        end
    end).

handle(Ctx, Fun) ->
    try Fun() of
        {ok, Next} when is_map(Next) -> Next;
        ok -> Ctx;
        {error, Reason} -> fail(Ctx, Reason);
        Other -> fail(Ctx, {unexpected_browser_response, sanitize_error(Other)})
    catch
        _:{badmatch, {error, Reason}} -> fail(Ctx, Reason);
        Class:_Reason:_Stack -> fail(Ctx, {browser_step_failed, Class})
    end.

with_session(Cfg, Ctx, Fun) ->
    handle(Ctx, fun() ->
        case maps:find(?SESS, Ctx) of
            {ok, Session} -> Fun(Session);
            error -> {error, no_recorded_browser_session}
        end
    end).

fail(Ctx, Reason) ->
    ?LOG_WARNING("Recorder step failed: ~p", [sanitize_error(Reason)]),
    maps:put(fail, to_bin(io_lib:format("Recorded browser step failed: ~p", [sanitize_error(Reason)])), Ctx).

sanitize_error({http_status, Status, Reason}) -> {http_status, Status, Reason};
sanitize_error({webdriver_error, Reason}) -> {webdriver_error, Reason};
sanitize_error(E) when is_atom(E); is_integer(E) -> E;
sanitize_error(_) -> unknown_error.

read_secret(Name0) ->
    Name = to_bin(Name0),
    case secrets:retrieve_decrypt(Name) of
        {ok, Value} -> {ok, Value};
        _ ->
            try
                Atom = binary_to_existing_atom(Name, utf8),
                secrets:retrieve_decrypt(Atom)
            catch _:_ -> {error, not_found}
            end
    end.

config(Cfg, Key, Default) ->
    proplists:get_value(Key, Cfg, application:get_env(damage, Key, Default)).

driver(Cfg) ->
    Raw = to_list(config(Cfg, browser_recorder_webdriver_url, "http://127.0.0.1:4444")),
    case uri_string:parse(Raw) of
        #{scheme := Scheme, host := Host} when (Scheme =:= "http" orelse Scheme =:= "https"), Host =/= "" ->
            string:trim(Raw, trailing, "/");
        _ -> erlang:error(invalid_webdriver_url)
    end.

new_session(Cfg) ->
    Browser = to_bin(config(Cfg, browser_recorder_browser, "chrome")),
    case lists:member(Browser, [<<"chrome">>, <<"firefox">>]) of
        false -> {error, invalid_browser_name};
        true ->
            Payload = #{<<"capabilities">> => #{<<"alwaysMatch">> => #{<<"browserName">> => Browser}}},
            case request(Cfg, post, "/session", Payload) of
                {ok, Result} when is_map(Result) ->
                    Value = maps:get(<<"value">>, Result, #{}),
                    SessionId = maps:get(<<"sessionId">>, Value, maps:get(<<"sessionId">>, Result, undefined)),
                    case SessionId of
                        Id when is_binary(Id), byte_size(Id) > 0 -> {ok, Id};
                        _ -> {error, missing_webdriver_session_id}
                    end;
                Error -> Error
            end
    end.

navigate(Cfg, Session, Url) ->
    no_value(Cfg, Session, post, ["url"], #{<<"url">> => Url}).

close(Cfg, Session) ->
    no_value(Cfg, Session, delete, [], none).

allowed_url(Url0) ->
    Url = to_bin(Url0),
    case uri_string:parse(Url) of
        #{scheme := Scheme, host := _} when Scheme =:= <<"http">>; Scheme =:= <<"https">> -> {ok, Url};
        #{scheme := Scheme, host := _} when Scheme =:= "http"; Scheme =:= "https" -> {ok, Url};
        _ -> {error, unsupported_browser_url}
    end.

with_element(Cfg, Session, Selector0, Fun) ->
    Selector = to_bin(Selector0),
    Deadline = erlang:monotonic_time(millisecond) + ?TIMEOUT_MS,
    case locate(Cfg, Session, Selector, Deadline) of
        {ok, Element} -> Fun(Element);
        Error -> Error
    end.

locate(Cfg, Session, Selector, Deadline) ->
    case webdriver(Cfg, Session, post, "element", #{<<"using">> => <<"css selector">>, <<"value">> => Selector}) of
        {ok, #{?ELEMENT_KEY := Element}} when is_binary(Element) -> {ok, Element};
        {ok, _} -> {error, missing_webdriver_element};
        Error ->
            case erlang:monotonic_time(millisecond) < Deadline andalso missing_element(Error) of
                true -> timer:sleep(200), locate(Cfg, Session, Selector, Deadline);
                false -> Error
            end
    end.

missing_element({error, {webdriver_error, <<"no such element">>}}) -> true;
missing_element(_) -> false.

fill(Cfg, Session, Selector, Text) ->
    with_element(Cfg, Session, Selector, fun(Element) ->
        case no_value(Cfg, Session, post, ["element/",Element,"/clear"], #{}) of
            ok -> no_value(Cfg, Session, post, ["element/",Element,"/value"], #{<<"text">> => Text});
            Error -> Error
        end
    end).

select_option(Cfg, Session, Element, Wanted) ->
    case webdriver(Cfg, Session, post, ["element/",Element,"/elements"],
        #{<<"using">> => <<"css selector">>, <<"value">> => <<"option">>}) of
        {ok, Options} when is_list(Options) -> choose_option(Cfg, Session, Options, Wanted);
        Error -> Error
    end.

choose_option(_Cfg, _Session, [], _Wanted) -> {error, recorded_option_not_found};
choose_option(Cfg, Session, [Option | Rest], Wanted) ->
    case maps:get(?ELEMENT_KEY, Option, undefined) of
        undefined -> choose_option(Cfg, Session, Rest, Wanted);
        Element ->
            Text = webdriver(Cfg, Session, get, ["element/",Element,"/text"], none),
            Attr = webdriver(Cfg, Session, get, ["element/",Element,"/attribute/value"], none),
            case Text =:= {ok, Wanted} orelse Attr =:= {ok, Wanted} of
                true -> no_value(Cfg, Session, post, ["element/",Element,"/click"], #{});
                false -> choose_option(Cfg, Session, Rest, Wanted)
            end
    end.

set_checked(Cfg, Session, Selector, Wanted) ->
    with_element(Cfg, Session, Selector, fun(Element) ->
        case webdriver(Cfg, Session, get, ["element/",Element,"/selected"], none) of
            {ok, Wanted} -> ok;
            {ok, Actual} when is_boolean(Actual) ->
                no_value(Cfg, Session, post, ["element/",Element,"/click"], #{});
            Error -> Error
        end
    end).

wait_url(Cfg, Session, Prefix, Deadline) ->
    case webdriver(Cfg, Session, get, "url", none) of
        {ok, Current} when is_binary(Current) ->
            case binary:match(Current, Prefix) of
                {0, _} -> ok;
                _ -> retry_url(Cfg, Session, Prefix, Deadline)
            end;
        Error -> Error
    end.

retry_url(Cfg, Session, Prefix, Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true -> timer:sleep(200), wait_url(Cfg, Session, Prefix, Deadline);
        false -> {error, recorded_url_mismatch}
    end.

no_value(Cfg, Session, Method, Path, Body) ->
    case webdriver(Cfg, Session, Method, Path, Body) of
        {ok, _} -> ok;
        Error -> Error
    end.

webdriver(Cfg, Session, Method, Path, Body) ->
    Sess = binary_to_list(Session),
    Prefix = "/session/" ++ Sess,
    Suffix = case iolist_to_binary(Path) of <<>> -> ""; P -> "/" ++ binary_to_list(P) end,
    case request(Cfg, Method, Prefix ++ Suffix, Body) of
        {ok, BodyMap} when is_map(BodyMap) -> {ok, maps:get(<<"value">>, BodyMap, null)};
        Error -> Error
    end.

%% Reuse DamageBDD's existing connection wrapper; no extra OTP application
%% dependencies or unsafe TLS verification fallbacks are introduced.
request(Cfg, Method, Path, Payload) ->
    Url = driver(Cfg) ++ Path,
    case parse_endpoint(Url) of
        {ok, Host, Port, RequestPath, Transport} ->
            Headers = [{<<"accept">>, <<"application/json">>},
                {<<"content-type">>, <<"application/json">>}],
            Body = case Method of
                post -> jsx:encode(Payload);
                _ -> <<>>
            end,
            Opts = #{transport => Transport, proxy => direct, timeout => ?TIMEOUT_MS,
                connect_timeout => ?TIMEOUT_MS, decode => raw},
            case damage_gun:request(Method, Host, Port, RequestPath, Headers, Body, Opts) of
                {ok, #{status := Status, body := RespBody}} -> response(Status, RespBody);
                {error, _} -> {error, webdriver_transport_failure};
                _ -> {error, unexpected_webdriver_transport_reply}
            end;
        Error -> Error
    end.

parse_endpoint(Url) ->
    case uri_string:parse(Url) of
        #{scheme := Scheme0, host := Host0} = Parsed ->
            Scheme = to_list(Scheme0),
            case Scheme of
                "http" -> endpoint_parts(Host0, maps:get(port, Parsed, 80), Parsed, tcp);
                "https" -> endpoint_parts(Host0, maps:get(port, Parsed, 443), Parsed, tls);
                _ -> {error, invalid_webdriver_scheme}
            end;
        _ -> {error, invalid_webdriver_url}
    end.

endpoint_parts(Host, Port, Parsed, Transport) ->
    Path0 = maps:get(path, Parsed, "/"),
    Path = case to_bin(Path0) of
        <<>> -> <<"/">>;
        Bin -> Bin
    end,
    case {maps:get(query, Parsed, undefined), Port} of
        {undefined, P} when is_integer(P), P > 0, P < 65536 ->
            {ok, to_list(Host), Port, Path, Transport};
        _ -> {error, invalid_webdriver_endpoint}
    end.

response(Status, Body) ->
    try jsx:decode(Body, [return_maps]) of
        Data when is_map(Data) ->
            case maps:get(<<"value">>, Data, undefined) of
                #{<<"error">> := Error} -> {error, {webdriver_error, Error}};
                _ when Status >= 200, Status < 300 -> {ok, Data};
                _ -> {error, {http_status, Status, invalid_webdriver_response}}
            end;
        _ -> {error, invalid_webdriver_json}
    catch _:_ -> {error, invalid_webdriver_json}
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(_) -> <<>>.

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.
