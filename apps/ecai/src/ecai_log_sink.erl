%%--------------------------------------------------------------------
%% ecai_log_sink.erl
%%
%% Emits artifacts from deterministic matches:
%%   - alerts
%%   - BDD scenarios/features
%%--------------------------------------------------------------------
-module(ecai_log_sink).

-export([
    emit/3,
    emit_alert/2,
    emit_bdd/2
]).

-include_lib("kernel/include/logger.hrl").

emit(RuleResult, Event, Opts) ->
    Actions = maps:get(actions, RuleResult, []),
    Results =
        lists:foldl(
            fun(Action, Acc) ->
                Res =
                    case Action of
                        alert ->
                            emit_alert(RuleResult, Event);
                        emit_bdd ->
                            emit_bdd(RuleResult, Opts);
                        suggest_rate_limit ->
                            {ok, ignored};
                        _ ->
                            {ok, ignored}
                    end,
                [Res | Acc]
            end,
            [],
            Actions
        ),
    {ok, lists:reverse(Results)}.

emit_alert(RuleResult, Event) ->
    Severity = maps:get(severity, RuleResult, low),
    Pattern = maps:get(known_pattern, RuleResult, undefined),
    Text = maps:get(text, Event, <<>>),

    Msg = io_lib:format(
        "[~p] ECAI log alert pattern=~p~n~s",
        [Severity, Pattern, Text]
    ),
    ?LOG_WARNING("~s", [Msg]),
    {ok, alert_logged}.

emit_bdd(RuleResult, Opts) ->
    Dir = maps:get(bdd_dir, Opts, "./ecai_bdd_out"),
    ok = ensure_dir(Dir),

    Pattern = maps:get(known_pattern, RuleResult, unknown_pattern),
    Ts = integer_to_binary(erlang:system_time(millisecond)),
    File = filename:join(Dir, atom_to_list(Pattern) ++ "_" ++ binary_to_list(Ts) ++ ".feature"),
    Feature = bdd_template(Pattern, RuleResult),

    case file:write_file(File, Feature) of
        ok ->
            {ok, {bdd_written, File}};
        Error ->
            Error
    end.

bdd_template(db_connection_refused, _RuleResult) ->
    iolist_to_binary([
        "Feature: Database connectivity remains available\n\n",
        "  Scenario: Application can reach the configured database\n",
        "    # TODO set correct server/base URL\n",
        "    Given I am using server \"default\":\n",
        "    # TODO set actual health endpoint\n",
        "    When I make a GET request to \"/health\":\n",
        "    Then the response status must be \"200\":\n",
        "    Then the response must contain text \"ok\":\n"
    ]);
bdd_template(db_pool_exhausted, _RuleResult) ->
    iolist_to_binary([
        "Feature: Database pool remains within operational capacity\n\n",
        "  Scenario: Health endpoint does not report pool exhaustion\n",
        "    Given I am using server \"default\":\n",
        "    When I make a GET request to \"/health\":\n",
        "    Then the response status must be one of \"200,204\":\n",
        "    # TODO add json path checks for pool usage when available\n"
    ]);
bdd_template(out_of_memory, _RuleResult) ->
    iolist_to_binary([
        "Feature: Application remains stable under expected memory load\n\n",
        "  Scenario: Health endpoint remains available after workload\n",
        "    Given I am using server \"default\":\n",
        "    When I make a GET request to \"/health\":\n",
        "    Then the response status must be \"200\":\n",
        "    # TODO add workload setup and memory assertions\n"
    ]);
bdd_template(disk_full, _RuleResult) ->
    iolist_to_binary([
        "Feature: Application handles storage pressure safely\n\n",
        "  Scenario: Writes do not fail from exhausted disk\n",
        "    Given I am using server \"default\":\n",
        "    # TODO use endpoint that exercises a write path\n",
        "    When I make a POST request to \"/\":\n",
        "    Then the response status must be one of \"200,201,202\":\n"
    ]);
bdd_template(timeout_upstream, _RuleResult) ->
    iolist_to_binary([
        "Feature: Upstream dependencies respond within operational bounds\n\n",
        "  Scenario: Proxy path does not timeout\n",
        "    Given I am using server \"default\":\n",
        "    # TODO set actual proxied endpoint\n",
        "    When I make a GET request to \"/\":\n",
        "    Then the response status must be one of \"200,204\":\n"
    ]);
bdd_template(tls_failure, _RuleResult) ->
    iolist_to_binary([
        "Feature: TLS configuration remains valid\n\n",
        "  Scenario: HTTPS endpoint presents a usable certificate chain\n",
        "    Given I am using server \"default\":\n",
        "    When I make a GET request to \"/health\":\n",
        "    Then the response status must be \"200\":\n"
    ]);
bdd_template(auth_failure, _RuleResult) ->
    iolist_to_binary([
        "Feature: Authenticated access works with valid credentials\n\n",
        "  Scenario: Valid token is accepted by protected endpoint\n",
        "    Given I am using server \"default\":\n",
        "    # TODO set auth header\n",
        "    When I make a GET request to \"/protected\":\n",
        "    Then the response status must be one of \"200,204\":\n"
    ]);
bdd_template(erlang_crash, _RuleResult) ->
    iolist_to_binary([
        "Feature: Erlang service avoids known crash paths\n\n",
        "  Scenario: Target endpoint does not trigger crash condition\n",
        "    Given I am using server \"default\":\n",
        "    # TODO set crash reproducer endpoint\n",
        "    When I make a GET request to \"/\":\n",
        "    Then the response status must be one of \"200,400,404\":\n"
    ]);
bdd_template(python_traceback, _RuleResult) ->
    iolist_to_binary([
        "Feature: Python service avoids traceback-generating requests\n\n",
        "  Scenario: Known request path returns safely\n",
        "    Given I am using server \"default\":\n",
        "    When I make a GET request to \"/\":\n",
        "    Then the response status must be one of \"200,400,404\":\n"
    ]);
bdd_template(java_exception, _RuleResult) ->
    iolist_to_binary([
        "Feature: Java service avoids exception-producing paths\n\n",
        "  Scenario: Known request path returns safely\n",
        "    Given I am using server \"default\":\n",
        "    When I make a GET request to \"/\":\n",
        "    Then the response status must be one of \"200,400,404\":\n"
    ]);
bdd_template(_, RuleResult) ->
    Pattern = maps:get(known_pattern, RuleResult, unknown_pattern),
    iolist_to_binary([
        "Feature: Investigate log-derived failure pattern\n\n",
        "  Scenario: Reproduce and verify ",
        atom_to_list(Pattern),
        "\n",
        "    # TODO derive a concrete HTTP/system scenario from the matched log pattern\n",
        "    Given I am using server \"default\":\n",
        "    When I make a GET request to \"/\":\n",
        "    Then the response status must be one of \"200,400,404,500\":\n"
    ]).

ensure_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true -> ok;
        false -> file:make_dir(Dir)
    end.
