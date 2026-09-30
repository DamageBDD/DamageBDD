-module(ecai_patch_worker_model_error_tests).

-include_lib("eunit/include/eunit.hrl").

model_error_has_distinct_failure_class_test() ->
    ?assertEqual(
        model_response_error,
        ecai_patch_worker:failure_class(
            {model_response_error, <<"cannot produce patch">>}
        )
    ).
