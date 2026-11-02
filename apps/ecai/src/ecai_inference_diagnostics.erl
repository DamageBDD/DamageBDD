%% Bounded, allowlisted diagnostics: never publish upstream bodies, headers,
%% prompts, credential names, tokens, filesystem paths or exception terms.
-module(ecai_inference_diagnostics).
-export([public_error/1]).

public_error(undefined) -> undefined;
public_error(none) -> undefined;
public_error({Tag, Status, _Body}) when
    (Tag =:= ollama_http_status orelse Tag =:= openai_http_status orelse
     Tag =:= anthropic_http_status), is_integer(Status) ->
    #{code => Tag, http_status => Status};
public_error({Tag, Status}) when
    (Tag =:= ollama_http_status orelse Tag =:= openai_http_status orelse
     Tag =:= anthropic_http_status), is_integer(Status) ->
    #{code => Tag, http_status => Status};
public_error({Tag, Reason}) when Tag =:= ollama_request_failed;
    Tag =:= openai_request_failed; Tag =:= anthropic_request_failed ->
    (transport_error(Reason))#{code => Tag};
public_error({default_model_unavailable, _}) -> #{code => default_model_unavailable};
public_error({model_digest_mismatch, _}) -> #{code => model_digest_mismatch};
public_error({missing_auth_environment_variable, _}) -> #{code => missing_auth_environment_variable};
public_error({empty_auth_environment_variable, _}) -> #{code => empty_auth_environment_variable};
public_error({cannot_read_auth_file, _, _}) -> #{code => cannot_read_auth_file};
public_error({empty_auth_file, _}) -> #{code => empty_auth_file};
public_error({auth_secret_not_found, _, _}) -> #{code => auth_secret_not_found};
public_error({auth_secret_lookup_failed, _, _, _}) -> #{code => auth_secret_lookup_failed};
public_error({auth_secret_lookup_exception, _, _, _, _}) -> #{code => auth_secret_lookup_exception};
public_error(probe_failed) -> #{code => probe_failed};
public_error(invalid_bearer_token) -> #{code => invalid_bearer_token};
public_error(_) -> #{code => inference_error}.

transport_error({await_up_failed, Why}) -> detail(connect, Why);
transport_error({await_up_exit, Why}) -> detail(connect, Why);
transport_error({gun_not_started, _}) -> detail(connect, noproc);
transport_error({gun_open_exit, Why}) -> detail(connect, Why);
transport_error({await_response_failed, Why}) -> detail(response_headers, Why);
transport_error({await_body_failed, Why}) -> detail(response_body, Why);
transport_error(Why) -> detail(transport, Why).
detail(Phase, Why) -> #{phase => Phase, reason => transport_reason(Why)}.
transport_reason({error, Why}) -> transport_reason(Why);
transport_reason({down, Why}) -> transport_reason(Why);
transport_reason({closed, _}) -> closed;
transport_reason({tls_alert, _}) -> tls_alert;
transport_reason(Why) when Why =:= timeout; Why =:= closed; Why =:= econnrefused;
    Why =:= nxdomain; Why =:= enetunreach; Why =:= ehostunreach;
    Why =:= normal; Why =:= shutdown; Why =:= noproc -> Why;
transport_reason(_) -> request_failed.
