%% Bounded monitor steps used by the dashboard starter schedules.
-module(steps_monitor).
-license("Apache-2.0").
-export([step/6, step_dry/6, matches_step/1]).

-define(TARGET, ["I monitor the authorized URL", Url]).
-define(PROBE, ["I run the", Profile, "monitor with options"]).
-define(ASSERT, ["the monitor check must pass"]).

%% Side-effect-free routing contract used by damage before legacy dry handlers.
matches_step(["I monitor the authorized URL", _Url]) -> true;
matches_step(["I run the", _Profile, "monitor with options"]) -> true;
matches_step(["the monitor check must pass"]) -> true;
matches_step(_) -> false.

%% Only recognized signatures match dry-run. Never resolve DNS, connect, read
%% credentials, sign or pay during preview. Multi-probe baseline costs one unit
%% per request rather than hiding four requests behind a single billable step.
step_dry(Config, Context, KW, N, ?TARGET = Parts, Args) ->
    cost(Config, target(Context, Url), KW, N, Parts, Args, 1);
step_dry(Config, Context, KW, N, ?PROBE = Parts, Args) ->
    case probe_options(Profile, Args) of
        {ok, P, _O} -> cost(Config, Context, KW, N, Parts, Args, damage_monitor:request_count(P));
        {error, _} -> Context#{fail => <<"Invalid monitoring profile or options">>}
    end;
step_dry(Config, Context, KW, N, ?ASSERT = Parts, Args) ->
    cost(Config, Context, KW, N, Parts, Args, 1).

step(_Config, Context, _KW, _N, ?TARGET, _Args) -> target(Context, Url);
step(Config, Context, KW, N, ?PROBE = Parts, Args) ->
    case {maps:get(monitor_target_url, Context, undefined), probe_options(Profile, Args)} of
        {Url, {ok, P, O}} when is_binary(Url) ->
            Owner = maps:get(public_key, Context, undefined),
            Result = damage_monitor:run(P, Url, Owner, O),
            cost(Config, Context#{monitor_result => Result}, KW, N, Parts, Args,
                damage_monitor:request_count(P));
        _ -> Context#{fail => <<"Set a valid monitor URL, profile and options first">>}
    end;
step(Config, Context, KW, N, ?ASSERT, _Args) ->
    case maps:get(monitor_result, Context, undefined) of
        #{outcome := Outcome} = Result ->
            formatter:format(Config, print,
                {KW, N, ["Monitor findings (response bodies omitted)"], jsx:encode(Result), Context, success}),
            case Outcome of
                pass -> Context;
                _ -> Context#{fail => iolist_to_binary([
                    <<"Monitoring ">>, atom_to_binary(Outcome, utf8), <<": ">>,
                    lists:join(<<"; ">>, [maps:get(detail, C) || C <- maps:get(checks, Result),
                        maps:get(outcome, C) =/= pass])
                ])}
            end;
        _ -> Context#{fail => <<"No monitoring result exists; no check has passed">>}
    end.

target(Context, Url) ->
    case damage_monitor_target:parse_url(Url) of
        {ok, #{url := Canonical}} ->
            (maps:remove(monitor_result, Context))#{monitor_target_url => Canonical};
        {error, _} -> Context#{fail => <<"Invalid monitor URL: use HTTP(S), without credentials, query or fragment">>}
    end.
probe_options(Profile, Body0) ->
    try
        P = unicode:characters_to_binary(Profile),
        Body = case unicode:characters_to_binary(Body0) of <<>> -> <<"{}">>; B -> B end,
        true = byte_size(Body) =< 2048,
        M = jsx:decode(Body, [return_maps]),
        case damage_monitor:options(P, M) of
            {ok, O} -> {ok, P, O};
            Error -> Error
        end
    catch _:_ -> {error, invalid_monitor_options} end.
cost(Config, Context, KW, N, Parts, Args, Units) ->
    C = steps_utils:step_dry(Config, Context, KW, N, Parts, Args),
    C#{step_spend => maps:get(step_spend, C) * Units}.
