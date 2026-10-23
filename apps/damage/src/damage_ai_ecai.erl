%% Optional DamageBDD AI profile adapter for the ECAI provider registry.
%% Existing damage_ai profile account/skill/size/deadline and result contracts
%% still apply. No agent tools, execution context or embeddings are forwarded.
-module(damage_ai_ecai).
-behaviour(damage_ai_backend).
-export([invoke/2]).
-ifdef(TEST).
-export([normalize_result/2]).
-endif.

invoke(P, #{operation := chat, messages := Messages}) when is_list(P), is_list(Messages) ->
    Timeout = proplists:get_value(timeout_ms, P, 30000),
    Options = #{timeout => Timeout, connect_timeout => min(5000, Timeout),
        queue_timeout_ms => min(5000, Timeout), cluster_attempts => 1,
        max_output_tokens => proplists:get_value(max_output_tokens, P, 1024),
        max_response_bytes => proplists:get_value(max_response_bytes, P, 1048576),
        response_decode => json_binary, store => false},
    try ecai_ollama_pool:chat_messages(bdd, Messages, Options) of
        {ok, Text, Meta} -> normalize_result(Text, Meta);
        _ -> {error, backend_failed}
    catch _:_ -> {error, backend_failed} end;
invoke(_, _) -> {error, invalid_profile}.

%% Do not turn partial OpenAI/Ollama completions into valid task results.
complete(#{provider := openai, status := <<"completed">>}) -> true;
complete(#{provider := openai}) -> false;
complete(#{done_reason := <<"length">>}) -> false;
complete(_) -> true.

normalize_result(Text, Meta) when is_binary(Text), byte_size(Text) > 0, is_map(Meta) ->
    case {complete(Meta), maps:get(model, Meta, undefined)} of
        {true, Model} when is_binary(Model), byte_size(Model) > 0 ->
            Usage0 = #{input_tokens => maps:get(input_tokens, Meta, maps:get(prompt_eval_count, Meta, undefined)),
                output_tokens => maps:get(output_tokens, Meta, maps:get(eval_count, Meta, undefined)),
                total_tokens => maps:get(total_tokens, Meta, undefined)},
            Usage = maps:filter(fun(_, V) -> is_integer(V) andalso V >= 0 end, Usage0),
            {ok, #{text => Text, model => Model, usage => Usage}};
        _ -> {error, backend_failed}
    end;
normalize_result(_, _) -> {error, backend_failed}.
