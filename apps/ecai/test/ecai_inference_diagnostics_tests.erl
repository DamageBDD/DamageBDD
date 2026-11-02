-module(ecai_inference_diagnostics_tests).
-include_lib("eunit/include/eunit.hrl").

transport_phase_is_preserved_test() ->
    ?assertEqual(#{code => ollama_request_failed, phase => response_body, reason => timeout},
        ecai_inference_diagnostics:public_error(
            {ollama_request_failed, {await_body_failed, {error, timeout}}})),
    ?assertEqual(#{code => ollama_request_failed, phase => connect, reason => shutdown},
        ecai_inference_diagnostics:public_error(
            {ollama_request_failed, {await_up_failed, {down, shutdown}}})).

error_payloads_never_escape_test() ->
    Secret = <<"SECRET-TOKEN-AND-PROMPT">>,
    ?assertEqual(#{code => ollama_http_status, http_status => 401},
        ecai_inference_diagnostics:public_error({ollama_http_status, 401, Secret})),
    ?assertEqual(#{code => auth_secret_lookup_exception},
        ecai_inference_diagnostics:public_error({auth_secret_lookup_exception, node, Secret, error, Secret})),
    ?assertEqual(#{code => inference_error},
        ecai_inference_diagnostics:public_error({unknown, Secret})),
    ?assertEqual(#{code => ollama_request_failed, phase => transport, reason => request_failed},
        ecai_inference_diagnostics:public_error({ollama_request_failed, {unknown, Secret}})).
