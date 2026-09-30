-module(ecai_patch_worker_source_block_tests).

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
                ecai_patch_worker:
                    source_snapshot_block_kind(
                        #{kind => Kind}
                    )
            )
        end,
        Kinds
    ).

transient_snapshot_failures_remain_retryable_test() ->
    Kinds = [
        invalid_base_commit,
        cannot_read_source_from_base,
        git_timeout,
        undefined
    ],
    lists:foreach(
        fun(Kind) ->
            ?assertNot(
                ecai_patch_worker:
                    source_snapshot_block_kind(
                        #{kind => Kind}
                    )
            )
        end,
        Kinds
    ),
    ?assertNot(
        ecai_patch_worker:
            source_snapshot_block_kind(timeout)
    ).
