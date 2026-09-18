%%% VM-local, low-write-frequency hot-code journal. Do not use for per-step data.
%%% Writes AND managed code changes share one node-local lock. Keeping the journal
%%% in persistent_term means a calling process dying cannot erase live overrides.
%%% This is operational provenance, not an attestation/sandbox for hostile BEAM code.
-module(damage_release_overrides).

-export([record/1, remove/1, get/1, list/0, clear/0,
         with_lock/1, snapshot/0, runtime_code_hash/1]).

-define(KEY, {?MODULE, overrides}).
-define(LOCK_MARKER, {?MODULE, lock_held}).

%% The marker is only for same-process re-entrancy, NOT authorization. In
%% particular, nested record/get calls must not release the outer global lock.
-spec with_lock(fun(() -> T)) -> T.
with_lock(Fun) when is_function(Fun, 0) ->
    case erlang:get(?LOCK_MARKER) of
        true -> Fun();
        _ ->
            global:trans({{?MODULE, journal}, self()}, fun() ->
                Previous = erlang:put(?LOCK_MARKER, true),
                try Fun()
                after
                    case Previous of
                        undefined -> erlang:erase(?LOCK_MARKER);
                        _ -> erlang:put(?LOCK_MARKER, Previous)
                    end
                end
            end, [node()])
    end.

-spec record(map()) -> ok.
record(#{module := Module} = Meta) when is_atom(Module) ->
    with_lock(fun() ->
        {Revision, Overrides} = state(),
        write(Revision, maps:put(Module, Meta, Overrides))
    end).

-spec get(module()) -> {ok, map()} | not_found.
get(Module) when is_atom(Module) ->
    with_lock(fun() ->
        {_Revision, Overrides} = state(),
        case maps:find(Module, Overrides) of
            {ok, Meta} -> {ok, Meta};
            error -> not_found
        end
    end).

%% An administrative clear must never make still-loaded overrides disappear
%% from reports. Only remove entries after the base is current and no old code
%% remains. Rollback is responsible for the actual code change/purge.
-spec remove(module()) -> ok | {error, term()}.
remove(Module) when is_atom(Module) ->
    with_lock(fun() ->
        {Revision, Overrides} = state(),
        case maps:find(Module, Overrides) of
            error -> ok;
            {ok, Meta} ->
                case restored(Module, Meta) of
                    true -> write(Revision, maps:remove(Module, Overrides));
                    false -> {error, {override_still_loaded, Module}}
                end
        end
    end).

-spec clear() -> ok | {error, term()}.
clear() ->
    with_lock(fun() ->
        {Revision, Overrides} = state(),
        Remaining = [M || {M, Meta} <- maps:to_list(Overrides), not restored(M, Meta)],
        case Remaining of
            [] -> write(Revision, #{});
            _ -> {error, {overrides_still_loaded, lists:sort(Remaining)}}
        end
    end).

-spec snapshot() -> map().
snapshot() ->
    with_lock(fun() ->
        {Revision, Overrides} = state(),
        Pairs = lists:sort(maps:to_list(Overrides)),
        Public = [public_meta(M, Meta) || {M, Meta} <- Pairs],
        Integrity = case lists:all(fun({M, Meta}) -> consistent(M, Meta) end, Pairs) of
            true -> recorded;
            false -> uncertain
        end,
        #{overrides => Public, override_revision => Revision,
          runtime_modified => Public =/= [], runtime_integrity_status => Integrity}
    end).

-spec list() -> [map()].
list() -> maps:get(overrides, snapshot()).

%% Pure: hash precisely the public snapshot passed by the caller. Never read
%% live registry state here: info/0 must not combine two generations of data.
%% v2 includes transition and old-code state. Timestamps/revisions are excluded.
-spec runtime_code_hash(map()) -> binary().
runtime_code_hash(#{overrides := Overrides} = Info) when is_list(Overrides) ->
    case maps:get(runtime_integrity_status, Info, recorded) of
        recorded ->
            Origin = maps:get(release_origin, Info, package),
            Nft = case Origin of nft -> maps:get(nft, Info, null); _ -> null end,
            Sorted = lists:sort(fun(A, B) ->
                maps:get(module, A) < maps:get(module, B)
            end, Overrides),
            Data = [<<"damagebdd-runtime-code-v2\0">>,
                field(maps:get(release_version, Info, <<>>)),
                field(maps:get(git_sha, Info, <<>>)), field(Origin), nft_field(Nft),
                [override_field(O) || O <- Sorted]],
            hex(crypto:hash(sha256, Data));
        _ -> <<"unknown">>
    end.

state() ->
    case persistent_term:get(?KEY, #{}) of
        {journal_v2, Revision, Overrides} when is_integer(Revision), is_map(Overrides) ->
            {Revision, Overrides};
        Legacy when is_map(Legacy) -> {0, Legacy};
        _ -> error(invalid_override_journal)
    end.

write(Revision, Overrides) ->
    persistent_term:put(?KEY, {journal_v2, Revision + 1, Overrides}),
    ok.

restored(Module, Meta) ->
    Base = maps:get(base_module_md5, Meta, <<>>),
    Base =/= <<>> andalso current_md5(Module) =:= Base andalso
        code:is_loaded(Module) =:= {file, maps:get(base_filename, Meta, undefined)} andalso
        not erlang:check_old_code(Module).

consistent(Module, Meta) ->
    State = maps:get(state, Meta, legacy),
    OldSha = maps:get(old_beam_sha256, Meta, <<>>),
    OldKnown = not erlang:check_old_code(Module) orelse
        (is_binary(OldSha) andalso byte_size(OldSha) =:= 64),
    (State =:= active orelse State =:= rollback_pending) andalso OldKnown andalso
        current_md5(Module) =:= maps:get(loaded_module_md5, Meta, undefined).

current_md5(Module) ->
    case code:is_loaded(Module) of
        false -> undefined;
        _ -> try hex(Module:module_info(md5)) catch _:_ -> undefined end
    end.

public_meta(Module, Meta) ->
    Public = maps:with([source_sha256, beam_sha256, base_beam_sha256,
        loaded_beam_sha256, old_beam_sha256, base_module_md5,
        loaded_module_md5, loaded_at, state], Meta),
    %% Another process may have explicitly purged old code. Do not claim that
    %% generation remains present if the VM no longer has it.
    Old = case erlang:check_old_code(Module) of
        true -> maps:get(old_beam_sha256, Meta, <<"unknown">>);
        false -> <<>>
    end,
    Public#{module => atom_to_binary(Module, utf8), old_beam_sha256 => Old}.

field(Value) ->
    Bin = to_bin(Value),
    [integer_to_binary(byte_size(Bin)), <<":">>, Bin, <<"\0">>].

nft_field(Nft) when is_map(Nft) ->
    [field(nft) | [field(maps:get(K, Nft, <<>>)) || K <-
        [network_id, contract_id, token_id, metadata_cid, asset_cid, package_sha256]]];
nft_field(_) -> field(none).

override_field(O) ->
    [field(maps:get(K, O, <<>>)) || K <- [module, state, source_sha256,
        beam_sha256, base_beam_sha256, loaded_beam_sha256, old_beam_sha256]].

hex(Bin) -> string:lowercase(binary:encode_hex(Bin)).
to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_integer(V) -> integer_to_binary(V);
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V).
