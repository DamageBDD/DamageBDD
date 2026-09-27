-module(ecai_patch_verifier_tests).

-include_lib("eunit/include/eunit.hrl").

valid_patch_test() ->
    Patch = <<
        "diff --git a/apps/ecai/src/a.erl b/apps/ecai/src/a.erl\n"
        "--- a/apps/ecai/src/a.erl\n"
        "+++ b/apps/ecai/src/a.erl\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    ?assertEqual(ok, ecai_patch_verifier:validate_patch(Patch)).

reject_unrelated_path_test() ->
    Patch = <<
        "diff --git a/rebar.config b/rebar.config\n"
        "--- a/rebar.config\n"
        "+++ b/rebar.config\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    ?assertMatch({error, {patch_path_not_allowed, _}},
                 ecai_patch_verifier:validate_patch(Patch)).

reject_parent_traversal_test() ->
    Patch = <<
        "diff --git a/apps/ecai/../../etc/passwd b/apps/ecai/../../etc/passwd\n"
        "--- a/apps/ecai/../../etc/passwd\n"
        "+++ b/apps/ecai/../../etc/passwd\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    >>,
    ?assertMatch({error, {patch_path_not_allowed, _}},
                 ecai_patch_verifier:validate_patch(Patch)).
