%%%-------------------------------------------------------------------
%%% Runtime release override registry.
%%%
%%% The registry is intentionally ephemeral: a VM restart loses both hot code
%%% and this metadata. Operator source files may remain on disk, but they are
%%% never reloaded implicitly on boot.
%%%-------------------------------------------------------------------
-module(damage_release_overrides).

-export([
    record/1,
    remove/1,
    get/1,
    list/0,
    clear/0,
    runtime_code_hash/1
]).

-define(KEY, {?MODULE, overrides}).

-spec record(map()) -> ok.
record(#{module := Module} = Meta0) when is_atom(Module) ->
    Meta = normalize_meta(Meta0),
    Overrides0 = persistent_term:get(?KEY, #{}),
    persistent_term:put(?KEY, maps:put(Module, Meta, Overrides0)),
    ok.

-spec remove(module()) -> ok.
remove(Module) when is_atom(Module) ->
    Overrides0 = persistent_term:get(?KEY, #{}),
    persistent_term:put(?KEY, maps:remove(Module, Overrides0)),
    ok.

-spec get(module()) -> {ok, map()} | not_found.
get(Module) when is_atom(Module) ->
    case maps:find(Module, persistent_term:get(?KEY, #{})) of
        {ok, Meta} -> {ok, Meta};
        error -> not_found
    end.

-spec list() -> [map()].
list() ->
    Overrides = persistent_term:get(?KEY, #{}),
    [public_meta(Meta) || {_Module, Meta} <- lists:sort(maps:to_list(Overrides))].

-spec clear() -> ok.
clear() ->
    persistent_term:erase(?KEY),
    ok.

%% Hash the immutable base identity plus the exact loaded override BEAM hashes.
%% This is not a hash of every OTP dependency; it is a stable DamageBDD runtime
%% code identity suitable for verification reports.
-spec runtime_code_hash(map()) -> binary().
runtime_code_hash(ReleaseInfo) when is_map(ReleaseInfo) ->
    Origin = maps:get(release_origin, ReleaseInfo, package),
    Nft =
        case Origin of
            nft -> maps:get(nft, ReleaseInfo, null);
            _ -> null
        end,
    Base = [
        <<"damagebdd-runtime-code-v1\0">>,
        field(maps:get(release_version, ReleaseInfo, <<>>)),
        field(maps:get(git_sha, ReleaseInfo, <<>>)),
        field(Origin),
        nft_field(Nft)
    ],
    OverrideFields = [override_field(O) || O <- list()],
    lower_hex(crypto:hash(sha256, iolist_to_binary([Base, OverrideFields]))).

normalize_meta(Meta0) ->
    Meta1 = maps:put(loaded_at, maps:get(loaded_at, Meta0, erlang:system_time(second)), Meta0),
    maps:map(fun(_K, V) -> normalize_value(V) end, Meta1).

public_meta(Meta) ->
    Public0 = maps:with(
        [module, source_sha256, beam_sha256, base_module_md5, loaded_module_md5, loaded_at],
        Meta
    ),
    case maps:find(module, Public0) of
        {ok, Module} when is_atom(Module) -> Public0#{module := atom_to_binary(Module, utf8)};
        _ -> Public0
    end.

field(Value) ->
    Bin = to_bin(Value),
    [integer_to_binary(byte_size(Bin)), <<":">>, Bin, <<"\0">>].

nft_field(Nft) when is_map(Nft) ->
    [
        field(maps:get(network_id, Nft, <<>>)),
        field(maps:get(contract_id, Nft, <<>>)),
        field(maps:get(token_id, Nft, <<>>)),
        field(maps:get(metadata_cid, Nft, <<>>)),
        field(maps:get(asset_cid, Nft, <<>>)),
        field(maps:get(package_sha256, Nft, <<>>))
    ];
nft_field(_) ->
    field(<<>>).

override_field(Override) ->
    [
        field(maps:get(module, Override, <<>>)),
        field(maps:get(source_sha256, Override, <<>>)),
        field(maps:get(beam_sha256, Override, <<>>))
    ].

normalize_value(V) when is_list(V) -> unicode:characters_to_binary(V);
normalize_value(V) -> V.

lower_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_integer(V) -> integer_to_binary(V);
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).
