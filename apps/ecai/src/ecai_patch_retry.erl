-module(ecai_patch_retry).

-export([
    is_retryable/1,
    backoff_ms/2,
    next_retry_at_ms/3,
    retry_limit/1,
    due/2
]).

-define(DEFAULT_BASE_MS, 30000).
-define(DEFAULT_MAX_MS, 900000).
-define(DEFAULT_RETRY_LIMIT, 12).

is_retryable({inference_queue_timeout, _Role, _Provider, _Model}) -> true;
is_retryable(inference_queue_timeout) -> true;
is_retryable({inference_failed, Reason}) -> is_retryable(Reason);
is_retryable({inference_pool_exit, Reason}) -> is_retryable(Reason);
is_retryable({inference_pool_exception, _Class, Reason}) -> is_retryable(Reason);
is_retryable({ollama_failed, Reason}) -> is_retryable(Reason);
is_retryable({await_response_failed, Reason}) -> is_retryable(Reason);
is_retryable({await_body_failed, Reason}) -> is_retryable(Reason);
is_retryable({request_failed, Reason}) -> is_retryable(Reason);
is_retryable({down, Reason}) -> is_retryable(Reason);
is_retryable({error, Reason}) -> is_retryable(Reason);
is_retryable({no_eligible_ollama_node, _}) -> true;
is_retryable(Term) when is_tuple(Term), tuple_size(Term) > 0,
                        element(1, Term) =:= no_eligible_ollama_node ->
    true;
is_retryable(no_eligible_ollama_node) -> true;
is_retryable({no_eligible_inference_node, _Role, _Provider, _Model}) -> true;
is_retryable(Term) when is_tuple(Term), tuple_size(Term) > 0,
                        element(1, Term) =:= no_eligible_inference_node ->
    true;
is_retryable(no_eligible_inference_node) -> true;
is_retryable(gun_not_started) -> true;
is_retryable(noproc) -> true;
is_retryable(timeout) -> true;
is_retryable(etimedout) -> true;
is_retryable(econnrefused) -> true;
is_retryable(closed) -> true;
is_retryable(shutdown) -> true;
is_retryable(Reasons) when is_list(Reasons) ->
    lists:any(fun is_retryable/1, Reasons);
is_retryable(Term) when is_tuple(Term), tuple_size(Term) > 1,
                        element(1, Term) =:= ollama_cluster_failed ->
    lists:any(fun is_retryable/1, tl(tuple_to_list(Term)));
is_retryable({inference_cluster_failed, _Role, Errors}) ->
    is_retryable(Errors);
is_retryable(Term) when is_tuple(Term), tuple_size(Term) > 1,
                        element(1, Term) =:= inference_cluster_failed ->
    lists:any(fun is_retryable/1, tl(tuple_to_list(Term)));
is_retryable(_) -> false.

backoff_ms(RetryCount0, Opts) ->
    RetryCount = max(1, RetryCount0),
    Base = positive_int(
        maps:get(retry_base_ms, Opts,
            application:get_env(ecai, code_patch_retry_base_ms, ?DEFAULT_BASE_MS)),
        ?DEFAULT_BASE_MS),
    Max = positive_int(
        maps:get(retry_max_ms, Opts,
            application:get_env(ecai, code_patch_retry_max_ms, ?DEFAULT_MAX_MS)),
        ?DEFAULT_MAX_MS),
    Exponent = min(20, RetryCount - 1),
    min(Max, Base * (1 bsl Exponent)).

next_retry_at_ms(RetryCount, NowMs, Opts) when is_integer(NowMs) ->
    NowMs + backoff_ms(RetryCount, Opts).

retry_limit(Opts) ->
    positive_int(
        maps:get(retry_limit, Opts,
            application:get_env(ecai, code_patch_retry_max_attempts,
                                ?DEFAULT_RETRY_LIMIT)),
        ?DEFAULT_RETRY_LIMIT).

due(Repair, NowMs) when is_map(Repair), is_integer(NowMs) ->
    case maps:get(status, Repair, undefined) of
        queued -> true;
        <<"queued">> -> true;
        retry_wait ->
            maps:get(next_retry_at_ms, Repair, 0) =< NowMs;
        <<"retry_wait">> ->
            maps:get(next_retry_at_ms, Repair, 0) =< NowMs;
        failed ->
            is_retryable(maps:get(error, Repair, undefined));
        <<"failed">> ->
            is_retryable(maps:get(error, Repair, undefined));
        failed_to_start -> true;
        <<"failed_to_start">> -> true;
        _ -> false
    end;
due(_, _) -> false.

positive_int(V, _Default) when is_integer(V), V > 0 -> V;
positive_int(_, Default) -> Default.
