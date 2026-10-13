%%--------------------------------------------------------------------
%% ecai_log_rules.erl
%%
%% Deterministic rule engine for log events.
%% Input: a grouped multiline event
%% Output: classification, severity, escalation, sink directives
%%--------------------------------------------------------------------
-module(ecai_log_rules).

-export([
    evaluate/1,
    default_rules/0
]).

evaluate(Event0) when is_binary(Event0) ->
    evaluate(#{text => Event0});
evaluate(Event0) when is_map(Event0) ->
    Text0 = maps:get(text, Event0, <<>>),
    Text = norm(Text0),

    Rules = default_rules(),
    Matches = [R || R <- Rules, rule_matches(R, Text)],
    Severity = max_severity(Text, Matches),
    Tags = unique_flatten([maps:get(tags, R, []) || R <- Matches]),
    Actions = unique_flatten([maps:get(actions, R, []) || R <- Matches]),
    KnownPattern =
        case Matches of
            [R | _] -> maps:get(id, R);
            [] -> undefined
        end,
    Escalate = should_escalate(Severity, Matches, Text),
    UseOllama = should_use_ollama(Severity, Matches, Text),

    #{
        severity => Severity,
        escalate => Escalate,
        use_ollama => UseOllama,
        known_pattern => KnownPattern,
        matches => [maps:get(id, R) || R <- Matches],
        tags => Tags,
        actions => Actions,
        text => Text0
    }.

default_rules() ->
    [
        #{
            id => db_connection_refused,
            pattern => <<"connection refused|econnrefused|failed to connect">>,
            severity => critical,
            tags => [database, network, startup],
            actions => [alert, emit_bdd]
        },
        #{
            id => db_pool_exhausted,
            pattern =>
                <<"pool exhausted|too many clients|connection pool full|max connections exceeded">>,
            severity => high,
            tags => [database, capacity],
            actions => [alert, emit_bdd, suggest_rate_limit]
        },
        #{
            id => out_of_memory,
            pattern =>
                <<"out of memory|oom|cannot allocate memory|enomem|killed process .* out of memory">>,
            severity => critical,
            tags => [memory, infrastructure],
            actions => [alert, emit_bdd]
        },
        #{
            id => disk_full,
            pattern => <<"no space left on device|disk full|enospc">>,
            severity => critical,
            tags => [storage, infrastructure],
            actions => [alert, emit_bdd]
        },
        #{
            id => timeout_upstream,
            pattern => <<"timeout|timed out|upstream request timeout|gateway timeout">>,
            severity => medium,
            tags => [latency, network],
            actions => [alert]
        },
        #{
            id => tls_failure,
            pattern =>
                <<"certificate verify failed|tls handshake failed|unknown ca|certificate expired">>,
            severity => high,
            tags => [tls, security],
            actions => [alert, emit_bdd]
        },
        #{
            id => auth_failure,
            pattern => <<"unauthorized|forbidden|invalid token|jwt|authentication failed">>,
            severity => high,
            tags => [auth, security],
            actions => [alert, emit_bdd]
        },
        #{
            id => null_pointer,
            pattern =>
                <<"nullpointerexception|nil pointer dereference|undefined is not an object">>,
            severity => high,
            tags => [application, crash],
            actions => [alert, emit_bdd]
        },
        #{
            id => erlang_crash,
            pattern =>
                <<"init terminating in do_boot|crash dump|badmatch|function_clause|case_clause|undef">>,
            severity => high,
            tags => [erlang, crash],
            actions => [alert, emit_bdd]
        },
        #{
            id => python_traceback,
            pattern => <<"traceback \\(most recent call last\\)|exception:|raise ">>,
            severity => high,
            tags => [python, crash],
            actions => [alert, emit_bdd]
        },
        #{
            id => java_exception,
            pattern => <<"exception in thread|caused by:|java\\.lang\\.">>,
            severity => high,
            tags => [java, crash],
            actions => [alert, emit_bdd]
        }
    ].

rule_matches(Rule, Text) ->
    Pattern = maps:get(pattern, Rule),
    case re:run(Text, Pattern, [caseless, unicode]) of
        match -> true;
        nomatch -> false;
        _ -> false
    end.

max_severity(Text, Matches) ->
    RuleSevs = [maps:get(severity, R) || R <- Matches],
    Base =
        case
            has(Text, <<"fatal">>) orelse
                has(Text, <<"panic">>) orelse
                has(Text, <<"segmentation fault">>)
        of
            true ->
                critical;
            false ->
                case has(Text, <<"error">>) of
                    true ->
                        high;
                    false ->
                        case has(Text, <<"warning">>) orelse has(Text, <<"warn">>) of
                            true ->
                                medium;
                            false ->
                                low
                        end
                end
        end,
    lists:foldl(fun max_sev/2, Base, RuleSevs).

max_sev(critical, _) -> critical;
max_sev(_, critical) -> critical;
max_sev(high, low) -> high;
max_sev(high, medium) -> high;
max_sev(high, high) -> high;
max_sev(medium, low) -> medium;
max_sev(medium, medium) -> medium;
max_sev(low, low) -> low;
max_sev(S, _) -> S.

should_escalate(critical, _Matches, _Text) ->
    true;
should_escalate(high, Matches, _Text) ->
    has_action(alert, Matches);
should_escalate(medium, Matches, Text) ->
    has_action(alert, Matches) andalso
        (has(Text, <<"exception">>) orelse has(Text, <<"crash">>));
should_escalate(low, _Matches, _Text) ->
    false.

should_use_ollama(critical, Matches, _Text) ->
    not has_known_pattern(Matches);
should_use_ollama(high, Matches, Text) ->
    (not has_known_pattern(Matches)) orelse
        has(Text, <<"unknown">>);
should_use_ollama(_Severity, _Matches, _Text) ->
    false.

has_known_pattern([]) -> false;
has_known_pattern(_) -> true.

has_action(Action, Matches) ->
    lists:any(
        fun(R) ->
            lists:member(Action, maps:get(actions, R, []))
        end,
        Matches
    ).

has(Bin, Needle) ->
    binary:match(binary:lowercase(Bin), binary:lowercase(Needle)) =/= nomatch.

norm(B) when is_binary(B) ->
    binary:lowercase(B);
norm(L) when is_list(L) ->
    norm(list_to_binary(L)).

unique_flatten(Lists) ->
    lists:usort(lists:flatten(Lists)).
