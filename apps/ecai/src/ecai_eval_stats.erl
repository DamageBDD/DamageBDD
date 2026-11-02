%% Planned denominators include errors, interruptions and unreviewed responses.
-module(ecai_eval_stats).
-export([report/3, compare/4, brief/2]).

report(Run, Suite, Attempts) ->
    Config = maps:get(<<"config">>, Run),
    Rows = report_rows(Run, Attempts),
    Targets = lists:usort([maps:get(<<"target_id">>, R) || R <- Rows]),
    Slices = lists:usort([slice(R) || R <- Rows]),
    ByTarget = maps:from_list([{T, summarize([R || R <- Rows, maps:get(<<"target_id">>, R) =:= T], maps:get(<<"pass_bps">>, Config))} || T <- Targets]),
    Summary = gated_summary(Rows, Config, ByTarget),
    Summary#{<<"run_id">> => maps:get(<<"id">>, Run), <<"suite_id">> => maps:get(<<"suite_id">>, Run),
             <<"targets">> => ByTarget,
             <<"human_review">> => human_agreement(Attempts),
             <<"slices">> => maps:from_list([{S, summarize([R || R <- Rows, slice(R) =:= S], maps:get(<<"pass_bps">>, Config))} || S <- Slices]),
             <<"cases">> => Rows, <<"dataset_coverage">> => ecai_eval_spec:coverage(Suite),
             <<"grader_version">> => ecai_eval_grader:version(),
             <<"recommendations">> => recommendations(Rows),
             <<"cost">> => #{<<"amount">> => null, <<"reason">> => <<"No authoritative provider billing data. Request and token ceilings are not a currency budget.">>}}.
report_rows(Run, Attempts) ->
    Authorized = maps:get(<<"reviewer_ids">>, Run),
    Min = maps:get(<<"min_reviewers">>, maps:get(<<"config">>, Run)),
    [row(T, maps:get(maps:get(<<"id">>, T), Attempts, #{}), Authorized, Min) || T <- maps:get(<<"plan">>, Run)].
brief(Run, Attempts) ->
    Rows = report_rows(Run, Attempts), Config = maps:get(<<"config">>, Run),
    Targets = lists:usort([maps:get(<<"target_id">>, X) || X <- Rows]),
    ByTarget = maps:from_list([{T, summarize([X || X <- Rows, maps:get(<<"target_id">>, X) =:= T], maps:get(<<"pass_bps">>, Config))} || T <- Targets]),
    gated_summary(Rows, Config, ByTarget).
gated_summary(Rows, Config, Targets) ->
    B = summarize(Rows, maps:get(<<"pass_bps">>, Config)),
    B#{<<"release_gate">> => maps:get(<<"release_gate">>, B) andalso map_size(Targets)>0 andalso
        lists:all(fun(V) -> maps:get(<<"release_gate">>, V) end, maps:values(Targets))}.
row(T, A, Authorized, Min) ->
    C = T,
    Status = ecai_eval_grader:verdict(A, Min, Authorized),
    Expected = maps:get(<<"evidence_ids">>, C), Selected = maps:get(<<"retrieved_ids">>, A, []),
    Recall = case Expected of [] -> null; _ -> length([E || E <- Expected, lists:member(E, Selected)]) / length(Expected) end,
    maps:merge(T, #{<<"status">> => Status, <<"domain">> => maps:get(<<"domain">>, C),
                    <<"dimension">> => maps:get(<<"dimension">>, C), <<"group">> => maps:get(<<"group">>, C),
                    <<"latency_ms">> => maps:get(<<"latency_ms">>, A, null),
                    <<"critical_failures">> => critical_count(A, Status),
                    <<"failed_checks">> => [maps:with([<<"id">>, <<"type">>, <<"reason">>], Ch) || Ch <- maps:get(<<"checks">>, maps:get(<<"grade">>, A, #{}), []), maps:get(<<"status">>, Ch) =/= <<"pass">>],
                    <<"retrieval_recall">> => Recall}).
slice(R) -> iolist_to_binary([maps:get(<<"target_id">>, R), <<" / ">>, maps:get(<<"domain">>, R), <<" / ">>, maps:get(<<"dimension">>, R)]).
summarize(Rows, Threshold) ->
    N = length(Rows), Counts = count([maps:get(<<"status">>, R) || R <- Rows]),
    Pass = maps:get(<<"pass">>, Counts, 0),
    Critical = lists:sum([maps:get(<<"critical_failures">>, R) || R <- Rows]),
    Complete = N > 0 andalso lists:all(fun(R) -> lists:member(maps:get(<<"status">>, R), [<<"pass">>, <<"fail">>]) end, Rows),
    Latencies = lists:sort([L || R <- Rows, L <- [maps:get(<<"latency_ms">>, R)], is_number(L)]),
    Groups = lists:usort([{maps:get(<<"target_id">>, R), maps:get(<<"group">>, R)} || R <- Rows]),
    GoodGroups = length([G || G <- Groups, lists:all(fun(R) -> maps:get(<<"status">>, R) =:= <<"pass">> end,
                [R || R <- Rows, {maps:get(<<"target_id">>, R), maps:get(<<"group">>, R)} =:= G])]),
    #{<<"planned">> => N, <<"counts">> => Counts, <<"pass_bps">> => case N of 0 -> 0; _ -> (Pass * 10000) div N end,
      <<"critical_failures">> => Critical, <<"complete">> => Complete,
      <<"release_gate">> => Complete andalso Critical =:= 0 andalso Pass * 10000 >= Threshold * N,
      <<"threshold_bps">> => Threshold, <<"p50_latency_ms">> => quantile(Latencies, 0.50),
      <<"p95_latency_ms">> => quantile(Latencies, 0.95), <<"latency_samples">> => length(Latencies),
      <<"group_all_repeats_pass">> => #{<<"passed">> => GoodGroups, <<"total">> => length(Groups),
        <<"wilson_95_descriptive">> => wilson(GoodGroups, length(Groups)),
        <<"caveat">> => <<"Groups are declared dataset clusters, not independent trials. This interval is descriptive, not a population guarantee.">>}}.
count(Values) -> lists:foldl(fun(V, M) -> maps:update_with(V, fun(X) -> X + 1 end, 1, M) end, #{}, Values).
quantile([], _) -> null;
quantile(L, Q) -> lists:nth(max(1, ceil(length(L) * Q)), L).
wilson(_, 0) -> null;
wilson(K, N) ->
    Z = 1.95996398454, P = K / N, D = 1 + Z * Z / N,
    C = (P + Z * Z / (2 * N)) / D,
    H = Z * math:sqrt((P * (1 - P) + Z * Z / (4 * N)) / N) / D,
    #{<<"low">> => max(0.0, C-H), <<"high">> => min(1.0, C+H)}.
recommendations(Rows) ->
    Types = lists:usort([maps:get(<<"type">>, C) || R <- Rows, C <- maps:get(<<"failed_checks">>, R)]),
    States = lists:usort([maps:get(<<"status">>, R) || R <- Rows]),
    [#{<<"failure_type">> => T, <<"recommendation">> => advice(T)} || T <- lists:usort(Types ++ [S || S <- States, S =/= <<"pass">>, S =/= <<"fail">>])].
advice(<<"citation_ids">>) -> <<"Inspect retrieved reference IDs and source coverage; citation presence alone does not establish entailment.">>;
advice(<<"paper_trade">>) -> <<"Inspect the paper replay's risk-contract failure. Keep risk limits external to the model; do not interpret replay profit as a live-trading guarantee.">>;
advice(<<"tool_allowlist">>) -> <<"Inspect the proposed tool and schema; enforce permissions outside the model.">>;
advice(<<"indeterminate">>) -> <<"Complete independent rubric reviews; resolve ambiguous anchors in a NEW suite version, not by changing this run's gold labels.">>;
advice(<<"uncertain">>) -> <<"The request may have reached the provider. Check provider records before explicitly starting a replacement run.">>;
advice(<<"error">>) -> <<"Inspect the redacted execution reason and provider health. Infrastructure errors are not model-quality passes.">>;
advice(_) -> <<"Inspect the failed assertion and transcript; add a reviewed development regression case before changing prompts, retrieval or model configuration.">>.

%% Exact pairing, no cherry-picked denominator. Compare one target in each run.
compare(A, TA, B, TB) ->
    ecai_eval_util:require(maps:get(<<"suite_id">>, A) =:= maps:get(<<"suite_id">>, B), incompatible_suite),
    RA = by_case(A, TA), RB = by_case(B, TB),
    ecai_eval_util:require(map_size(RA) > 0 andalso lists:sort(maps:keys(RA)) =:= lists:sort(maps:keys(RB)), incompatible_cases),
    Pairs = [{maps:get(K, RA), maps:get(K, RB)} || K <- lists:sort(maps:keys(RA))],
    Counts = count([pair_label(X, Y) || {X, Y} <- Pairs]),
    #{<<"pairs">> => length(Pairs), <<"counts">> => Counts,
      <<"note">> => <<"Each case passes only when all its repetitions pass. Incomplete pairs are reported, not dropped. Compare configuration fingerprints before attributing changes to the model.">>}.
by_case(R, Target) ->
    Rows = [X || X <- maps:get(<<"cases">>, R), maps:get(<<"target_id">>, X) =:= Target],
    Ids = lists:usort([maps:get(<<"case_id">>, X) || X <- Rows]),
    maps:from_list([{I, collapse([maps:get(<<"status">>, X) || X <- Rows, maps:get(<<"case_id">>, X) =:= I])} || I <- Ids]).
collapse(S) -> case lists:all(fun(X) -> X =:= <<"pass">> end, S) of true -> <<"pass">>; false ->
    case lists:all(fun(X) -> lists:member(X, [<<"pass">>, <<"fail">>]) end, S) of true -> <<"fail">>; false -> <<"incomplete">> end end.
pair_label(<<"incomplete">>, _) -> <<"incomplete">>;
pair_label(_, <<"incomplete">>) -> <<"incomplete">>;
pair_label(<<"pass">>, <<"pass">>) -> <<"both_pass">>;
pair_label(<<"fail">>, <<"fail">>) -> <<"both_fail">>;
pair_label(<<"fail">>, <<"pass">>) -> <<"candidate_improvement">>;
pair_label(<<"pass">>, <<"fail">>) -> <<"candidate_regression">>.

critical_count(A, Status) ->
    G = maps:get(<<"grade">>, A, #{}), Machine = maps:get(<<"critical_failures">>, G, 0),
    case maps:get(<<"human_critical">>, G, false) andalso Status =:= <<"fail">> andalso Machine =:= 0 of
        true -> 1; false -> Machine end.
human_agreement(Attempts) ->
    Trials = [[maps:get(<<"verdict">>, V) || V <- maps:values(maps:get(<<"reviews">>, A, #{}))] || A <- maps:values(Attempts),
                 maps:get(<<"human_required">>, maps:get(<<"grade">>, A, #{}), false)],
    Multi = [Vs || Vs <- Trials, length(Vs)>=2],
    Pairs = lists:append([[{X,Y} || {I,X} <- lists:zip(lists:seq(1,length(Vs)), Vs),
                                  {J,Y} <- lists:zip(lists:seq(1,length(Vs)), Vs), I<J] || Vs <- Multi]),
    N = length(Pairs), Matches = length([ok || {X,Y} <- Pairs, X=:=Y]),
    #{<<"rubric_trials">> => length(Trials), <<"multiply_reviewed_trials">> => length(Multi),
      <<"disagreement_trials">> => length([ok || Vs <- Multi, length(lists:usort(Vs))>1]),
      <<"reviewer_pairs">> => N, <<"observed_pair_agreement">> => case N of 0 -> null; _ -> Matches/N end,
      <<"note">> => <<"Observed agreement only; not a calibrated accuracy or inter-rater reliability guarantee.">>}.
