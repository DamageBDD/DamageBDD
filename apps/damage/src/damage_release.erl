%%%-------------------------------------------------------------------
%%% damage_release.erl
%%% Running release identity, NFT installation provenance and artifact helpers.
%%%-------------------------------------------------------------------
-module(damage_release).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([
    info/0,
    provenance_path/0,
    read_install_provenance/0,
    install_provenance/1,
    rel_name_vsn/0,
    artifact_candidates/0,
    ipfs_urls/1,
    ipfs_urls/2
]).

-define(DEFAULT_IPFS_GATEWAY, <<"https://ipfs.io/ipfs">>).
-define(DEFAULT_PROVENANCE_FILE, "/var/lib/damage/release_provenance.install").

%% @doc Complete running code/release identity used by /version and BDD reports.
%% NFT origin is asserted only when the post-install provenance sidecar agrees
%% with this running build. Local hot-code overrides are always reported.
-spec info() -> map().
info() ->
    {Name, Vsn} = rel_name_vsn(),
    Snapshot = safe_override_snapshot(),
    Base0 = #{
        application => Name,
        version => Vsn,
        release_version => Vsn,
        git_sha => build_info(git_sha, <<"unknown">>),
        git_sha_short => build_info(git_sha_short, <<"unknown">>),
        build_time => build_info(build_time, <<"unknown">>),
        build_env => build_info(build_env, <<"unknown">>),
        otp_release => to_bin(erlang:system_info(otp_release)),
        erts_version => to_bin(erlang:system_info(version)),
        source_included => source_included(),
        release_origin => package,
        provenance_status => absent,
        provenance_matches_build => false,
        nft => null
    },
    Base1 = apply_install_provenance(maps:merge(Base0, Snapshot)),
    Base1#{runtime_code_hash => runtime_code_hash(Base1)}.

-spec provenance_path() -> file:filename_all().
provenance_path() ->
    case application:get_env(damage, release_provenance_file) of
        {ok, Path} when is_binary(Path) -> binary_to_list(Path);
        {ok, Path} when is_list(Path) -> Path;
        _ -> ?DEFAULT_PROVENANCE_FILE
    end.

-spec read_install_provenance() -> {ok, map()} | {error, term()} | not_found.
read_install_provenance() ->
    case file:read_file(provenance_path()) of
        {ok, Manifest} ->
            damage_release_nft:parse_install_manifest(Manifest);
        {error, enoent} ->
            not_found;
        {error, Why} ->
            {error, {release_provenance_read_failed, Why}}
    end.

%% @doc Validate and atomically persist the install manifest supplied by an NFT
%% installer. This is intentionally not exposed by public HTTP routes.
-spec install_provenance(binary() | string()) -> {ok, map()} | {error, term()}.
install_provenance(Manifest0) ->
    Manifest = to_bin(Manifest0),
    case damage_release_nft:parse_install_manifest(Manifest) of
        {ok, Provenance} ->
            Canonical = damage_release_nft:install_manifest(Provenance),
            Path = provenance_path(),
            case atomic_write(Path, Canonical) of
                ok -> {ok, Provenance};
                {error, Why} -> {error, {release_provenance_write_failed, Why}}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc Get the release name and version from the running node.
%% Falls back to {<<"damage">>, VsnFromApp} if release_handler is unavailable.
-spec rel_name_vsn() -> {binary(), binary()}.
rel_name_vsn() ->
    Releases = try release_handler:which_releases() catch _:_ -> unavailable end,
    case Releases of
        List when is_list(List) ->
            case lists:dropwhile(fun({_, _, _, S}) -> S =/= current end, List) of
                [{Name, Vsn, _Desc, current} | _] ->
                    {to_bin(Name), to_bin(Vsn)};
                _ ->
                    fallback()
            end;
        _ ->
            fallback()
    end.

fallback() ->
    AppName = <<"damage">>,
    VsnBin =
        case application:get_key(damage, vsn) of
            {ok, Vsn} -> to_bin(Vsn);
            _ -> <<"0.0.0">>
        end,
    {AppName, VsnBin}.

%% @doc Return common relx tarball path/name candidates (relative paths).
-spec artifact_candidates() -> [binary()].
artifact_candidates() ->
    {Name, Vsn} = rel_name_vsn(),
    Arch = to_bin(erlang:system_info(system_architecture)),
    Base = <<Name/binary, "-", Vsn/binary>>,
    [
        <<Base/binary, ".tar.gz">>,
        <<"releases/", Vsn/binary, "/", Base/binary, ".tar.gz">>,
        <<Base/binary, "-", Arch/binary, ".tar.gz">>
    ].

-spec ipfs_urls(binary()) -> [binary()].
ipfs_urls(CID) ->
    ipfs_urls(CID, ?DEFAULT_IPFS_GATEWAY).

-spec ipfs_urls(binary(), binary()) -> [binary()].
ipfs_urls(CID, GatewayBase) ->
    [join3(GatewayBase, CID, Candidate) || Candidate <- artifact_candidates()].

apply_install_provenance(Base) ->
    case read_install_provenance() of
        {ok, Provenance} ->
            Nft = nft_info(Provenance),
            case provenance_build_status(Provenance, Base) of
                valid ->
                    Base#{
                        release_origin => nft,
                        provenance_status => valid,
                        provenance_matches_build => true,
                        nft => Nft
                    };
                build_mismatch ->
                    Base#{
                        provenance_status => build_mismatch,
                        provenance_matches_build => false,
                        nft => Nft
                    };
                unverified ->
                    Base#{
                        provenance_status => unverified,
                        provenance_matches_build => false,
                        nft => Nft
                    }
            end;
        not_found ->
            Base;
        {error, Why} ->
            Base#{provenance_status => invalid, provenance_error => to_bin(Why)}
    end.

provenance_build_status(Provenance, Build) ->
    ProvenanceSha = maps:get(git_sha, Provenance, <<>>),
    BuildSha = maps:get(git_sha, Build, <<>>),
    ProvenanceRelease = maps:get(release, Provenance, <<>>),
    BuildRelease = maps:get(release_version, Build, <<>>),
    case {known_sha(ProvenanceSha), known_sha(BuildSha)} of
        {true, true} ->
            case ProvenanceSha =:= BuildSha andalso ProvenanceRelease =:= BuildRelease of
                true -> valid;
                false -> build_mismatch
            end;
        _ ->
            %% A differing known release version is still a definite mismatch.
            %% Matching versions alone are not enough to prove artifact identity.
            case known_release(ProvenanceRelease) andalso
                known_release(BuildRelease) andalso
                ProvenanceRelease =/= BuildRelease
            of
                true -> build_mismatch;
                false -> unverified
            end
    end.

known_release(<<>>) -> false;
known_release(<<"unknown">>) -> false;
known_release(Bin) when is_binary(Bin) -> true;
known_release(_) -> false.

known_sha(<<>>) -> false;
known_sha(<<"unknown">>) -> false;
known_sha(Bin) when is_binary(Bin) -> true;
known_sha(_) -> false.

nft_info(Provenance) ->
    #{
        network_id => maps:get(network_id, Provenance),
        contract_id => maps:get(contract_id, Provenance),
        token_id => maps:get(token_id, Provenance),
        release => maps:get(release, Provenance),
        platform => maps:get(platform, Provenance),
        metadata_cid => maps:get(metadata_cid, Provenance),
        asset_cid => maps:get(asset_cid, Provenance),
        asset_path => maps:get(asset_path, Provenance),
        package_sha256 => maps:get(sha256, Provenance)
    }.

%% Never convert a broken registry into a false "pristine" claim.
safe_override_snapshot() ->
    try damage_release_overrides:snapshot() of
        #{overrides := _, runtime_modified := _, runtime_integrity_status := _} = Snapshot ->
            Snapshot
    catch
        _:_ ->
            #{overrides => [], override_revision => null,
              runtime_modified => null, runtime_integrity_status => unavailable}
    end.

runtime_code_hash(ReleaseInfo) ->
    try damage_release_overrides:runtime_code_hash(ReleaseInfo) of
        Hash when is_binary(Hash) -> Hash
    catch
        _:_ -> <<"unknown">>
    end.

source_included() ->
    case code:lib_dir(damage, src) of
        Dir when is_list(Dir) -> filelib:is_dir(Dir);
        _ -> false
    end.

build_info(Function, Default) ->
    try apply(damage_build_info, Function, []) of
        Value -> to_bin(Value)
    catch
        _:_ -> Default
    end.

atomic_write(Path, Data) ->
    case filelib:ensure_dir(Path) of
        ok ->
            Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
            Tmp = Path ++ ".tmp." ++ Suffix,
            case file:write_file(Tmp, Data, [binary, sync]) of
                ok ->
                    case file:rename(Tmp, Path) of
                        ok ->
                            _ = file:change_mode(Path, 8#644),
                            ok;
                        {error, Why} ->
                            _ = file:delete(Tmp),
                            {error, Why}
                    end;
                {error, Why} ->
                    {error, Why}
            end;
        {error, Why} ->
            {error, Why}
    end.

join3(Base, CID, Tail) ->
    B = trim_slash_right(Base),
    C = trim_slash(CID),
    T = trim_slash_left(Tail),
    <<B/binary, "/", C/binary, "/", T/binary>>.

trim_slash_right(Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        0 ->
            Bin;
        N ->
            case binary:at(Bin, N - 1) of
                $/ -> trim_slash_right(binary:part(Bin, 0, N - 1));
                _ -> Bin
            end
    end.

trim_slash_left(Bin) when is_binary(Bin) ->
    case Bin of
        <<$/, Rest/binary>> -> trim_slash_left(Rest);
        _ -> Bin
    end.

trim_slash(Bin) when is_binary(Bin) ->
    trim_slash_left(trim_slash_right(Bin)).

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_integer(V) -> integer_to_binary(V);
to_bin(V) when is_list(V) -> unicode:characters_to_binary(V);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

-ifdef(TEST).
provenance_build_status_test_() ->
    Sha = binary:copy(<<"a">>, 40),
    P = #{git_sha => Sha, release => <<"1.2.3">>},
    B = #{git_sha => Sha, release_version => <<"1.2.3">>},
    [?_assertEqual(valid, provenance_build_status(P, B)),
     ?_assertEqual(build_mismatch, provenance_build_status(P, B#{release_version := <<"1.2.4">>})),
     ?_assertEqual(build_mismatch, provenance_build_status(P, B#{git_sha := binary:copy(<<"b">>, 40)})),
     ?_assertEqual(unverified, provenance_build_status(P, B#{git_sha := <<"unknown">>})),
     ?_assertEqual(unverified, provenance_build_status(P#{git_sha := <<>>}, B)),
     ?_assertEqual(build_mismatch, provenance_build_status(P#{git_sha := <<>>},
                         B#{release_version := <<"1.2.4">>}))].
-endif.
