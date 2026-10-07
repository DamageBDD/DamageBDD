%%--------------------------------------------------------------------
%% Convert learned runtime incidents and health recommendations into
%% ordinary repair-queue findings. This module never edits source directly;
%% ecai_patch_manager owns admission, persistence, verification and dispatch.
%%--------------------------------------------------------------------
-module(ecai_repair_feedback).

-export([incident/1, health_report/1, replay/0, finding_from_incident/1]).

incident(Incident) when is_map(Incident) ->
    case enabled() andalso eligible_incident(Incident) of
        true ->
            case finding_from_incident(Incident) of
                {ok, App, Module, Finding, Meta} ->
                    ecai_patch_manager:enqueue_feedback(App, Module, Finding, Meta),
                    ok;
                {skip, _} = Skip -> Skip
            end;
        false ->
            {skip, disabled_or_ineligible}
    end;
incident(_) ->
    {skip, invalid_incident}.

health_report(Report) when is_map(Report) ->
    Status = maps:get(status, Report, unknown),
    EligibleStatus = (Status =:= degraded) orelse (Status =:= fail),
    case enabled() andalso health_feedback_enabled() andalso EligibleStatus of
        true ->
            Logs = maps:get(recent_logs, Report, []),
            Resolution = maps:get(resolution, Report, #{}),
            lists:foreach(fun(Log) -> maybe_health_log(Log, Resolution, Report) end, Logs),
            ok;
        false ->
            {skip, disabled_or_healthy}
    end;
health_report(_) ->
    {skip, invalid_report}.


replay() ->
    case enabled() of
        false -> {skip, disabled};
        true ->
            Limit = replay_limit(),
            Incidents = try ecai_learning_store:log_incidents(Limit) of
                Values when is_list(Values) -> Values;
                _ -> []
            catch
                _:_ -> []
            end,
            lists:foreach(fun(Incident) -> _ = incident(Incident) end, Incidents),
            _ = replay_health_checkpoint(),
            ok
    end.

replay_health_checkpoint() ->
    case health_feedback_enabled() of
        false -> ok;
        true ->
            try ecai_learning_store:get_checkpoint(ecai_health_monitor) of
                {ok, Checkpoint} when is_map(Checkpoint) ->
                    case maps:get(latest_report, Checkpoint, undefined) of
                        Report when is_map(Report) -> health_report(Report);
                        _ -> ok
                    end;
                _ -> ok
            catch
                _:_ -> ok
            end
    end.

replay_limit() ->
    case application:get_env(ecai, code_repair_feedback_replay_limit, 100) of
        N when is_integer(N), N > 0 -> N;
        _ -> 100
    end.

finding_from_incident(Incident) ->
    App = maps:get(application, Incident, undefined),
    Module = maps:get(module, Incident, undefined),
    Learning = maps:get(learning, Incident, #{}),
    Fp0 = maps:get(fingerprint, Incident, undefined),
    case {is_atom(App), is_atom(Module), is_binary(Fp0), is_map(Learning)} of
        {true, true, true, true} ->
            Summary = text(maps:get(summary, Learning, <<>>), 2048),
            FailureMode = text(maps:get(failure_mode, Learning, <<>>), 1536),
            Evidence = join_text(maps:get(observed_evidence, Learning, []), 8, 768),
            Causes = join_text(maps:get(likely_causes, Learning, []), 8, 768),
            Remediation = join_text(maps:get(resolution_instructions, Learning, []), 10, 1024),
            Verification = join_text(maps:get(verification, Learning, []), 10, 768),
            Notes = join_text(maps:get(code_learning_notes, Learning, []), 8, 768),
            FindingFp = prefixed_fp(<<"runtime-feedback:">>, Fp0),
            Finding = #{
                <<"fingerprint">> => FindingFp,
                <<"issue_key">> => <<"runtime_log_feedback">>,
                <<"status">> => <<"open">>,
                <<"severity">> => severity(maps:get(level, Incident, error)),
                <<"title">> => nonempty(Summary, <<"Runtime incident repair feedback">>),
                <<"function">> => atom_to_binary(Module, utf8),
                <<"evidence">> => combine([FailureMode, Evidence, Causes]),
                <<"impact">> => FailureMode,
                <<"remediation">> => combine([Remediation, Notes]),
                <<"verification">> => Verification,
                <<"source">> => <<"ecai_log_learning">>,
                <<"confidence">> => atom_or_binary(maps:get(confidence, Learning, low))
            },
            Meta = #{
                source => runtime_log_learning,
                source_sha256 => maps:get(source_sha256, Incident, undefined),
                incident_fingerprint => Fp0,
                learned_at => maps:get(learned_at, Incident, undefined)
            },
            {ok, App, Module, Finding, Meta};
        _ ->
            {skip, missing_target}
    end.

maybe_health_log(Log, Resolution, Report) when is_map(Log) ->
    App = maps:get(application, Log, undefined),
    Module = maps:get(module, Log, undefined),
    Fp0 = maps:get(fingerprint, Log, undefined),
    case {is_atom(App), is_atom(Module), is_binary(Fp0)} of
        {true, true, true} ->
            Summary = text(maps:get(summary, Resolution, <<>>), 1536),
            Steps = maps:get(steps, Resolution, []),
            RepairSteps = health_steps_text(Steps),
            Finding = #{
                <<"fingerprint">> => prefixed_fp(<<"runtime-feedback:">>, Fp0),
                <<"issue_key">> => <<"periodic_health_feedback">>,
                <<"status">> => <<"open">>,
                <<"severity">> => severity(maps:get(level, Log, error)),
                <<"title">> => <<"Periodic health check correlated runtime failure">>,
                <<"function">> => atom_to_binary(Module, utf8),
                <<"evidence">> => text(maps:get(message, Log, <<>>), 2048),
                <<"impact">> => Summary,
                <<"remediation">> => RepairSteps,
                <<"source">> => <<"ecai_health_monitor">>,
                <<"confidence">> => <<"medium">>
            },
            Meta = #{
                source => periodic_health_feedback,
                health_checked_at => maps:get(checked_at, Report, undefined),
                health_status => maps:get(status, Report, undefined),
                incident_fingerprint => Fp0
            },
            ecai_patch_manager:enqueue_feedback(App, Module, Finding, Meta);
        _ ->
            ok
    end;
maybe_health_log(_, _, _) -> ok.

eligible_incident(Incident) ->
    maps:get(status, Incident, undefined) =:= learned andalso
    confidence_rank(get_in(Incident, [learning, confidence], low)) >=
        confidence_rank(min_confidence()).

enabled() -> application:get_env(ecai, code_repair_feedback_enabled, true) =:= true.
health_feedback_enabled() ->
    application:get_env(ecai, code_health_repair_feedback_enabled, true) =:= true.

min_confidence() ->
    application:get_env(ecai, code_repair_feedback_min_confidence, medium).

confidence_rank(high) -> 3;
confidence_rank(<<"high">>) -> 3;
confidence_rank(medium) -> 2;
confidence_rank(<<"medium">>) -> 2;
confidence_rank(_) -> 1.

severity(emergency) -> <<"critical">>;
severity(alert) -> <<"critical">>;
severity(critical) -> <<"critical">>;
severity(error) -> <<"high">>;
severity(warning) -> <<"medium">>;
severity(<<"emergency">>) -> <<"critical">>;
severity(<<"alert">>) -> <<"critical">>;
severity(<<"critical">>) -> <<"critical">>;
severity(<<"error">>) -> <<"high">>;
severity(<<"warning">>) -> <<"medium">>;
severity(_) -> <<"medium">>.

health_steps_text(Steps) when is_list(Steps) ->
    Actions = [maps:get(action, S, <<>>) || S <- Steps, is_map(S)],
    join_text(Actions, 8, 1024);
health_steps_text(_) -> <<>>.

prefixed_fp(Prefix, Fp) ->
    hash_hex(<<Prefix/binary, Fp/binary>>).

hash_hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= crypto:hash(sha256, Bin)]).

get_in(Map, [], _Default) -> Map;
get_in(Map, [K | Ks], Default) when is_map(Map) ->
    get_in(maps:get(K, Map, Default), Ks, Default);
get_in(_, _, Default) -> Default.

join_text(Values, Limit, MaxEach) when is_list(Values) ->
    Clean = [text(V, MaxEach) || V <- lists:sublist(Values, Limit), text(V, MaxEach) =/= <<>>],
    combine(Clean);
join_text(_, _, _) -> <<>>.

combine(Parts) ->
    iolist_to_binary(lists:join(<<"\n">>, [P || P <- Parts, is_binary(P), P =/= <<>>])).

nonempty(<<>>, Default) -> Default;
nonempty(Value, _Default) -> Value.

atom_or_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
atom_or_binary(B) when is_binary(B) -> B;
atom_or_binary(_) -> <<"low">>.

text(B, Max) when is_binary(B), byte_size(B) =< Max -> B;
text(B, Max) when is_binary(B), Max > 0 -> binary:part(B, 0, Max);
text(L, Max) when is_list(L) -> text(unicode:characters_to_binary(L), Max);
text(A, Max) when is_atom(A) -> text(atom_to_binary(A, utf8), Max);
text(V, Max) -> text(iolist_to_binary(io_lib:format("~p", [V])), Max).
