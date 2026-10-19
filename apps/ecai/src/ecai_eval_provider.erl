%% Explicit server-configured targets only. No caller-selected URLs or secrets.
-module(ecai_eval_provider).
-export([catalog/0, resolve/1, call/4]).

catalog() ->
    try
        {ok, Resolved} = ecai_ollama_pool:evaluation_configurations(),
        Allowed = maps:get(<<"target_ids">>, ecai_eval_policy:node()),
        Nodes = [parse_node(maps:merge(maps:get(client_opts, N, #{}), N)) ||
                    {I, N} <- maps:to_list(Resolved), lists:member(I, Allowed)],
        {ok, Nodes}
    catch _:_ -> {error, invalid_evaluation_target_configuration} end.
resolve(Id) ->
    case catalog() of
        {ok, Nodes} -> case [X || X = {P, _} <- Nodes, maps:get(<<"id">>, P) =:= Id] of
            [{P, O}] -> {ok, P, O}; _ -> {error, target_not_allowed} end;
        Error -> Error
    end.
parse_node(L) when is_list(L) -> parse_node(maps:from_list(L));
parse_node(N) when is_map(N) ->
    Id = ecai_eval_util:text(ecai_eval_util:bin(maps:get(id, N)), 128),
    PB = ecai_eval_util:enum(ecai_eval_util:bin(maps:get(provider, N, ollama)), [<<"ollama">>, <<"openai">>]),
    Provider = case PB of <<"ollama">> -> ollama; <<"openai">> -> openai end,
    Model = ecai_eval_util:text(ecai_eval_util:bin(maps:get(default_model, N, maps:get(model, N, <<>>))), 256),
    Host = maps:get(host, N, case Provider of ollama -> "localhost"; openai -> "api.openai.com" end),
    HB = ecai_eval_util:bin(Host),
    Remote = not lists:member(HB, [<<"localhost">>, <<"127.0.0.1">>, <<"::1">>]),
    Port = maps:get(port, N, case Provider of ollama -> 11434; openai -> 443 end),
    ecai_eval_util:integer(Port, 1, 65535),
    Transport = maps:get(transport, N, case Provider of ollama -> tcp; openai -> tls end),
    %% Remote evaluation transport must authenticate peers (default TLS settings).
    ecai_eval_util:require(not Remote orelse Transport =:= tls, remote_tls_required),
    TLSOpts = maps:get(tls_opts, N, []),
    ecai_eval_util:require(not Remote orelse not lists:member({verify, verify_none}, TLSOpts), peer_verification_required),
    Revision = ecai_eval_util:bin(maps:get(model_revision, N, <<"unverified-model-alias">>)),
    Base = #{<<"id">> => Id, <<"provider">> => PB, <<"model">> => Model,
             <<"model_revision">> => Revision, <<"remote">> => Remote},
    Fingerprint = ecai_eval_util:hash(Base#{<<"host">> => HB, <<"port">> => Port,
        <<"transport">> => ecai_eval_util:bin(Transport),
        <<"base_path">> => ecai_eval_util:bin(maps:get(base_path, N, "/v1")),
        <<"temperature">> => maps:get(temperature, N, case Provider of ollama -> 0; openai -> null end),
        <<"reasoning_effort">> => ecai_eval_util:bin(maps:get(reasoning_effort, N, unspecified))}),
    SafeOpts = maps:with([auth, tls_opts, proxy, base_path, temperature, reasoning_effort,
                         organization, organization_env, project, project_env, connect_timeout], N),
    {Base#{<<"configuration_sha256">> => Fingerprint},
     SafeOpts#{provider => Provider, host => Host, port => Port,
               transport => Transport, model => Model, store => false}}.

call(Target, Messages, Config, NodePolicy) ->
    case resolve(maps:get(<<"id">>, Target)) of
        {ok, Current, Opts} ->
            ecai_eval_util:require(maps:get(<<"configuration_sha256">>, Current) =:=
                                  maps:get(<<"configuration_sha256">>, Target), target_configuration_changed),
            ecai_eval_util:require(byte_size(ecai_eval_util:json(Messages)) =< maps:get(<<"max_prompt_bytes">>, NodePolicy), prompt_too_large),
            Options = Opts#{timeout => maps:get(<<"timeout_ms">>, NodePolicy),
                            max_response_bytes => maps:get(<<"max_response_bytes">>, NodePolicy),
                            max_output_tokens => min(maps:get(<<"max_output_tokens">>, Config), maps:get(<<"max_output_tokens">>, NodePolicy))},
            case ecai_ollama_client:evaluation_chat_with_meta(Messages, Options) of
                {ok, Text, Meta} when is_binary(Text) ->
                    ecai_eval_util:require(byte_size(Text) =< maps:get(<<"max_response_bytes">>, NodePolicy), response_too_large),
                    ecai_eval_util:require(maps:get(done_reason, Meta, undefined) =/= <<"length">>, output_truncated),
                    case maps:get(provider, Meta, undefined) of
                        openai -> ecai_eval_util:require(maps:get(status, Meta, undefined) =:= <<"completed">>, provider_incomplete);
                        _ -> ok
                    end,
                    %% Provider errors/headers may contain sensitive data: never persist them wholesale.
                    SafeMeta = maps:with([provider, model, status, done_reason, response_id, request_id,
                        input_tokens, output_tokens, total_tokens, prompt_eval_count, eval_count, wall_duration_ms], Meta),
                    {ok, Text, ecai_eval_util:public(SafeMeta)};
                {error, _} -> {error, provider_request_failed};
                _ -> {error, invalid_provider_response}
            end;
        Error -> Error
    end.
