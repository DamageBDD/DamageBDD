%% Profile recipes are hypotheses. Linked comparisons do not attest steering.
-module(ecai_eval_profiles).
-export([normalize/1, templates/0, capabilities/0, summary/1, comparison/7]).

normalize(B) ->
    ecai_eval_util:keys(B, [<<"schema">>, <<"name">>, <<"objective">>, <<"model">>,
        <<"model_revision">>, <<"quantization">>, <<"tags">>, <<"intervention">>, <<"evaluation_notes">>]),
    ecai_eval_util:enum(maps:get(<<"schema">>, B), [<<"ecai-qwen-profile/v1">>]),
    Model = text(B, <<"model">>, 256),
    ecai_eval_util:require(binary:match(string:lowercase(Model), <<"qwen">>) =/= nomatch, qwen_model_required),
    Revision = case maps:get(<<"model_revision">>, B, null) of
        null -> null; R -> ecai_eval_util:text(R, 256) end,
    Tags = maps:get(<<"tags">>, B, []),
    ecai_eval_util:require(is_list(Tags) andalso length(Tags) =< 16, invalid_profile_tags),
    #{<<"schema">> => <<"ecai-qwen-profile/v1">>, <<"name">> => text(B, <<"name">>, 120),
      <<"objective">> => text(B, <<"objective">>, 2048), <<"model">> => Model,
      <<"model_revision">> => Revision, <<"quantization">> => text(B, <<"quantization">>, 128),
      <<"tags">> => lists:usort([ecai_eval_util:text(T, 48) || T <- Tags]),
      <<"intervention">> => intervention(maps:get(<<"intervention">>, B)),
      <<"evaluation_notes">> => text(B, <<"evaluation_notes">>, 4096)}.
text(B, K, Max) -> ecai_eval_util:text(maps:get(K, B), Max).

intervention(B) ->
    ecai_eval_util:keys(B, [<<"kind">>, <<"hook">>, <<"token_scope">>, <<"normalization">>,
        <<"neurons">>, <<"layer">>, <<"vector_sha256">>, <<"dose_milli">>]),
    Kind = ecai_eval_util:enum(maps:get(<<"kind">>, B), [<<"unconfigured">>, <<"neurons">>, <<"vector">>]),
    case Kind of
        <<"unconfigured">> -> ecai_eval_util:keys(B, [<<"kind">>]), B;
        _ -> configured_intervention(Kind, B)
    end.
configured_intervention(Kind, B) ->
    Scope = ecai_eval_util:enum(maps:get(<<"token_scope">>, B), [<<"generated">>, <<"all">>]),
    Norm = ecai_eval_util:enum(maps:get(<<"normalization">>, B), [<<"absolute">>, <<"residual_norm">>]),
    Base = #{<<"kind">> => Kind, <<"token_scope">> => Scope, <<"normalization">> => Norm},
    case Kind of
        <<"neurons">> ->
            ecai_eval_util:keys(B, [<<"kind">>, <<"token_scope">>, <<"normalization">>, <<"hook">>, <<"neurons">>]),
            ecai_eval_util:enum(maps:get(<<"hook">>, B), [<<"mlp.down_proj.output">>]),
            Ns = maps:get(<<"neurons">>, B),
            ecai_eval_util:require(is_list(Ns) andalso length(Ns) > 0 andalso length(Ns) =< 32, invalid_neurons),
            Normal = [neuron(N) || N <- Ns],
            Pairs = [{maps:get(<<"layer">>, N), maps:get(<<"index">>, N)} || N <- Normal],
            ecai_eval_util:require(length(Pairs) =:= length(lists:usort(Pairs)), duplicate_neuron),
            Base#{<<"hook">> => <<"mlp.down_proj.output">>, <<"neurons">> =>
                [N || {_, N} <- lists:sort(lists:zip(Pairs, Normal))]};
        <<"vector">> ->
            ecai_eval_util:keys(B, [<<"kind">>, <<"token_scope">>, <<"normalization">>, <<"hook">>,
                <<"layer">>, <<"vector_sha256">>, <<"dose_milli">>]),
            Hook = ecai_eval_util:enum(maps:get(<<"hook">>, B), [<<"residual.post_layer">>, <<"mlp.down_proj.output">>]),
            Hash = text(B, <<"vector_sha256">>, 64),
            ecai_eval_util:require(byte_size(Hash) =:= 64 andalso lists:all(fun(C) ->
                (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end, binary_to_list(Hash)), invalid_vector_hash),
            Base#{<<"hook">> => Hook, <<"layer">> => layer(B), <<"vector_sha256">> => Hash, <<"dose_milli">> => dose(B)}
    end.
neuron(N) ->
    ecai_eval_util:keys(N, [<<"layer">>, <<"index">>, <<"dose_milli">>]),
    #{<<"layer">> => layer(N), <<"index">> => ecai_eval_util:integer(maps:get(<<"index">>, N), 0, 1048575),
      <<"dose_milli">> => dose(N)}.
layer(B) -> ecai_eval_util:integer(maps:get(<<"layer">>, B), 0, 1023).
dose(B) -> ecai_eval_util:integer(maps:get(<<"dose_milli">>, B), -4000, 4000).

capabilities() -> #{<<"activation_steering">> => false, <<"execution">> => <<"catalogue_only">>,
    <<"reason">> => <<"The evaluation providers do not apply activation interventions. Save and export recipes; linked results are observational and do not attest that steering occurred.">>}.

templates() -> [template(Name, Objective, Tags) || {Name, Objective, Tags} <- [
    {<<"Grounded answers">>, <<"Answer from supplied references and identify missing evidence without inventing citations.">>, [<<"grounding">>, <<"citations">>]},
    {<<"Erlang patch discipline">>, <<"Produce scoped Erlang changes that compile and pass independently written BDD scenarios.">>, [<<"erlang">>, <<"code">>, <<"bdd">>]},
    {<<"Tool contract discipline">>, <<"Produce schema-valid tool proposals within the task's allowed tool set.">>, [<<"tools">>, <<"json">>]},
    {<<"Calibrated abstention">>, <<"Abstain when evidence is insufficient while retaining accuracy on answerable cases.">>, [<<"uncertainty">>, <<"grounding">>]} ]].
template(Name, Objective, Tags) ->
    #{<<"schema">> => <<"ecai-qwen-profile/v1">>, <<"name">> => Name, <<"objective">> => Objective,
      <<"model">> => <<"Qwen/Qwen3.5-4B">>, <<"model_revision">> => null, <<"quantization">> => <<"unspecified">>,
      <<"tags">> => Tags, <<"intervention">> => #{<<"kind">> => <<"unconfigured">>},
      <<"evaluation_notes">> => <<"Discover on development cases only. Freeze the recipe before test/holdout evaluation. Compare no steering, fixed steering, ECAI-selected steering and simple lookup with identical context and generation limits. Record scenario pass rate, regressions, latency and cost when measured. No activation direction or performance claim is supplied by this template.">>}.

summary(R) ->
    Spec = maps:get(<<"spec">>, R), Cs = maps:get(<<"comparisons">>, R),
    State = case {length(Cs), maps:get(<<"kind">>, maps:get(<<"intervention">>, Spec))} of
        {0, <<"unconfigured">>} -> <<"draft">>;
        {0, _} -> <<"recipe_saved">>;
        _ -> <<"comparison_linked">>
    end,
    (maps:with([<<"id">>, <<"created_at_ms">>], R))#{<<"spec">> => Spec,
        <<"status">> => State, <<"comparison_count">> => length(Cs), <<"steering_attested">> => false}.

%% All run/report inputs are resolved from the authenticated owner's ledger.
%% A caller label describes an experiment; it is never an execution receipt.
comparison(Profile, A, TA, AR, B, TB, BR) ->
    Spec = maps:get(<<"spec">>, Profile),
    ecai_eval_util:require({maps:get(<<"id">>, A), TA} =/= {maps:get(<<"id">>, B), TB}, identical_comparison_arm),
    ecai_eval_util:require(maps:get(<<"split">>, A) =:= maps:get(<<"split">>, B), incompatible_split),
    AT = maps:get(TA, maps:get(<<"targets">>, A)), BT = maps:get(TB, maps:get(<<"targets">>, B)),
    lists:foreach(fun(T) -> ecai_eval_util:require(maps:get(<<"model">>, T) =:= maps:get(<<"model">>, Spec), profile_model_mismatch) end, [AT, BT]),
    Revision = maps:get(<<"model_revision">>, Spec),
    ecai_eval_util:require(Revision =/= null andalso Revision =/= <<"unverified-model-alias">>, profile_revision_required),
    lists:foreach(fun(T) -> ecai_eval_util:require(maps:get(<<"model_revision">>, T, null) =:= Revision, profile_revision_mismatch) end, [AT, BT]),
    AM = maps:get(TA, maps:get(<<"targets">>, AR)), BM = maps:get(TB, maps:get(<<"targets">>, BR)),
    ecai_eval_util:require(maps:get(<<"complete">>, AM) andalso maps:get(<<"complete">>, BM), comparison_incomplete),
    Compared = ecai_eval_stats:compare(AR, TA, BR, TB),
    Keys = [<<"repetitions">>, <<"max_output_tokens">>, <<"knowledge_mode">>, <<"retrieval_k">>, <<"pass_bps">>, <<"min_reviewers">>],
    AC = maps:with(Keys, maps:get(<<"config">>, A)), BC = maps:with(Keys, maps:get(<<"config">>, B)),
    #{<<"baseline">> => maps:get(<<"id">>, A), <<"candidate">> => maps:get(<<"id">>, B),
      <<"baseline_target">> => AT, <<"candidate_target">> => BT, <<"suite_id">> => maps:get(<<"suite_id">>, A),
      <<"split">> => maps:get(<<"split">>, A), <<"comparison">> => Compared,
      <<"baseline_metrics">> => AM, <<"candidate_metrics">> => BM,
      <<"baseline_config">> => AC, <<"candidate_config">> => BC, <<"settings_match">> => AC =:= BC,
      <<"pass_delta_bps">> => maps:get(<<"pass_bps">>, BM) - maps:get(<<"pass_bps">>, AM),
      <<"steering_attested">> => false, <<"model_identity_attested">> => false,
      <<"claim">> => <<"Observed comparison linked by the account owner. Model revision is operator-declared. Activation execution, quantization and causal benefit are not attested. Results are frozen at attachment time.">>}.
