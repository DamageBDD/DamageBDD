%% Isolated W3C WebDriver client for Selenium Grid/ChromeDriver and Appium web.
%% Profiles are trusted operator configuration, never feature-supplied capabilities.
-module(damage_webdriver).
-compile({no_auto_import, [element/2]}).
-behaviour(gen_server).
-export([start/1, perform/3, close/1, options/1, capabilities/1, navigation_url/1]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3,
    format_status/1
]).
-define(ELEMENT, <<"element-6066-11e4-a52e-4f735466cecf">>).

start(Profile0) ->
    case damage_webdriver_runtime:resolve_profile(Profile0) of
        {ok, Profile} -> start_resolved(Profile);
        Error -> Error
    end.

start_resolved(Profile) ->
    %% Reject malformed configuration before it can appear in a gen_server crash report.
    case options(Profile) of
        {ok, Opts} ->
            case gen_server:start(?MODULE, {self(), Opts}, []) of
                {ok, Pid} ->
                    case perform(Pid, start, []) of
                        ok ->
                            {ok, Pid};
                        Error ->
                            _ = close(Pid),
                            Error
                    end;
                _ ->
                    {error, webdriver_start_failed}
            end;
        Error ->
            Error
    end.

perform(Pid, Op, Args) when is_pid(Pid) ->
    try gen_server:call(Pid, {Op, Args}, 240000) of
        Reply -> Reply
    catch
        exit:_ -> {error, webdriver_session_unavailable}
    end.

close(Pid) when is_pid(Pid) ->
    try gen_server:call(Pid, close, 35000) of
        Reply -> Reply
    catch
        exit:{noproc, _} -> ok;
        exit:_ -> {error, webdriver_cleanup_failed}
    end;
close(_) ->
    ok.

options(P) when is_list(P) ->
    try
        Endpoint = endpoint(proplists:get_value(endpoint, P)),
        Dashboard = endpoint(proplists:get_value(dashboard_url, P)),
        Caps0 = capabilities(proplists:get_value(capabilities, P, [])),
        true = map_size(Caps0) > 0,
        %% Native WebView/app launch requires separate native tests, not CSS selectors.
        Browser = maps:get(<<"browserName">>, Caps0),
        true = is_binary(Browser) andalso byte_size(Browser) > 0,
        false = maps:is_key(<<"appium:app">>, Caps0),
        Caps = Caps0#{
            <<"timeouts">> => #{
                <<"implicit">> => 0,
                <<"pageLoad">> => 30000,
                <<"script">> => 15000
            },
            <<"unhandledPromptBehavior">> => <<"ignore">>
        },
        Wait = bounded(proplists:get_value(wait_ms, P, 15000), 100, 180000),
        Command = bounded(proplists:get_value(command_timeout_ms, P, 30000), 100, 60000),
        StartTimeout = bounded(
            proplists:get_value(session_start_timeout_ms, P, 120000), 1000, 180000
        ),
        Lifetime = bounded(proplists:get_value(session_lifetime_ms, P, 900000), 1000, 3600000),
        Idle = bounded(proplists:get_value(idle_timeout_ms, P, 120000), 1000, 900000),
        Fixture = proplists:get_value(fixture, P, false),
        true = is_boolean(Fixture),
        Credentials = proplists:get_value(credentials, P, []),
        true = is_list(Credentials),
        true = lists:all(
            fun
                ({K, {env, E}}) ->
                    is_atom(K) andalso is_list(E) andalso E =/= [];
                (_) ->
                    false
            end,
            Credentials
        ),
        {ok, #{
            endpoint => Endpoint,
            dashboard => Dashboard,
            caps => Caps,
            wait => Wait,
            command => Command,
            start_timeout => StartTimeout,
            lifetime => Lifetime,
            idle => Idle,
            fixture => Fixture,
            credentials => Credentials,
            remembered => #{},
            managed_service => proplists:get_value(managed_service, P)
        }}
    catch
        _:_ -> {error, invalid_webdriver_profile}
    end;
options(_) ->
    {error, invalid_webdriver_profile}.

%% Config remains an Erlang proplist, including nested W3C capability objects.
capabilities(P) when is_list(P) ->
    true = lists:all(
        fun
            ({K, _V}) -> is_atom(K) orelse is_binary(K);
            (_) -> false
        end,
        P
    ),
    M = maps:from_list([{bin(K), cap_value(V)} || {K, V} <- P]),
    true = map_size(M) =:= length(P),
    M;
capabilities(_) ->
    error(invalid_capabilities).
cap_value([]) -> [];
cap_value([{_, _} | _] = P) -> capabilities(P);
cap_value(L) when is_list(L) -> [cap_value(V) || V <- L];
cap_value(B) when is_binary(B); is_number(B); is_boolean(B) -> B;
cap_value(null) -> null;
cap_value(A) when is_atom(A) -> atom_to_binary(A, utf8).

endpoint(U0) ->
    U = bin(U0),
    #{scheme := Scheme, host := Host} = Parsed = uri_string:parse(U),
    true = Scheme =:= <<"http">> orelse Scheme =:= <<"https">>,
    true = byte_size(Host) > 0,
    false = lists:any(fun(K) -> maps:is_key(K, Parsed) end, [userinfo, query, fragment]),
    string:trim(U, trailing, "/").
bounded(N, Min, Max) when is_integer(N), N >= Min, N =< Max -> N.
bin(B) when is_binary(B) -> B;
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> unicode:characters_to_binary(L).

init({Owner, Opts}) ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    Ref = erlang:monitor(process, Owner),
    Timer = erlang:send_after(maps:get(lifetime, Opts), self(), expired),
    case claim_service(maps:get(managed_service, Opts)) of
        {ok, ServiceMonitor} ->
            {ok,
                Opts#{
                    owner => Owner,
                    monitor => Ref,
                    timer => Timer,
                    session => undefined,
                    service_monitor => ServiceMonitor
                },
                maps:get(idle, Opts)};
        {error, Why} ->
            erlang:cancel_timer(Timer),
            erlang:demonitor(Ref, [flush]),
            {stop, Why}
    end.

claim_service(undefined) ->
    {ok, undefined};
claim_service({Backend, Service, Generation}) ->
    case damage_webdriver_runtime:claim(Backend, {Service, Generation}) of
        {ok, Service} -> {ok, erlang:monitor(process, Service)};
        Error -> Error
    end.

handle_call(_, {Caller, _}, #{owner := Owner} = S) when Caller =/= Owner ->
    {reply, {error, webdriver_wrong_owner}, S, maps:get(idle, S)};
handle_call(close, _From, S) ->
    Reply = delete_session(S),
    case Reply of
        ok -> release_managed(S);
        _ -> invalidate_managed(S)
    end,
    {stop, normal, Reply, S#{session => undefined}};
handle_call({Op, Args}, _From, S0) ->
    %% Nothing from remote error bodies, entered values or credentials is logged.
    S = S0#{
        deadline => erlang:monotonic_time(millisecond) +
            operation_timeout(Op, S0)
    },
    try operation(Op, Args, S) of
        S1 when is_map(S1) -> {reply, ok, maps:remove(deadline, S1), maps:get(idle, S1)}
    catch
        throw:{webdriver, Reason} ->
            maybe_uncertain_start(Op, S0),
            {reply, {error, Reason}, S0, maps:get(idle, S0)};
        _:_ ->
            maybe_uncertain_start(Op, S0),
            {reply, {error, webdriver_operation_failed}, S0, maps:get(idle, S0)}
    end;
handle_call(_, _, S) ->
    {reply, {error, bad_call}, S, maps:get(idle, S)}.
handle_cast(_, S) -> {noreply, S, maps:get(idle, S)}.
handle_info({'DOWN', Ref, process, _, _}, #{service_monitor := Ref} = S) when is_reference(Ref) ->
    {stop, normal, S#{session => undefined}};
handle_info({webdriver_backend_lost, Service}, #{managed_service := {_, Service, _}} = S) ->
    {stop, normal, S#{session => undefined}};
handle_info({'DOWN', Ref, process, _, _}, #{monitor := Ref} = S) ->
    {stop, normal, S};
handle_info(expired, S) ->
    {stop, normal, S};
handle_info(timeout, S) ->
    {stop, normal, S};
handle_info(_, S) ->
    {noreply, S, maps:get(idle, S)}.
terminate(_, S) ->
    erlang:cancel_timer(maps:get(timer, S)),
    case delete_session(S) of
        ok -> release_managed(S);
        _ -> invalidate_managed(S)
    end,
    ok.

%% A timed-out POST /session can leave a server-side session whose id was never
%% received. Recycle the owned backend instead of leaking that browser/slot.
maybe_uncertain_start(start, S) -> invalidate_managed(S);
maybe_uncertain_start(_, _) -> ok.
invalidate_managed(#{managed_service := {_, Service, Generation}}) ->
    gen_server:cast(Service, {invalidate, self(), Generation});
invalidate_managed(_) ->
    ok.
release_managed(#{managed_service := {_, Service, Generation}}) ->
    try
        gen_server:call(Service, {release, Generation}, 5000)
    catch
        exit:_ -> ok
    end;
release_managed(_) ->
    ok.
code_change(_, S, _) -> {ok, S}.
format_status(Status) ->
    Status#{
        state => redacted_webdriver_session,
        message => redacted,
        reason => redacted
    }.

operation_timeout(start, S) ->
    maps:get(start_timeout, S);
operation_timeout(Op, S) ->
    case
        lists:member(Op, [
            state,
            text,
            value,
            unchanged,
            attribute,
            property,
            fragment,
            no_overflow,
            one_panel,
            layout,
            fixture_idle,
            value_contains,
            fixture_count,
            url_prefix
        ])
    of
        true -> maps:get(wait, S);
        false -> erlang:max(maps:get(wait, S), maps:get(command, S))
    end.

operation(start, [], #{session := undefined} = S) ->
    V = wire(
        S#{command => maps:get(start_timeout, S)},
        post,
        <<"/session">>,
        #{
            <<"capabilities">> =>
                #{<<"alwaysMatch">> => maps:get(caps, S), <<"firstMatch">> => [#{}]}
        },
        false
    ),
    case V of
        #{<<"sessionId">> := Id} when is_binary(Id), byte_size(Id) > 0 -> S#{session => Id};
        _ -> fail(bad_session_response)
    end;
operation(navigate, [Url], S) ->
    case navigation_url(Url) of
        {ok, Target} -> navigate(Target, S);
        {error, Reason} -> fail(Reason)
    end;
operation(url_prefix, [Prefix0], S) ->
    case navigation_url(Prefix0) of
        {ok, Prefix} ->
            await(fun(S1) ->
                case command(S1, get, <<"/url">>, #{}) of
                    Current when is_binary(Current) -> binary:match(Current, Prefix) =:= {0, byte_size(Prefix)};
                    _ -> false
                end
            end, S);
        {error, Reason} -> fail(Reason)
    end;
operation(select, [Css, Wanted], S) ->
    select_option(bin(Css), bin(Wanted), S);
operation(checked, [Css, State], S) ->
    Wanted = case bin(State) of
        <<"checked">> -> true;
        <<"unchecked">> -> false;
        _ -> fail(invalid_checked_state)
    end,
    set_checked(bin(Css), Wanted, S);
operation(account_secret, [Owner0, Name0, Css], S) ->
    Owner = bin(Owner0),
    Name = bin(Name0),
    %% Resolve in the owned client process; no plaintext in context or command args.
    case account_secret(Owner, Name) of
        {ok, Value} -> fill(bin(Css), Value, S);
        error -> fail(missing_recorded_account_secret)
    end;
operation(open, [], S) ->
    open_clean(S);
operation(open_authenticated, [], S) ->
    S1 = open_clean(S),
    case maps:get(fixture, S) of
        true -> wait_state(<<"[data-dashboard-shell]">>, <<"visible">>, S1);
        false -> login(S1)
    end;
operation(open_fragment, [Fragment], S) ->
    F = bin(Fragment),
    case F of
        <<"#", _/binary>> -> ok;
        _ -> fail(invalid_fragment)
    end,
    navigate(<<(maps:get(dashboard, S))/binary, "/", F/binary>>, S);
operation(select_panel, [Panel0], S) ->
    Panel = bin(Panel0),
    true = lists:member(Panel, [
        <<"execution-tab">>,
        <<"activity-tab">>,
        <<"analytics-tab">>,
        <<"schedules-tab">>,
        <<"billing-tab">>,
        <<"settings-tab">>,
        <<"swap-options-tab">>,
        <<"ecai-jobs-tab">>,
        <<"node-transactions-tab">>,
        <<"node-channels-tab">>,
        <<"node-cln-admin-tab">>
    ]),
    S1 =
        case
            script(
                <<"return matchMedia('(max-width: 900px)').matches && !document.querySelector('[data-dashboard-shell]').classList.contains('sidebar-open')">>,
                [],
                S
            )
        of
            true -> click(<<"#dashboard-nav-toggle">>, S);
            false -> S
        end,
    click(<<"#dashboard-navigation [data-dashboard-panel='", Panel/binary, "']">>, S1);
operation(sidebar_action, [Action], S) ->
    Css =
        case bin(Action) of
            <<"sign-out">> -> <<"#logoutBtn">>;
            _ -> fail(unsupported_sidebar_action)
        end,
    S1 =
        case
            script(
                <<"return matchMedia('(max-width: 900px)').matches && !document.querySelector('[data-dashboard-shell]').classList.contains('sidebar-open')">>,
                [],
                S
            )
        of
            true -> click(<<"#dashboard-nav-toggle">>, S);
            false -> S
        end,
    click(Css, S1);
operation(one_panel, [], S) ->
    await(
        fun(S1) ->
            script(
                <<"return [...document.querySelectorAll('[data-dashboard-view]')].filter(e => !e.hidden && getComputedStyle(e).display !== 'none').length">>,
                [],
                S1
            ) =:= 1
        end,
        S
    );
operation(layout, [Layout], S) ->
    Mobile =
        case bin(Layout) of
            <<"mobile">> -> true;
            <<"desktop">> -> false
        end,
    await(
        fun(S1) ->
            script(<<"return matchMedia('(max-width: 900px)').matches">>, [], S1) =:= Mobile
        end,
        S
    );
operation(backdrop, [], S) ->
    [X, Y] = script(
        <<"const r = document.querySelector('#dashboard-sidebar').getBoundingClientRect(); if (r.right >= innerWidth) throw Error('no backdrop strip'); return [Math.floor((r.right + innerWidth)/2), Math.floor(innerHeight/2)]">>,
        [],
        S
    ),
    Action = #{
        <<"type">> => <<"pointer">>,
        <<"id">> => <<"dashboard-touch">>,
        <<"parameters">> => #{<<"pointerType">> => <<"touch">>},
        <<"actions">> => [
            #{
                <<"type">> => <<"pointerMove">>,
                <<"duration">> => 0,
                <<"origin">> => <<"viewport">>,
                <<"x">> => X,
                <<"y">> => Y
            },
            #{<<"type">> => <<"pointerDown">>, <<"button">> => 0},
            #{<<"type">> => <<"pause">>, <<"duration">> => 50},
            #{<<"type">> => <<"pointerUp">>, <<"button">> => 0}
        ]
    },
    try command(S, post, <<"/actions">>, #{<<"actions">> => [Action]}) of
        _ -> S
    after
        _ = command(S, delete, <<"/actions">>, #{})
    end;
operation(fixture_gate, [Gate], S) ->
    fixture(S),
    case bin(Gate) of
        <<"hold">> -> true = script(<<"window.__dashboardTest.hold = true; return true">>, [], S);
        <<"release">> -> true = script(<<"window.__dashboardTest.release(); return true">>, [], S);
        _ -> fail(invalid_fixture_gate)
    end,
    S;
operation(fixture_idle, [], S) ->
    fixture(S),
    await(
        fun(S1) -> script(<<"return window.__dashboardTest?.pending === 0">>, [], S1) =:= true end,
        S
    );
operation(value_contains, [Css, Value], S) ->
    Expected = bin(Value),
    await(
        fun(S1) ->
            case probe(value, [bin(Css)], S1) of
                V when is_binary(V) -> binary:match(V, Expected) =/= nomatch;
                _ -> false
            end
        end,
        S
    );
operation(click, [Css], S) ->
    click(bin(Css), S);
operation(fill, [Css, Text], S) ->
    fill(bin(Css), bin(Text), S);
operation(credential, [Alias, Css], S) ->
    %% Credential aliases are fixed; feature authors cannot name arbitrary env vars.
    Key =
        case bin(Alias) of
            <<"username">> -> username;
            <<"password">> -> password;
            _ -> fail(unknown_credential_alias)
        end,
    fill(bin(Css), credential(Key, S), S);
operation(remember, [Css, Name], S) ->
    Value = probe(value, [bin(Css)], S),
    case Value of
        null -> fail(missing_remembered_element);
        _ -> ok
    end,
    S#{remembered => maps:put(bin(Name), Value, maps:get(remembered, S))};
operation(unchanged, [Css, Name], S) ->
    case maps:find(bin(Name), maps:get(remembered, S)) of
        {ok, Value} -> await(fun(S1) -> probe(value, [bin(Css)], S1) =:= Value end, S);
        error -> fail(unknown_remembered_value)
    end;
operation(state, [Css, State], S) ->
    wait_state(bin(Css), bin(State), S);
operation(text, [Css, Text], S) ->
    Expected = bin(Text),
    await(
        fun(S1) ->
            case probe(text, [bin(Css)], S1) of
                V when is_binary(V) -> binary:match(V, Expected) =/= nomatch;
                _ -> false
            end
        end,
        S
    );
operation(value, [Css, Value], S) ->
    await(fun(S1) -> probe(value, [bin(Css)], S1) =:= bin(Value) end, S);
operation(attribute, [Css, Attribute, Value], S) ->
    await(fun(S1) -> probe(attribute, [bin(Css), bin(Attribute)], S1) =:= bin(Value) end, S);
operation(property, [Css, Property, Json], S) ->
    Expected =
        try
            jsx:decode(bin(Json), [return_maps])
        catch
            _:_ -> fail(invalid_json_value)
        end,
    await(fun(S1) -> probe(property, [bin(Css), bin(Property)], S1) =:= Expected end, S);
operation(fragment, [Fragment], S) ->
    await(fun(S1) -> script(<<"return location.hash">>, [], S1) =:= bin(Fragment) end, S);
operation(no_overflow, [], S) ->
    await(
        fun(S1) ->
            script(
                <<"return document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1">>,
                [],
                S1
            ) =:= true
        end,
        S
    );
operation(back, [], S) ->
    _ = command(S, post, <<"/back">>, #{}),
    S;
operation(forward, [], S) ->
    _ = command(S, post, <<"/forward">>, #{}),
    S;
operation(refresh, [], S) ->
    _ = command(S, post, <<"/refresh">>, #{}),
    S;
operation(key_element, [Name, Css], S) ->
    Id = element(bin(Css), S),
    _ = command(S, post, element_path(Id, <<"/value">>), #{<<"text">> => key(bin(Name))}),
    S;
operation(key, [Name], S) ->
    Text = key(bin(Name)),
    #{?ELEMENT := Id} = command(S, get, <<"/element/active">>, #{}),
    _ = command(S, post, element_path(Id, <<"/value">>), #{<<"text">> => Text}),
    S;
operation(alert, [Choice], S) ->
    Path =
        case bin(Choice) of
            <<"accept">> -> <<"/alert/accept">>;
            <<"dismiss">> -> <<"/alert/dismiss">>;
            _ -> fail(invalid_alert_action)
        end,
    _ = command(S, post, Path, #{}),
    S;
operation(wait_ms, [Ms], S) ->
    S#{wait => bounded(int(Ms), 100, 180000)};
operation(viewport, [Width, Height], S) ->
    case maps:is_key(<<"appium:automationName">>, maps:get(caps, S)) of
        true -> fail(appium_viewport_uses_device_dimensions);
        false -> resize(bounded(int(Width), 320, 3840), bounded(int(Height), 480, 2160), S, 3)
    end;
operation(fixture_mode, [Mode], S) ->
    fixture(S),
    M = bin(Mode),
    true = lists:member(M, [
        <<"ok">>,
        <<"invalid">>,
        <<"incomplete">>,
        <<"xss">>,
        <<"http-error">>,
        <<"unauthorized">>,
        <<"no-engine">>
    ]),
    true = script(
        <<"window.__mock.mode = arguments[0]; window.__mock.delay = 160; return true">>, [M], S
    ),
    S;
operation(fixture_count, [Action, Count], S) ->
    fixture(S),
    A = bin(Action),
    N = int(Count),
    await(
        fun(S1) ->
            script(
                <<"return arguments[0] === 'execute' ? window.__mock.executions : window.__mock.calls.filter(x => x.action === arguments[0]).length">>,
                [A],
                S1
            ) =:= N
        end,
        S
    );
operation(fixture_billing, [Visible], S) ->
    fixture(S),
    V =
        case bin(Visible) of
            <<"visible">> -> false;
            <<"hidden">> -> true
        end,
    true = script(
        <<"const v=arguments[0]; document.querySelector('#billing-nav').hidden=v; const g=document.querySelector('#billing-nav-group'); if(g) g.hidden=v; return true">>,
        [V],
        S
    ),
    S;
operation(fixture_no_injection, [], S) ->
    fixture(S),
    false = script(<<"return window.__injected === true">>, [], S),
    S.

open_clean(#{visited := true} = S) ->
    navigate(<<(maps:get(dashboard, S))/binary, "/">>, S);
open_clean(S) ->
    %% Dedicated test profiles/devices only. Appium may otherwise retain an old
    %% mobile browser login between sessions, invalidating authentication checks.
    S1 = navigate(<<(maps:get(dashboard, S))/binary, "/">>, S),
    _ = command(S1, delete, <<"/cookie">>, #{}),
    true = script(<<"localStorage.clear(); sessionStorage.clear(); return true">>, [], S1),
    _ = command(S1, post, <<"/refresh">>, #{}),
    S1#{visited => true}.

login(S) ->
    S1 = wait_state(<<"#login-username">>, <<"visible">>, S),
    S2 = fill(<<"#login-username">>, credential(username, S1), S1),
    S3 = fill(<<"#password">>, credential(password, S2), S2),
    S4 = click(<<"#loginSubmitBtn">>, S3),
    wait_state(<<"[data-dashboard-shell]">>, <<"visible">>, S4).
credential(Key, S) ->
    case proplists:get_value(Key, maps:get(credentials, S)) of
        {env, Name} ->
            case os:getenv(Name) of
                false -> fail(missing_webdriver_credential);
                "" -> fail(missing_webdriver_credential);
                Value -> bin(Value)
            end;
        _ ->
            fail(missing_webdriver_credential)
    end.

%% Website URLs may include path/query/hash, unlike the automation endpoint.
%% Reject credentials, controls and non-web schemes before creating a session.
navigation_url(Value) ->
    try
        Url = bin(Value),
        true = byte_size(Url) > 0 andalso byte_size(Url) =< 8192,
        #{scheme := Scheme, host := Host} = Parsed = uri_string:parse(Url),
        true = (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>),
        true = is_binary(Host) andalso byte_size(Host) > 0,
        false = maps:is_key(userinfo, Parsed),
        Port = maps:get(port, Parsed, 80),
        true = is_integer(Port) andalso Port > 0 andalso Port < 65536,
        nomatch = re:run(Url, <<"[\\x00-\\x20\\x7f]">>, [{capture, none}]),
        {ok, Url}
    catch
        _:_ -> {error, invalid_browser_url}
    end.

account_secret(Owner, Name) when is_binary(Owner), byte_size(Owner) > 0,
    is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< 256 ->
    try secrets:retrieve_decrypt({account, Owner}, Name) of
        {ok, Value} when is_binary(Value); is_list(Value) ->
            case bin(Value) of
                B when is_binary(B) -> {ok, B};
                _ -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end;
account_secret(_, _) -> error.

select_option(Css, Wanted, S) ->
    S1 = wait_state(Css, <<"clickable">>, S),
    Id = element(Css, S1),
    case {command(S1, get, element_path(Id, <<"/name">>), #{}),
        command(S1, get, element_path(Id, <<"/property/multiple">>), #{})} of
        {<<"select">>, false} -> ok;
        _ -> fail(expected_single_select)
    end,
    Option = matching_option(Id, Wanted, S1),
    %% WebDriver clicks the option; no synthetic change events or action retries.
    _ = command(S1, post, element_path(Option, <<"/click">>), #{}),
    await(fun(S2) -> command(S2, get, element_path(Option, <<"/selected">>), #{}) =:= true end, S1).

matching_option(Select, Wanted, S) ->
    Options = command(S, post, element_path(Select, <<"/elements">>),
        #{<<"using">> => <<"css selector">>, <<"value">> => <<"option">>}),
    %% Recorders capture select.value, not the displayed label. In particular,
    %% an empty option value is valid and must not be replaced by its label.
    Matches = [Id || #{?ELEMENT := Id} <- Options,
        command(S, get, element_path(Id, <<"/property/value">>), #{}) =:= Wanted],
    case Matches of
        [Id] -> Id;
        [] ->
            case remaining(S) > 100 of
                true -> timer:sleep(100), matching_option(Select, Wanted, S);
                false -> fail(recorded_option_not_found)
            end;
        _ -> fail(ambiguous_recorded_option)
    end.

set_checked(Css, Wanted, S) ->
    S1 = wait_state(Css, <<"clickable">>, S),
    Id = element(Css, S1),
    Kind = command(S1, get, element_path(Id, <<"/property/type">>), #{}),
    case {Kind, Wanted} of
        {<<"checkbox">>, _} -> ok;
        {<<"radio">>, true} -> ok;
        {<<"radio">>, false} -> fail(cannot_uncheck_radio);
        _ -> fail(expected_checkbox_or_radio)
    end,
    case command(S1, get, element_path(Id, <<"/selected">>), #{}) of
        Wanted -> S1;
        Actual when is_boolean(Actual) ->
            _ = command(S1, post, element_path(Id, <<"/click">>), #{}),
            await(fun(S2) -> command(S2, get, element_path(Id, <<"/selected">>), #{}) =:= Wanted end, S1);
        _ -> fail(invalid_checked_response)
    end.

navigate(Url, S) ->
    _ = command(S, post, <<"/url">>, #{<<"url">> => Url}),
    S.
click(Css, S) ->
    S1 = wait_state(Css, <<"clickable">>, S),
    Id = element(Css, S1),
    %% Never retry a click: a lost response must not duplicate a payment/run.
    _ = command(S1, post, element_path(Id, <<"/click">>), #{}),
    S1.
fill(Css, Text, S) ->
    S1 = wait_state(Css, <<"clickable">>, S),
    Id = element(Css, S1),
    _ = command(S1, post, element_path(Id, <<"/clear">>), #{}),
    _ = command(S1, post, element_path(Id, <<"/value">>), #{<<"text">> => Text}),
    S1.
element(Css, S) ->
    case
        command(S, post, <<"/elements">>, #{<<"using">> => <<"css selector">>, <<"value">> => Css})
    of
        [#{?ELEMENT := Id}] -> Id;
        [] -> fail(element_not_found);
        _ -> fail(ambiguous_selector)
    end.
element_path(Id, Suffix) -> <<"/element/", (uri_string:quote(Id))/binary, Suffix/binary>>.

wait_state(Css, State, S) ->
    true = lists:member(State, [
        <<"visible">>,
        <<"hidden">>,
        <<"absent">>,
        <<"enabled">>,
        <<"disabled">>,
        <<"focused">>,
        <<"contains-focus">>,
        <<"clickable">>
    ]),
    await(fun(S1) -> probe(state, [Css, State], S1) =:= true end, S).

%% Scripts below only inspect DOM state. Actions use actual WebDriver input commands.
%% A missing selector is NOT a successful hidden/disabled/property assertion.
probe(Kind, Args, S) ->
    Prefix =
        <<"const es = document.querySelectorAll(arguments[0]); const e = es.length === 1 ? es[0] : null; ">>,
    Body =
        case Kind of
            value ->
                <<"return e && !e.matches('input[type=password]') ? e.value ?? null : null">>;
            text ->
                <<"return e ? e.innerText : null">>;
            attribute ->
                <<"return e ? e.getAttribute(arguments[1]) : null">>;
            property ->
                <<"if (arguments[1] === 'value') throw Error('use value assertion'); return e ? e[arguments[1]] : '__missing_element__'">>;
            state ->
                <<"const state = arguments[1]; if (state === 'absent') return es.length === 0; if (!e) return false; const s = getComputedStyle(e), r = e.getBoundingClientRect(); const visible = !e.closest('[hidden]') && s.visibility !== 'hidden' && s.display !== 'none' && r.width > 0 && r.height > 0; const enabled = !e.matches(':disabled') && e.getAttribute('aria-disabled') !== 'true'; switch (state) { case 'visible': return visible; case 'hidden': return !visible; case 'enabled': return enabled; case 'disabled': return !enabled; case 'focused': return document.activeElement === e; case 'contains-focus': return e.contains(document.activeElement); case 'clickable': return visible && enabled && !e.closest('[inert]'); } return false">>
        end,
    script(<<Prefix/binary, Body/binary>>, Args, S).

await(Predicate, S) ->
    %% One deadline per operation; each wire timeout is clamped to time remaining.
    case Predicate(S) of
        true ->
            S;
        false ->
            case remaining(S) > 100 of
                true ->
                    timer:sleep(100),
                    await(Predicate, S);
                false ->
                    fail(webdriver_assertion_timeout)
            end
    end.
remaining(S) -> erlang:max(1, maps:get(deadline, S) - erlang:monotonic_time(millisecond)).

resize(W, H, S, 0) ->
    await(
        fun(S1) ->
            script(
                <<"return innerWidth === arguments[0] && innerHeight === arguments[1]">>, [W, H], S1
            ) =:= true
        end,
        S
    );
resize(W, H, S, N) ->
    [IW, IH] = script(<<"return [innerWidth, innerHeight]">>, [], S),
    #{<<"width">> := OW, <<"height">> := OH} = command(S, get, <<"/window/rect">>, #{}),
    _ = command(S, post, <<"/window/rect">>, #{
        <<"width">> => W + OW - IW,
        <<"height">> => H + OH - IH
    }),
    case
        script(<<"return innerWidth === arguments[0] && innerHeight === arguments[1]">>, [W, H], S)
    of
        true -> S;
        false -> resize(W, H, S, N - 1)
    end.

key(<<"Escape">>) -> utf8([16#E00C]);
key(<<"Enter">>) -> utf8([16#E007]);
key(<<"Tab">>) -> utf8([16#E004]);
key(<<"Shift+Tab">>) -> utf8([16#E008, 16#E004, 16#E000]);
key(<<"ArrowDown">>) -> utf8([16#E015]);
key(<<"Home">>) -> utf8([16#E011]);
key(<<"End">>) -> utf8([16#E010]);
key(<<"Control+Enter">>) -> utf8([16#E009, 16#E007, 16#E000]);
key(<<"Meta+Enter">>) -> utf8([16#E03D, 16#E007, 16#E000]);
key(_) -> fail(unsupported_key).
utf8(L) -> unicode:characters_to_binary(L).
int(B) when is_binary(B) -> binary_to_integer(B);
int(L) when is_list(L) -> list_to_integer(L);
int(I) when is_integer(I) -> I.

fixture(S) ->
    case maps:get(fixture, S, false) of
        true ->
            case
                script(<<"return !!window.__mock && Array.isArray(window.__mock.calls)">>, [], S)
            of
                true -> ok;
                _ -> fail(not_a_dashboard_fixture)
            end;
        false ->
            fail(fixture_operation_forbidden_on_live_node)
    end.
script(Script, Args, S) ->
    command(S, post, <<"/execute/sync">>, #{<<"script">> => Script, <<"args">> => Args}).
command(#{session := undefined}, _, _, _) -> fail(webdriver_session_missing);
command(S, Method, Path, Body) -> wire(S, Method, Path, Body, true).
wire(S, Method, Path, Body, SessionScoped) ->
    Prefix =
        case SessionScoped of
            true -> <<"/session/", (uri_string:quote(maps:get(session, S)))/binary>>;
            false -> <<>>
        end,
    URL = <<(maps:get(endpoint, S))/binary, Prefix/binary, Path/binary>>,
    #{scheme := Scheme, host := Host} = uri_string:parse(URL),
    TLS =
        case Scheme of
            <<"https">> ->
                [
                    {ssl, [
                        {verify, verify_peer},
                        {cacerts, public_key:cacerts_get()},
                        {server_name_indication, binary_to_list(Host)},
                        {customize_hostname_check, [
                            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                        ]}
                    ]}
                ];
            _ ->
                []
        end,
    Timeout = erlang:min(maps:get(command, S), remaining(S)),
    HttpOpts = [{timeout, Timeout}, {connect_timeout, Timeout}, {autoredirect, false} | TLS],
    Headers = [{"accept", "application/json"}, {"x-appium-is-sensitive", "true"}],
    Request =
        case Method of
            get -> {binary_to_list(URL), Headers};
            delete -> {binary_to_list(URL), Headers};
            post -> {binary_to_list(URL), Headers, "application/json", jsx:encode(Body)}
        end,
    case httpc:request(Method, Request, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, Status, _}, _, Raw}} when byte_size(Raw) =< 8388608 ->
            Json =
                try
                    jsx:decode(Raw, [return_maps])
                catch
                    _:_ -> fail(webdriver_invalid_json)
                end,
            case {Status, Json} of
                {N, #{<<"value">> := V}} when N >= 200, N < 300 -> V;
                {_, #{<<"value">> := #{<<"error">> := Code}}} ->
                    %% Only known protocol codes leave this process, never server messages.
                    fail({webdriver_protocol, Status, protocol_code(Code)});
                _ ->
                    fail({webdriver_http_status, Status})
            end;
        {error, timeout} ->
            fail(webdriver_transport_timeout);
        {error, _} ->
            fail(webdriver_transport_failed);
        _ ->
            fail(webdriver_response_too_large)
    end.
protocol_code(Code) ->
    Allowed = [
        <<"invalid session id">>,
        <<"no such element">>,
        <<"stale element reference">>,
        <<"invalid selector">>,
        <<"no such alert">>,
        <<"unexpected alert open">>,
        <<"element click intercepted">>,
        <<"element not interactable">>,
        <<"invalid argument">>,
        <<"session not created">>,
        <<"timeout">>,
        <<"script timeout">>,
        <<"unknown command">>
    ],
    case lists:member(Code, Allowed) of
        true -> Code;
        false -> <<"remote error">>
    end.
delete_session(#{session := undefined}) ->
    ok;
delete_session(S0) ->
    S = S0#{deadline => erlang:monotonic_time(millisecond) + 30000, command => 30000},
    try command(S, delete, <<>>, #{}) of
        _ -> ok
    catch
        throw:{webdriver, {webdriver_protocol, 404, <<"invalid session id">>}} -> ok;
        _:_ -> {error, webdriver_cleanup_failed}
    end.
fail(Reason) -> throw({webdriver, Reason}).
