%% Configuration is operator-owned proplists. Models/users only select IDs.
-module(damage_agent_policy).
-license("Apache-2.0").
-export([env/2, owner/1, template/2, templates/1, validate_plan/2,
         action/2, needs_approval/1, descriptor/1, terminal/1, limit/3]).

env(K, Default) ->
    proplists:get_value(K, application:get_env(damage, agentic, []), Default).
owner(O) -> is_binary(O) andalso lists:member(O, env(owners,[])).

template(O, Id) ->
    case owner(O) andalso env(enabled,false) =:= true of
        false -> {error, forbidden};
        true ->
            case proplists:get_value(Id,env(templates,[]),undefined) of
                T when is_list(T), T =/= [] -> build_template(Id,T);
                _ -> {error, unknown_template}
            end
    end.

build_template(Id, T) ->
    try
        Actions = proplists:get_value(actions,T,[]),
        true = length(Actions) > 0 andalso length(Actions) =< 24,
        true = length(Actions) =:= length(lists:usort([K || {K,_} <- Actions])),
        lists:foreach(fun validate_action/1,Actions),
        Required = proplists:get_value(required_actions,T,[]),
        true = Required =/= [],
        true = lists:all(fun(K) -> lists:keymember(K,1,Actions) end,Required),
        Verifier = proplists:get_value(verifier,T,undefined),
        ok = validate_verifier(Verifier,Actions),
        {Provider,Options} = env(provider,{damage_agent_llm_ollama,[]}),
        true = is_atom(Provider) andalso is_list(Options),
        Impl = implementation_versions(Provider, Actions, Verifier),
        Profile = #{id => Id, config => T, provider => Provider, provider_options => Options,
                    implementations => Impl},
        {ok, Profile#{hash => damage_agent_codec:hash(#{
            template => config_json(T), provider => atom_to_binary(Provider,utf8),
            provider_options => config_json(Options),
            accounting => config_json(accounting_configuration()), implementations => Impl})}}
    catch _:_ -> {error, invalid_template_configuration}
    end.

%% Config hashing covers server-side capabilities, verifier, model and limits.
%% Preserve Erlang types: false and <<"false">> must not hash identically.
config_json(T) when is_tuple(T) -> [<<"tuple">>,[config_json(X) || X <- tuple_to_list(T)]];
config_json(L) when is_list(L) -> [<<"list">>,[config_json(X) || X <- L]];
config_json(A) when is_atom(A) -> [<<"atom">>,atom_to_binary(A,utf8)];
config_json(V) when is_binary(V) -> [<<"binary">>,V];
config_json(V) when is_integer(V) -> [<<"integer">>,V].

validate_action({K,A}) when is_binary(K), is_list(A) ->
    true = damage_agent_codec:text(K,80),
    Type = proplists:get_value(type,A),
    true = lists:member(Type,[source,artifact,bdd,adapter]),
    Effect = proplists:get_value(effect,A,read),
    true = lists:member(Effect,[read,local_artifact,isolated_write,external_write]),
    case Type of
        source -> true = Effect =:= read,
                  true = is_list(proplists:get_value(root,A)),
                  true = proplists:get_value(files,A,[]) =/= [];
        artifact -> true = Effect =:= local_artifact,
                    true = damage_agent_codec:text(proplists:get_value(name,A),80);
        bdd -> true = damage_agent_codec:text(proplists:get_value(feature,A),65536),
               %% A native BDD runner is trusted code, not an OS sandbox.
               true = proplists:get_value(trusted_native,A,false) =:= true;
        adapter -> true = is_atom(proplists:get_value(module,A)),
                   true = proplists:get_value(module,A) =/= undefined
    end,
    true = is_list(proplists:get_value(args,A,[])),
    ok.
validate_verifier({artifact, Name}, Actions) when is_binary(Name) ->
    true = lists:any(fun({_K,A}) -> proplists:get_value(type,A) =:= artifact andalso
                                   proplists:get_value(name,A) =:= Name end, Actions), ok;
validate_verifier({bdd, Id}, Actions) when is_binary(Id) ->
    A = proplists:get_value(Id,Actions,[]),
    true = proplists:get_value(type,A) =:= bdd,
    true = proplists:get_value(effect,A,read) =:= read, ok;
validate_verifier({adapter, M, Options}, _Actions) when is_atom(M), is_list(Options) -> ok.

templates(O) ->
    [descriptor(P) || {Id,_} <- env(templates,[]), {ok,P} <- [template(O,Id)]].
descriptor(P) ->
    T = maps:get(config,P),
    #{id => maps:get(id,P), policy_hash => maps:get(hash,P),
      description => proplists:get_value(description,T,<<>>),
      accounting => accounting_descriptor(T),
      implementations => maps:get(implementations,P),
      skills => [#{id => K, description => proplists:get_value(description,A,<<>>),
                   effect => proplists:get_value(effect,A,read),
                   approval => needs_approval(A)} || {K,A} <- proplists:get_value(actions,T)]}.
action(P,K) -> proplists:get_value(K,proplists:get_value(actions,maps:get(config,P)),undefined).
needs_approval(A) ->
    case proplists:get_value(effect,A,read) of
        external_write -> true;
        isolated_write -> proplists:get_value(approval,A,true) =/= false;
        _ -> proplists:get_value(approval,A,false) =:= true
    end.
limit(P,K,Default) ->
    N = proplists:get_value(K,maps:get(config,P),Default),
    case is_integer(N) andalso N > 0 of true -> N; false -> Default end.

validate_plan(Plan,P) when is_map(Plan) ->
    try
        true = lists:sort(maps:keys(Plan)) =:=
               lists:sort([<<"op">>,<<"skill">>,<<"args">>,<<"seconds">>,<<"summary">>]),
        true = damage_agent_codec:json_value(Plan,0),
        true = byte_size(damage_agent_codec:canonical(Plan)) =< limit(P,max_plan_bytes,65536),
        true = damage_agent_codec:text(maps:get(<<"summary">>,Plan),2048),
        Args = maps:get(<<"args">>,Plan),
        true = is_map(Args),
        case maps:get(<<"op">>,Plan) of
            <<"act">> ->
                A = action(P,maps:get(<<"skill">>,Plan)),
                true = is_list(A),
                true = maps:get(<<"seconds">>,Plan) =:= 0,
                ok = validate_args(A,Args),
                {ok,Plan};
            <<"wait">> ->
                true = map_size(Args) =:= 0 andalso maps:get(<<"skill">>,Plan) =:= <<>>,
                S = maps:get(<<"seconds">>,Plan),
                true = is_integer(S) andalso S >= 1 andalso S =< limit(P,max_wait_seconds,300),
                {ok,Plan};
            <<"finish">> ->
                true = map_size(Args) =:= 0 andalso maps:get(<<"skill">>,Plan) =:= <<>>,
                true = maps:get(<<"seconds">>,Plan) =:= 0,
                {ok,Plan}
        end
    catch _:_ -> {error, invalid_or_forbidden_plan}
    end;
validate_plan(_,_) -> {error, invalid_or_forbidden_plan}.

validate_args(A, Args) ->
    Schema = case proplists:get_value(type,A) of
        artifact -> [{<<"content">>,{text,proplists:get_value(max_bytes,A,32768)}}];
        _ -> proplists:get_value(args,A,[])
    end,
    true = lists:sort(maps:keys(Args)) =:= lists:sort([K || {K,_} <- Schema]),
    lists:foreach(fun({K,S}) -> true = field(maps:get(K,Args),S) end,Schema), ok.
field(V,{text,N}) -> damage_agent_codec:text(V,N);
field(V,{enum,L}) -> lists:member(V,L);
field(V,{integer,Min,Max}) -> is_integer(V) andalso V >= Min andalso V =< Max;
field(V,boolean) -> is_boolean(V);
field(_,_) -> false.

terminal(S) -> lists:member(S,[completed,failed,cancelled,cancelled_unreconciled,exhausted]).

implementation_versions(Provider, Actions, Verifier) ->
    Adapters = [proplists:get_value(module,A) || {_,A} <- Actions,
                proplists:get_value(type,A) =:= adapter],
    VMods = case Verifier of {adapter,M,_} -> [M]; _ -> [] end,
    BMods = case lists:any(fun({_,A}) -> proplists:get_value(type,A) =:= bdd end,Actions) of
        true -> [steps_http,damage_context,egherkin]; false -> [] end,
    Mods = lists:usort([?MODULE,damage_agent_task,damage_agent_actions,
                       damage_agent_bdd,damage_agent_codec,damage_agent_budget,damage_agent_chain,
                       env(accounting_backend,damage_agent_chain),Provider]++Adapters++VMods++BMods),
    [begin
        {module,M} = code:ensure_loaded(M),
        #{module => atom_to_binary(M,utf8),loaded_code_md5 => binary:encode_hex(M:module_info(md5))}
    end || M <- Mods].


accounting_configuration() ->
    [{required,env(accounting_required,true)},
     {contracts_reviewed,env(accounting_contracts_reviewed,false)},
     {sources,env(accounting_sources,[])},
     {bindings,env(agent_bindings,[])},
     {network,application:get_env(damage,ae_network_id,undefined)}].
accounting_descriptor(T) ->
    case proplists:get_value(accounting,T,disabled) of
        disabled -> #{mode => disabled};
        A when is_list(A) -> #{mode => aeternity, unit => damage_base_units,
            agent_id => proplists:get_value(agent_id,A),
            max_cost_units => proplists:get_value(max_cost_units,A),
            pricing => fixed_per_admitted_invocation}
    end.
