-module(ecai_repair_inference).

%% Provider-neutral adapter. The existing Ollama/OpenAI pool remains authoritative
%% for routing; this module only supplies a capsule-bearing request.
-export([request/3, normalize/2]).

-spec request(binary(), map(), map()) -> {ok, map()} | {error, term()}.
request(Prompt, Capsule, Opts) when is_binary(Prompt), is_map(Capsule), is_map(Opts) ->
    Request = #{
        task => repair,
        prompt => Prompt,
        messages => [#{role => <<"user">>, content => Prompt}],
        repair_capsule => Capsule,
        metadata => #{
            capsule_id => ecai_repair_capsule:id(Capsule),
            repair_capsule => Capsule
        }
    },
    case maps:get(inference_fun, Opts, undefined) of
        Fun when is_function(Fun, 2) -> safe_call(fun() -> Fun(Request, Opts) end, custom_fun);
        Fun when is_function(Fun, 1) -> safe_call(fun() -> Fun(Request) end, custom_fun);
        undefined -> request_adapter(Request, Opts);
        Other -> {error, {invalid_inference_fun, Other}}
    end.

request_adapter(Request, Opts) ->
    case maps:get(inference_adapter, Opts, undefined) of
        {Module, Function} when is_atom(Module), is_atom(Function) ->
            safe_call(fun() -> apply(Module, Function, [Request]) end, {Module, Function});
        {Module, Function, Extra} when is_atom(Module), is_atom(Function), is_list(Extra) ->
            safe_call(fun() -> apply(Module, Function, [Request | Extra]) end, {Module, Function});
        undefined ->
            probe(Request);
        Other ->
            {error, {invalid_inference_adapter, Other}}
    end.

probe(Request) ->
    Candidates = [
        {ecai_inference_pool, submit, [repair, Request]},
        {ecai_inference_pool, request, [repair, Request]},
        {ecai_inference, repair, [Request]},
        {ecai_ollama, generate, [maps:get(prompt, Request)]}
    ],
    probe_candidates(Candidates).

probe_candidates([{Module, Function, Args} | Rest]) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            case erlang:function_exported(Module, Function, length(Args)) of
                true -> safe_call(fun() -> apply(Module, Function, Args) end, {Module, Function});
                false -> probe_candidates(Rest)
            end;
        _ ->
            probe_candidates(Rest)
    end;
probe_candidates([]) ->
    {error, no_inference_adapter_available}.

safe_call(Fun, Adapter) ->
    try
        normalize(Fun(), Adapter)
    catch
        Class:Reason:Stack -> {error, {inference_failed, Adapter, Class, Reason, Stack}}
    end.

-spec normalize(term(), term()) -> {ok, map()} | {error, term()}.
normalize({error, _} = Error, _Adapter) -> Error;
normalize({ok, Value}, Adapter) -> normalize_value(Value, Adapter);
normalize(Value, Adapter) -> normalize_value(Value, Adapter).

normalize_value(Value, Adapter) when is_binary(Value) ->
    {ok, #{content => Value, backend => Adapter, raw => Value}};
normalize_value(Value, Adapter) when is_list(Value) ->
    {ok, #{content => iolist_to_binary(Value), backend => Adapter, raw => Value}};
normalize_value(Map, Adapter) when is_map(Map) ->
    case content(Map) of
        undefined -> {ok, #{content => <<>>, backend => Adapter, raw => Map}};
        Content -> {ok, #{content => Content, backend => Adapter, raw => Map}}
    end;
normalize_value(Value, Adapter) ->
    {ok, #{
        content => iolist_to_binary(io_lib:format("~0tp", [Value])),
        backend => Adapter,
        raw => Value
    }}.

content(#{content := C}) -> to_binary(C);
content(#{response := C}) -> to_binary(C);
content(#{text := C}) -> to_binary(C);
content(#{message := #{content := C}}) -> to_binary(C);
content(_) -> undefined.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> iolist_to_binary(Value);
to_binary(Value) -> iolist_to_binary(io_lib:format("~0tp", [Value])).
