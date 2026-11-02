%% Single inference boundary for BDD and agent-draft authoring.
%% Existing ECAI roles, endpoint permissions, health and billing receipts apply.
-module(damage_bdd_inference).
-export([options/0, generate/3, available/0, metadata/1]).

available() -> is_pid(whereis(ecai_llm_settings)) andalso is_pid(whereis(ecai_ollama_pool)).
options() -> ecai_llm_settings:bdd_options().
generate(Prompt, Remaining, Route) when is_binary(Prompt), is_integer(Remaining), Remaining > 0 ->
    Queue = min(5000, max(1, Remaining div 4)),
    Options = maps:merge(Route, #{timeout => max(1, Remaining-Queue),
        connect_timeout => min(5000, max(1, Remaining-Queue)),
        queue_timeout_ms => Queue, cluster_attempts => 1, enforce_node_limits => true,
        max_output_tokens => 8192, max_response_bytes => 262144,
        response_decode => json_binary, store => false}),
    %% No raw-client fallback, browser-selected URL/key, native tools or execution.
    case ecai_ollama_pool:generate_json(bdd, Prompt, Options) of
        {ok, Value, Meta} ->
            case complete(Meta) of
                true -> {ok, Value, (metadata(Meta))#{routing_revision => maps:get(routing_revision, Route)}};
                false -> {error, incomplete_model_reply}
            end;
        Error -> Error
    end.
complete(#{provider := openai, status := <<"completed">>}) -> true;
complete(#{provider := openai}) -> false;
complete(#{done_reason := <<"length">>}) -> false;
complete(#{stop_reason := <<"max_tokens">>}) -> false;
complete(_) -> true.
metadata(Meta) -> maps:with([provider, model, model_digest, node_id, role, cache_hit,
    inference_receipt_id, prompt_eval_count, eval_count, input_tokens, output_tokens,
    total_tokens, wall_duration_ms], Meta).
