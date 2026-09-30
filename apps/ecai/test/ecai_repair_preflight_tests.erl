-module(ecai_repair_preflight_tests).

-include_lib("eunit/include/eunit.hrl").

structural_snapshot_failures_are_blocked_test() ->
    Kinds = [
        source_not_in_base_commit,
        source_base_mismatch,
        source_outside_repository,
        source_name_missing
    ],
    lists:foreach(
        fun(Kind) ->
            ?assert(
                ecai_repair_preflight:
                    structural_snapshot_failure(
                        #{kind => Kind}
                    )
            )
        end,
        Kinds
    ).

transient_snapshot_failures_are_not_structural_test() ->
    Kinds = [
        invalid_base_commit,
        cannot_read_source_from_base,
        git_timeout,
        undefined
    ],
    lists:foreach(
        fun(Kind) ->
            ?assertNot(
                ecai_repair_preflight:
                    structural_snapshot_failure(
                        #{kind => Kind}
                    )
            )
        end,
        Kinds
    ).

stale_finding_version_is_superseded_test() ->
    Old = <<"old-version">>,
    Current = <<"current-version">>,
    ?assertMatch(
        {superseded, #{
            kind := stale_finding_version,
            finding_version := Old,
            current_finding_version := Current
        }},
        ecai_repair_preflight:decision(
            Old, Current, {ok, #{}}
        )
    ).

matching_clean_snapshot_is_allowed_test() ->
    Version = <<"same-version">>,
    ?assertEqual(
        allow,
        ecai_repair_preflight:decision(
            Version, Version, {ok, #{}}
        )
    ).

matching_structural_mismatch_is_blocked_test() ->
    Version = <<"same-version">>,
    Error = #{
        kind => source_base_mismatch,
        base_commit => <<"abc">>,
        source_path => <<"apps/ecai/src/example.erl">>
    },
    ?assertEqual(
        {blocked, Error},
        ecai_repair_preflight:decision(
            Version, Version, {error, Error}
        )
    ).

matching_transient_error_is_allowed_test() ->
    Version = <<"same-version">>,
    ?assertEqual(
        allow,
        ecai_repair_preflight:decision(
            Version,
            Version,
            {error, #{kind => invalid_base_commit}}
        )
    ).
