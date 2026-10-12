-module(ecai_ollama_model_registry).

-export([
    list/0,
    resolve/1,
    show/1,
    process_models/0
]).

-define(PROFILES, [rag, code, strict]).

list() ->
    Base = base_models(pool_status()),
    Enhanced = lists:append([enhanced_models(M) || M <- Base]),
    Aliases = aliases(Base),
    dedupe_by_name(Base ++ Enhanced ++ Aliases).

resolve(Name0) ->
    Name = to_binary(Name0),
    case [M || M <- list(), maps:get(name, M) =:= Name] of
        [Model | _] -> {ok, Model};
        [] -> {error, model_not_found}
    end.

show(Name) ->
    case resolve(Name) of
        {ok, Model} ->
            {ok, #{
                <<"modified_at">> => maps:get(modified_at, Model, now_iso8601()),
                <<"details">> => maps:get(details, Model, #{}),
                <<"capabilities">> => maps:get(capabilities, Model, [<<"completion">>]),
                <<"model_info">> => #{
                    <<"ecai.public_name">> => maps:get(name, Model),
                    <<"ecai.backend_model">> => maps:get(backend_model, Model),
                    <<"ecai.provider">> => to_binary(maps:get(provider, Model)),
                    <<"ecai.profile">> => to_binary(maps:get(profile, Model))
                }
            }};
        {error, _} = Error -> Error
    end.

process_models() ->
    Status = pool_status(),
    Nodes = maps:get(nodes, Status, []),
    Active = [N || N <- Nodes, maps:get(inflight, N, 0) > 0, chat_capable(N)],
    [process_model(N) || N <- Active].

pool_status() ->
    try ecai_ollama_pool:status() of
        Status when is_map(Status) -> Status;
        _ -> #{}
    catch
        _:_ -> #{}
    end.

base_models(Status) ->
    Nodes = maps:get(nodes, Status, []),
    dedupe_by_target(lists:append([node_models(N) || N <- Nodes, usable_node(N)])).

usable_node(Node) ->
    Health = maps:get(health, Node, unknown),
    Health =/= down andalso chat_capable(Node).

chat_capable(Node) ->
    lists:member(chat, maps:get(roles, Node, [])).

node_models(Node) ->
    Provider = maps:get(provider, Node, ollama),
    Discovered = maps:get(discovered_models, Node, #{}),
    ModelPairs = case maps:size(Discovered) of
        0 -> configured_model_pairs(Node);
        _ -> maps:to_list(Discovered)
    end,
    [base_model(Provider, Model, Info, Node) || {Model, Info} <- ModelPairs].

configured_model_pairs(Node) ->
    case maps:get(configured_models, Node, all) of
        all -> [{maps:get(default_model, Node), #{}}];
        [] -> [{maps:get(default_model, Node), #{}}];
        Models -> [{M, #{}} || M <- Models]
    end.

base_model(Provider, Model0, Info0, Node) ->
    Model = to_binary(Model0),
    Info = ensure_map(Info0),
    Digest = first_nonempty([
        maps:get(digest, Info, <<>>),
        maps:get(Model, maps:get(configured_digests, Node, #{}), <<>>)
    ]),
    #{
        name => public_name(Provider, Model),
        backend_model => Model,
        provider => Provider,
        profile => passthrough,
        digest => Digest,
        size => int_or_zero(maps:get(size, Info, 0)),
        modified_at => normalize_time(
            maps:get(modified_at, Info, maps:get(created, Info, undefined))
        ),
        details => ensure_map(maps:get(details, Info, #{})),
        capabilities => capabilities(Info)
    }.

public_name(ollama, Model) -> Model;
public_name(openai, Model) -> <<"openai/", Model/binary>>;
public_name(Provider, Model) -> <<(to_binary(Provider))/binary, "/", Model/binary>>.

enhanced_models(Base) ->
    [Base#{
        name => enhanced_name(maps:get(name, Base), Profile),
        profile => Profile,
        digest => virtual_digest(Base, Profile)
    }
     || Profile <- ?PROFILES].

enhanced_name(BaseName, rag) -> <<"ecai/", BaseName/binary, "-rag-v1">>;
enhanced_name(BaseName, code) -> <<"ecai/", BaseName/binary, "-code-v1">>;
enhanced_name(BaseName, strict) -> <<"ecai/", BaseName/binary, "-strict-v1">>.

aliases([]) -> [];
aliases(Base) ->
    DefaultBackend = to_binary(application:get_env(
        ecai, ollama_api_default_model,
        application:get_env(ecai, code_ollama_model, "qwen3-coder:30b")
    )),
    Preferred = case [M || M <- Base, maps:get(backend_model, M) =:= DefaultBackend] of
        [M | _] -> M;
        [] -> hd(Base)
    end,
    [
        Preferred#{name => <<"ecai/chat:latest">>, profile => rag,
            digest => virtual_digest(Preferred, rag)},
        Preferred#{name => <<"ecai/code:latest">>, profile => code,
            digest => virtual_digest(Preferred, code)}
    ].

virtual_digest(Base, Profile) ->
    Material = term_to_binary({
        ecai_ollama_virtual_model_v1,
        maps:get(provider, Base),
        maps:get(backend_model, Base),
        maps:get(digest, Base, <<>>),
        Profile
    }, [deterministic]),
    binary:encode_hex(crypto:hash(sha256, Material)).

capabilities(Info) ->
    case maps:get(capabilities, Info, []) of
        Caps when is_list(Caps), Caps =/= [] -> [to_binary(C) || C <- Caps];
        _ -> [<<"completion">>]
    end.

dedupe_by_name(Models) ->
    maps:values(lists:foldl(
        fun(M, Acc) -> Acc#{maps:get(name, M) => M} end,
        #{}, Models
    )).

dedupe_by_target(Models) ->
    maps:values(lists:foldl(
        fun(M, Acc) ->
            Key = {maps:get(provider, M), maps:get(backend_model, M)},
            case maps:is_key(Key, Acc) of
                true -> Acc;
                false -> Acc#{Key => M}
            end
        end,
        #{}, Models
    )).

process_model(Node) ->
    Model = maps:get(default_model, Node, <<>>),
    Provider = maps:get(provider, Node, ollama),
    Digest = maps:get(Model, maps:get(configured_digests, Node, #{}), <<>>),
    #{
        <<"name">> => public_name(Provider, Model),
        <<"model">> => public_name(Provider, Model),
        <<"digest">> => Digest,
        <<"size">> => 0,
        <<"size_vram">> => 0,
        <<"context_length">> => 0,
        <<"details">> => #{}
    }.

ensure_map(M) when is_map(M) -> M;
ensure_map(_) -> #{}.

int_or_zero(I) when is_integer(I), I >= 0 -> I;
int_or_zero(_) -> 0.

first_nonempty([]) -> <<>>;
first_nonempty([H | T]) when is_binary(H), byte_size(H) > 0 -> H;
first_nonempty([_ | T]) -> first_nonempty(T).

normalize_time(undefined) -> now_iso8601();
normalize_time(I) when is_integer(I), I > 0 ->
    try calendar:system_time_to_rfc3339(I, [{unit, second}, {offset, "Z"}]) of
        S -> to_binary(S)
    catch _:_ -> now_iso8601()
    end;
normalize_time(V) -> to_binary(V).

now_iso8601() ->
    to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [
        {unit, second}, {offset, "Z"}
    ])).

to_binary(B) when is_binary(B) -> B;
to_binary(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_binary(L) when is_list(L) -> unicode:characters_to_binary(L);
to_binary(I) when is_integer(I) -> integer_to_binary(I);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).
