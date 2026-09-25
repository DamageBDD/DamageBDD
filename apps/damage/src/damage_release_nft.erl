%%% NFT release discovery plus explicit account-signed state changes.
%%% Discovery/GET paths remain read-only and public-key-only.
%%% The NFT binds the metadata CID; a trusted LOCAL validating Kubo daemon reads
%%% that metadata. A gateway URL alone is not proof of the returned bytes.
-module(damage_release_nft).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").
-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").
-export([latest/0, latest/1, release/2, token_release/3,
         transfer/3, prepare_transfer/3,
         operator_transfer/2, operator_transfer/3,
         parse_release/1, parse_manifest/1, install_manifest/1, parse_install_manifest/1,
         valid_platform/1, valid_release/1, package_sha256/2,
         prepare_metadata/4, installation/1,
         prepared_installation/1, installation_identity/1,
         contract_source/0, call_return/1, option_value/1, release_answer/6,
         discovery_config/0, verify_publication/3]).
-ifdef(TEST).
-export([select_release/3, token_metadata/2, bounded/2,
         valid_asset_path/1, installation_fields/2, checked_json/1, discover/5,
         transfer_call_result/1]).
-endif.
-define(NFT_SOURCE, "contracts/build_release_nft.aes").
-define(MAX_MANIFEST_BYTES, 4096).
-define(MAX_METADATA_BYTES, 1048576).
-define(MAX_PACKAGE_BYTES, 4294967296).

latest() -> latest(<<>>).
latest(Platform) -> read_release(latest, Platform).
release(Version, Platform) -> read_release({release, Version}, Platform).

read_release(Selector0, Platform0) ->
    guarded(fun() ->
        Platform = text(Platform0),
        require(Platform =:= <<>> orelse valid_platform(Platform), invalid_platform),
        Selector = normalize_selector(Selector0),
        require(Selector =:= latest orelse Platform =/= <<>>, invalid_platform),
        case discovery_config() of
            {ok, Config} ->
                Result = bounded(fun() ->
                    Caller = #{public_key => maps:get(reader, Config), private_key => undefined},
                    Query = fun(F, A) -> chain_query(Caller, maps:get(nft, Config), F, A) end,
                    discover(Selector, Platform, Config, Query, fun installation/1)
                end, maps:get(timeout, Config)),
                log_discovery_error(Platform, Result),
                Result;
            {error, _} = Error ->
                log_discovery_error(Platform, Error),
                Error
        end
    end).

%% The HTTP reader and installation build preflight use the SAME configuration.
%% Do not fall back to the builder's account registry or to a node private key.
%% This validates configuration only; it neither deploys nor mints a contract.
-spec discovery_config() -> {ok, map()} | {error, term()}.
discovery_config() ->
    guarded(fun() -> {ok, read_config()} end).

%% Resolve a single immutable snapshot, then read only that snapshot's metadata.
%% Keep this orchestration testable without a live chain. No search across
%% platforms or fallback to a generic/older artifact is permitted on failure.
discover(Selector, Platform, Config, Query, ReadInstallation) ->
    guarded(fun() ->
        case select_release(Selector, Platform, Query) of
            {ok, Record} ->
                {ok, Install} = must(ReadInstallation(Record)),
                Base = maps:get(gateway, Config),
                Asset = maps:get(asset_cid, Install),
                Path = maps:get(asset_path, Install),
                Meta = maps:get(metadata_cid, Install),
                Suffix = case Path of <<>> -> <<>>; _ -> <<"/", Path/binary>> end,
                {ok, Install#{
                    schema_version => 2,
                    network_id => maps:get(network, Config),
                    contract_id => maps:get(nft, Config),
                    metadata_verification => <<"local_kubo">>,
                    asset_url => <<Base/binary, "/", Asset/binary, Suffix/binary>>,
                    metadata_url => <<Base/binary, "/", Meta/binary>>
                }};
            Error -> Error
        end
    end).

%% Compare every installer-relevant field, not merely a 200 response or a
%% platform string. A reused historical mint must not pass as the latest NFT.
-spec verify_publication(map(), map(), map()) -> ok | {error, term()}.
verify_publication(Mint, ExpectedInstallation, Discovered) ->
    guarded(fun() ->
        MintKeys = [contract_id, token_id, release, platform, git_sha, metadata_cid, asset_cid],
        InstallKeys = [platform, asset_cid, git_sha, asset_path, sha256,
            package_format, architecture],
        require(is_map(Mint) andalso is_map(ExpectedInstallation) andalso
            is_map(Discovered), invalid_publication_identity),
        require(lists:all(fun(K) -> maps:is_key(K, Mint) end, MintKeys) andalso
            lists:all(fun(K) -> maps:is_key(K, ExpectedInstallation) end, InstallKeys),
            incomplete_publication_identity),
        require(lists:all(fun(K) -> maps:get(K, Mint) =:= maps:get(K, ExpectedInstallation) end,
            [platform, asset_cid, git_sha]), inconsistent_publication_identity),
        %% The NFT and final metadata can agree with each other while both
        %% have been relabeled since preparation. Keep the artifact's verified
        %% version authoritative; never derive this expectation from the NFT.
        case maps:find(packaged_release, ExpectedInstallation) of
            {ok, PackagedRelease} ->
                require(valid_release(PackagedRelease) andalso PackagedRelease =/= <<"latest">>,
                    invalid_publication_identity),
                require(maps:get(release, Mint) =:= PackagedRelease,
                    prepared_release_version_mismatch);
            error -> ok
        end,
        NetworkKeys = case maps:is_key(network_id, Mint) of true -> [network_id]; false -> [] end,
        %% Compare presence as well as value: a prepared version cannot later
        %% disappear from the selected metadata and pass as a legacy release.
        BoundInstallKeys = InstallKeys ++ [packaged_release],
        Keys = lists:usort(MintKeys ++ BoundInstallKeys ++ NetworkKeys),
        Expected = maps:merge(maps:with(MintKeys ++ NetworkKeys, Mint),
            maps:with(BoundInstallKeys, ExpectedInstallation)),
        Mismatches = [K || K <- Keys,
            maps:find(K, Discovered) =/= maps:find(K, Expected)],
        require(Mismatches =:= [], {release_discovery_mismatch, Mismatches}),
        ok
    end).

%% Public HTTP errors stay stable. Server logs identify the local failure
%% without exposing raw node replies, keys, complete metadata or request data.
log_discovery_error(_Platform, {ok, _}) -> ok;
log_discovery_error(_Platform, {error, not_found}) -> ok;
log_discovery_error(Platform, {error, Reason}) ->
    ?LOG_WARNING("Release discovery failed platform=~p reason=~p",
        [Platform, discovery_error_tag(Reason)]).

discovery_error_tag({missing_release_config, Key}) -> {missing_release_config, Key};
discovery_error_tag({release_ipfs_http_status, Status}) when is_integer(Status) ->
    {release_ipfs_http_status, Status};
discovery_error_tag(Reason) when is_atom(Reason) -> Reason;
discovery_error_tag(_) -> release_backend_failed.

%% Use the value getters already present in the attached NFT. This deliberately
%% avoids inventing a FATE record field order. Historical records are obtained
%% through release_token + the same token's immutable MetadataMap. No oracle is
%% involved, and latest is resolved only once per request.
select_release(Selector, Platform, Query) ->
    guarded(fun() ->
        Result = case Selector of
            latest ->
                {Function, Args} = case Platform of
                    <<>> -> {"latest_release_value", []};
                    _ -> {"latest_release_value_for", [binary_to_list(Platform)]}
                end,
                case query_option(Query(Function, Args)) of
                    {ok, Answer} -> parse_release(Answer);
                    Error0 -> Error0
                end;
            {release, Version0} ->
                case query_option(Query("release_token", [binary_to_list(Version0), binary_to_list(Platform)])) of
                    {ok, Token} when is_integer(Token), Token > 0 ->
                        token_from_query(Token, Query);
                    {ok, _} -> {error, invalid_release_token};
                    Error0 -> Error0
                end
        end,
        case Result of
            {ok, Record} ->
                require(Platform =:= <<>> orelse maps:get(platform, Record) =:= Platform,
                        release_platform_mismatch),
                case Selector of
                    latest -> ok;
                    {release, Version} ->
                        require(maps:get(release, Record) =:= Version, release_version_mismatch)
                end,
                {ok, Record};
            Error -> Error
        end
    end).

%% Also used to verify an idempotent mint retry BEFORE reusing the old token.
%% Strip any private key supplied by the publisher; this is always a dry run.
token_release(#{public_key := Public}, Contract0, Token) ->
    guarded(fun() ->
        Contract = encoded_id(contract_pubkey, Contract0),
        require(is_integer(Token) andalso Token > 0, invalid_release_token),
        Caller = #{public_key => Public, private_key => undefined},
        token_from_query(Token, fun(F, A) -> chain_query(Caller, Contract, F, A) end)
    end).

%% Transfer a release NFT with an explicit signing keypair.
%% The contract remains authoritative: the caller must own the token or be an
%% approved AEX-141 operator for it. Both authenticated custodial transfers and
%% operator transfers use damage_ae's shared per-account nonce locks.
%% The result explicitly distinguishes confirmed, submitted and unknown writes.
-spec transfer(map(), pos_integer(), binary() | string()) ->
    {ok, map()} | {error, term()}.
transfer(KeyPair0, Token, To0) ->
    guarded(fun() ->
        require(is_integer(Token) andalso Token > 0, invalid_release_token),
        KeyPair = signing_keypair(KeyPair0),
        Contract = configured_nft_contract(),
        To = encoded_id(account_pubkey, To0),
        Call = damage_ae:contract_call_tracked(
            KeyPair,
            Contract,
            contract_source(),
            "transfer",
            transfer_args(To, Token)
        ),
        transfer_call_result(Call)
    end).

%% Prepare once, then simulate the exact transaction returned to the wallet.
%% No signing key is retrieved, no transaction is broadcast, and no nonce or
%% ownership reservation is implied by a successful preflight.
-spec prepare_transfer(binary() | string(), pos_integer(), binary() | string()) ->
    {ok, map()} | {error, term()}.
prepare_transfer(From0, Token, To0) ->
    guarded(fun() ->
        require(is_integer(Token) andalso Token > 0, invalid_release_token),
        From = encoded_id(account_pubkey, From0),
        To = encoded_id(account_pubkey, To0),
        Contract = configured_nft_contract(),
        case damage_ae:contract_call_prepare_checked(
                #{public_key => From}, Contract, contract_source(),
                "transfer", transfer_args(To, Token)) of
            {ok, Tx} ->
                {ok, #{token_id => Token, from => From, to => To,
                       contract_id => Contract, tx => Tx}};
            {error, #{status := rejected} = Rejection} ->
                {error, {release_transfer_rejected, Rejection}};
            {error, Reason} ->
                {error, {release_transfer_failed, Reason}}
        end
    end).

%% Transfer a release NFT using the node keypair as the AEX-141 operator.
-spec operator_transfer(pos_integer(), binary() | string()) ->
    {ok, map()} | {error, term()}.
operator_transfer(Token, To) ->
    operator_transfer(secrets:node_keypair(), Token, To).

%% Explicit-keypair form for a dedicated operator account and for tests. Keep
%% the historical invalid_release_operator_keypair error stable for callers.
-spec operator_transfer(map(), pos_integer(), binary() | string()) ->
    {ok, map()} | {error, term()}.
operator_transfer(KeyPair, Token, To) ->
    case transfer(KeyPair, Token, To) of
        {error, invalid_release_signing_keypair} ->
            {error, invalid_release_operator_keypair};
        Result ->
            Result
    end.

transfer_args(To, Token) ->
    %% AEX-141 transfer/3 is (to, token_id, data). Release transfers attach no
    %% receiver data, so option(string) is Sophia None.
    [binary_to_list(To), Token, "None"].

transfer_call_result({ok, #{status := Status, tx_hash := _} = Outcome}) when
        Status =:= confirmed; Status =:= submitted; Status =:= submission_unknown ->
    {ok, Outcome};
transfer_call_result({error, #{status := rejected} = Rejection}) ->
    {error, {release_transfer_rejected, Rejection}};
transfer_call_result(Call) when is_map(Call) ->
    case call_return(Call) of
        {ok, _} -> {ok, Call};
        {error, Reason} -> {error, {release_transfer_failed, Reason}}
    end;
transfer_call_result({error, invalid_signing_keypair}) ->
    {error, invalid_release_signing_keypair};
transfer_call_result({error, Reason}) ->
    {error, {release_transfer_failed, Reason}};
transfer_call_result(_) ->
    {error, release_transfer_failed}.

signing_keypair(#{public_key := Public0, private_key := Private})
        when is_binary(Private), byte_size(Private) =:= 64 ->
    #{public_key => encoded_id(account_pubkey, Public0), private_key => Private};
signing_keypair(_) ->
    throw({release_error, invalid_release_signing_keypair}).

configured_nft_contract() ->
    encoded_id(contract_pubkey, required_env(build_release_nft_contract)).

token_from_query(Token, Query) ->
    case query_option(Query("metadata", [Token])) of
        {ok, Metadata} -> token_metadata(Token, Metadata);
        Error -> Error
    end.

token_metadata(Token, {variant, [1, 1], 1, {Metadata}}) when is_map(Metadata) ->
    token_metadata(Token, {'MetadataMap', Metadata});
token_metadata(Token, {'MetadataMap', Metadata}) when is_map(Metadata) ->
    guarded(fun() ->
        require(is_integer(Token) andalso Token > 0, invalid_release_token),
        Fields = [text(maps:get(K, Metadata)) ||
            K <- [<<"release">>, <<"platform">>, <<"git_sha">>, <<"url">>, <<"asset">>]],
        release_fields([integer_to_binary(Token) | Fields])
    end);
token_metadata(_, _) -> {error, invalid_release_metadata_map}.

chain_query(Caller, Contract, Function, Args) ->
    call_return(damage_ae:contract_call_dry(Caller, Contract,
        contract_source(), Function, Args)).

query_option({ok, Value}) ->
    case option_value(Value) of
        none -> {error, not_found};
        Result -> Result
    end;
query_option({error, _}) -> {error, release_query_failed}.

normalize_selector(latest) -> latest;
normalize_selector({release, Value}) ->
    Version = text(Value),
    require(valid_release(Version) andalso Version =/= <<"latest">>, invalid_release),
    {release, Version}.

read_config() ->
    Network = text(required_env(ae_network_id)),
    require(matches(Network, <<"\\A[a-z0-9_-]{1,64}\\z">>), invalid_release_network),
    #{nft => configured_nft_contract(),
      reader => encoded_id(account_pubkey, required_env(build_release_reader_account)),
      network => Network,
      gateway => gateway(application:get_env(damage, build_release_ipfs_gateway, "https://ipfs.io/ipfs")),
      timeout => configured_timeout(build_release_query_timeout, 10000, 60000)}.

required_env(Key) ->
    case application:get_env(damage, Key) of
        {ok, Value} -> Value;
        undefined -> throw({release_error, {missing_release_config, Key}})
    end.
configured_timeout(Key, Default, Max) ->
    Value = application:get_env(damage, Key, Default),
    require(is_integer(Value) andalso Value >= 100 andalso Value =< Max, invalid_release_timeout),
    Value.

option_value({variant, [0, 1], 0, {}}) -> none;
option_value({variant, [0, 1], 1, {Value}}) -> {ok, Value};
option_value({some, Value}) -> {ok, Value};
option_value({'Some', Value}) -> {ok, Value};
option_value(none) -> none;
option_value('None') -> none;
option_value(_) -> {error, invalid_release_option}.

%% Metadata is read by CID from Kubo, NOT from an arbitrary HTTP gateway.
installation(Record) ->
    guarded(fun() ->
        MetaCid = maps:get(metadata_cid, Record),
        require(safe_cid(MetaCid), invalid_release_cid),
        {ok, Meta} = must(ipfs_json(MetaCid)),
        installation_fields(Record, Meta)
    end).

installation_fields(Record, Meta) when is_map(Meta) ->
    guarded(fun() ->
        Install = case maps:find(<<"installation">>, Meta) of
            {ok, I} when is_map(I) -> I;
            _ -> throw({release_error, installation_manifest_missing})
        end,
        require(maps:get(<<"file_ipfs">>, Meta, undefined) =:= maps:get(asset_cid, Record),
                release_asset_mismatch),
        Platform = maps:get(platform, Record),
        {ok, Checked} = must(check_installation(Install, Platform)),
        Version = maps:get(release, Record, undefined),
        require(maps:get(<<"release">>, Meta, Version) =:= Version andalso
            maps:get(<<"release">>, Install, Version) =:= Version, release_version_mismatch),
        require(maps:get(<<"platform">>, Meta, Platform) =:= Platform, release_platform_mismatch),
        require(maps:get(<<"git_sha">>, Meta, maps:get(git_sha, Record)) =:= maps:get(git_sha, Record),
                release_git_sha_mismatch),
        %% Only the installation document may supply packaged_release. The
        %% NFT's release name is not evidence that its package declared it.
        {ok, maps:merge(maps:remove(packaged_release, Record), Checked)}
    end);
installation_fields(_, _) -> {error, invalid_installation_metadata}.

%% A prepared document and a re-read NFT document must be compared using
%% the same validated fields. Neither steps nor HTTP reconstruct this schema.
prepared_installation(Meta) ->
    guarded(fun() ->
        Install = maps:get(<<"installation">>, Meta),
        Record0 = #{platform => maps:get(<<"platform">>, Install),
            asset_cid => maps:get(<<"file_ipfs">>, Meta),
            git_sha => maps:get(<<"git_sha">>, Meta)},
        Record = case maps:find(<<"release">>, Meta) of
            {ok, Version} ->
                require(valid_release(Version) andalso Version =/= <<"latest">>, invalid_installation_release),
                Record0#{release => Version};
            error -> Record0
        end,
        {ok, Actual} = must(installation_fields(Record, Meta)),
        {ok, installation_identity(Actual)}
    end).

installation_identity(Record) ->
    %% The optional packaged_release comes from the validated installation
    %% manifest, not Record.release. Legacy unversioned manifests keep their
    %% seven-field identity; versioned preparations retain the extra binding.
    maps:with([platform, asset_cid, git_sha, asset_path, sha256,
        package_format, architecture, packaged_release], Record).

%% An invalid version in IPFS metadata is a publication/backend failure, not
%% an invalid client selector. Keep it distinct from normalize_selector/1.
check_installation(I, Platform) ->
    guarded(fun() ->
        require(maps:get(<<"schema_version">>, I, undefined) =:= 1, invalid_installation_schema),
        require(maps:get(<<"platform">>, I, undefined) =:= Platform, release_platform_mismatch),
        Path = maps:get(<<"asset_path">>, I, undefined),
        Digest = maps:get(<<"sha256">>, I, undefined),
        Format = maps:get(<<"package_format">>, I, undefined),
        Arch = maps:get(<<"architecture">>, I, undefined),
        require(valid_asset_path(Path), invalid_asset_path),
        require(is_binary(Digest) andalso matches(Digest, <<"\\A[0-9a-f]{64}\\z">>), invalid_package_sha256),
        require(lists:member(Format, [<<"deb">>, <<"pkg.tar.zst">>, <<"rpm">>, <<"apk">>]),
                invalid_package_format),
        require(is_binary(Arch) andalso matches(Arch, <<"\\A[a-z0-9_]{1,32}\\z">>), invalid_package_architecture),
        require(lists:suffix(binary_to_list(<<"-", Arch/binary>>), binary_to_list(Platform)),
                release_architecture_mismatch),
        require(platform_package_format(Platform, Format), release_package_format_mismatch),
        Fields = #{asset_path => Path, sha256 => Digest, package_format => Format, architecture => Arch},
        case maps:find(<<"release">>, I) of
            {ok, Version} ->
                require(valid_release(Version) andalso Version =/= <<"latest">>, invalid_installation_release),
                {ok, Fields#{packaged_release => Version}};
            error -> {ok, Fields}
        end
    end).

%% Known installer targets cannot accept a package from another package manager.
%% Retain extensibility for other explicitly named platform/architecture pairs.
platform_package_format(<<"ubuntu-noble-amd64">>, Format) -> Format =:= <<"deb">>;
platform_package_format(<<"archlinux-x86_64">>, Format) -> Format =:= <<"pkg.tar.zst">>;
platform_package_format(_, _) -> true.

%% Build-side operation BEFORE metadata upload/mint. Read the manifest from the
%% already-uploaded artifact, then independently hash that exact package via
%% Kubo. The builder cannot accidentally bind a local file's checksum to a
%% different file/path in the IPFS artifact. Only bounded JSON is buffered.
prepare_metadata(Meta0, Platform0, Asset0, ManifestPath0) ->
    guarded(fun() ->
        Platform = text(Platform0), Asset = text(Asset0), ManifestPath = text(ManifestPath0),
        require(valid_platform(Platform), invalid_platform),
        require(safe_cid(Asset), invalid_release_cid),
        require(ManifestPath =/= <<>> andalso valid_asset_path(ManifestPath), invalid_asset_path),
        Timeout = configured_timeout(build_release_publish_timeout, 300000, 3600000),
        bounded(fun() ->
            ManifestTarget = <<Asset/binary, "/", ManifestPath/binary>>,
            {ok, Manifest} = must(preparation_ipfs_result(read_installation_manifest,
                ManifestTarget, ipfs_json(ManifestTarget, Timeout))),
            {ok, Fields} = must(check_installation(Manifest, Platform)),
            Path = maps:get(asset_path, Fields),
            Target = case Path of <<>> -> Asset; _ -> <<Asset/binary, "/", Path/binary>> end,
            {ok, Digest} = must(preparation_ipfs_result(hash_installation_package,
                Target, ipfs_result(damage_ipfs:sha256(Target,
                    [{max_bytes, ?MAX_PACKAGE_BYTES}, {timeout, Timeout}])))),
            ExpectedDigest = maps:get(sha256, Fields),
            %% The identity checks stay strict. These are validated public
            %% artifact paths/digests; never include the full metadata/context.
            require(Digest =:= ExpectedDigest,
                {release_package_hash_mismatch, #{
                    manifest_path => ManifestTarget,
                    package_path => Target,
                    expected_sha256 => ExpectedDigest,
                    actual_sha256 => Digest
                }}),
            GitSha = maps:get(<<"git_sha">>, Manifest, <<>>),
            require(is_binary(GitSha) andalso (GitSha =:= <<>> orelse
                matches(GitSha, <<"\\A([0-9a-f]{40}|[0-9a-f]{64})\\z">>)), invalid_git_sha),
            Meta = manifest_release(json_keys(Meta0), Manifest),
            require(maps:get(<<"file_ipfs">>, Meta, Asset) =:= Asset, release_asset_mismatch),
            require(maps:get(<<"git_sha">>, Meta, GitSha) =:= GitSha, release_git_sha_mismatch),
            require(maps:get(<<"platform">>, Meta, Platform) =:= Platform, release_platform_mismatch),
            Install = maps:with([<<"schema_version">>, <<"platform">>, <<"package_format">>,
                <<"architecture">>, <<"asset_path">>, <<"sha256">>, <<"release">>], Manifest),
            Prepared = Meta#{<<"file_ipfs">> => Asset, <<"git_sha">> => GitSha, <<"installation">> => Install},
            require(byte_size(jsx:encode(Prepared)) =< ?MAX_METADATA_BYTES, release_metadata_too_large),
            {ok, Prepared}
        end, Timeout)
    end).

%% New build manifests carry the actual packaged OTP release version. Older
%% documents remain readable, but new builds must not use a CID as the version
%% recorded by the installer's provenance sidecar.
manifest_release(Meta, Manifest) ->
    case maps:find(<<"release">>, Manifest) of
        {ok, Version} ->
            require(valid_release(Version) andalso Version =/= <<"latest">>, invalid_installation_release),
            require(maps:get(<<"release">>, Meta, Version) =:= Version, release_version_mismatch),
            Meta#{<<"release">> => Version};
        error -> Meta
    end.

json_keys(Map) when is_map(Map) ->
    Pairs = [{case K of A when is_atom(A) -> atom_to_binary(A, utf8); _ -> text(K) end, V}
             || {K, V} <- maps:to_list(Map)],
    Result = maps:from_list(Pairs),
    require(map_size(Result) =:= map_size(Map), duplicate_metadata_key),
    Result;
json_keys(_) -> throw({release_error, invalid_installation_metadata}).

%% All Kubo transport, bounds, JSON decoding and hashing live in damage_ipfs.
%% Keep release-domain errors stable without leaking raw backend responses.
ipfs_json(Path) ->
    ipfs_json(Path, configured_timeout(build_release_query_timeout, 10000, 60000)).
ipfs_json(Path, Timeout) ->
    case ipfs_result(damage_ipfs:cat_json(Path,
            [{max_bytes, ?MAX_METADATA_BYTES}, {timeout, Timeout}])) of
        {ok, Map} when is_map(Map) -> {ok, Map};
        {ok, _} -> {error, invalid_installation_metadata};
        Error -> Error
    end.

-ifdef(TEST).
checked_json(Data) when is_binary(Data), byte_size(Data) =< ?MAX_METADATA_BYTES ->
    case ipfs_result(damage_ipfs:decode_json(Data, [{max_bytes, ?MAX_METADATA_BYTES}])) of
        {ok, Map} when is_map(Map) -> {ok, Map};
        {ok, _} -> {error, invalid_installation_metadata};
        Error -> Error
    end;
checked_json(_) -> {error, release_metadata_too_large}.
-endif.

ipfs_result({ok, _} = Result) -> Result;
ipfs_result({error, ipfs_object_too_large}) -> {error, release_ipfs_object_too_large};
ipfs_result({error, invalid_ipfs_json}) -> {error, invalid_installation_metadata};
ipfs_result({error, ipfs_api_must_be_loopback}) -> {error, release_ipfs_api_must_be_loopback};
ipfs_result({error, invalid_ipfs_api_port}) -> {error, invalid_ipfs_api_port};
ipfs_result({error, ipfs_unavailable}) -> {error, release_ipfs_unavailable};
ipfs_result({error, ipfs_timeout}) -> {error, release_ipfs_timeout};
ipfs_result({error, ipfs_stream_error}) -> {error, release_ipfs_stream_error};
ipfs_result({error, invalid_ipfs_api}) -> {error, invalid_ipfs_api};
ipfs_result({error, {ipfs_http_status, Status}}) when
    is_integer(Status), Status >= 100, Status =< 599
-> {error, {release_ipfs_http_status, Status}};
ipfs_result({error, {ipfs_exception, Class, Tag}}) when
    (Class =:= error orelse Class =:= exit orelse Class =:= throw),
    (Tag =:= undef orelse Tag =:= badarg orelse Tag =:= badmatch orelse
     Tag =:= function_clause orelse Tag =:= case_clause orelse Tag =:= badmap orelse
     Tag =:= system_limit orelse Tag =:= nif_not_loaded orelse Tag =:= noproc orelse
     Tag =:= unexpected)
-> {error, {release_ipfs_exception, Class, Tag}};
ipfs_result({error, _}) -> {error, release_ipfs_read_failed}.

%% Build reports get the failing stage and the already-validated public CID
%% path. Discovery HTTP responses keep their existing generic error schema.
preparation_ipfs_result(_Stage, _Path, {ok, _} = Result) -> Result;
preparation_ipfs_result(Stage, Path, {error, Reason}) ->
    {error, {installation_ipfs_failed, Stage, Path, Reason}}.

hex_digest(Bytes) -> string:lowercase(binary:encode_hex(Bytes)).

-spec parse_release(binary() | string()) -> {ok, map()} | {error, term()}.
parse_release(Answer0) ->
    guarded(fun() ->
        Answer = text(Answer0),
        require(byte_size(Answer) =< ?MAX_MANIFEST_BYTES, invalid_release_answer),
        release_fields(binary:split(Answer, <<"|">>, [global]))
    end).

release_fields([Token, Version, Platform, Sha,
        <<"ipfs://", Meta/binary>>, <<"ipfs://", Asset/binary>>]) ->
    require(matches(Token, <<"\\A[1-9][0-9]{0,38}\\z">>), invalid_release_token),
    require(valid_release(Version) andalso Version =/= <<"latest">>, invalid_release),
    require(valid_platform(Platform), invalid_platform),
    require(Sha =:= <<>> orelse matches(Sha, <<"\\A([0-9a-f]{40}|[0-9a-f]{64})\\z">>),
        invalid_git_sha),
    require(safe_cid(Meta) andalso safe_cid(Asset), invalid_release_cid),
    {ok, #{token_id => binary_to_integer(Token), release => Version,
        platform => Platform, git_sha => Sha, metadata_cid => Meta, asset_cid => Asset}};
release_fields(_) -> {error, invalid_release_answer}.

-spec parse_manifest(binary() | string()) -> {ok, map()} | {error, term()}.
parse_manifest(Manifest0) ->
    guarded(fun() ->
        Manifest = text(Manifest0),
        require(byte_size(Manifest) =< ?MAX_MANIFEST_BYTES, invalid_release_manifest),
        case binary:split(Manifest, <<"|">>, [global]) of
            [Token, Version, Platform, Sha, Meta, Asset, Path, Digest] ->
                case release_fields([Token, Version, Platform, Sha, Meta, Asset]) of
                    {ok, Release} ->
                        require(valid_asset_path(Path), invalid_asset_path),
                        require(matches(Digest, <<"\\A[0-9a-f]{64}\\z">>), invalid_package_sha256),
                        {ok, Release#{asset_path => Path, sha256 => Digest}};
                    {error, _} = Error ->
                        Error
                end;
            _ ->
                {error, invalid_release_manifest}
        end
    end).

%% DATA only. Version 2 removes the companion identity; all eleven fields
%% refer to one NFT snapshot. Blank git_sha and asset_path remain significant.
install_manifest(Release) ->
    Values = [<<"damagebdd-install-v2">>, maps:get(network_id, Release),
        maps:get(contract_id, Release), integer_to_binary(maps:get(token_id, Release)),
        maps:get(release, Release), maps:get(platform, Release), maps:get(git_sha, Release),
        maps:get(metadata_cid, Release), maps:get(asset_cid, Release),
        maps:get(asset_path, Release), maps:get(sha256, Release)],
    iolist_to_binary([[Value, <<"\n">>] || Value <- Values]).

%% Parse the exact install sidecar emitted by install_manifest/1. This gives the
%% running node one canonical decoder for NFT provenance rather than duplicating
%% field order/validation in HTTP, installers and verification reports.
-spec parse_install_manifest(binary() | string()) -> {ok, map()} | {error, term()}.
parse_install_manifest(Manifest0) ->
    guarded(fun() ->
        Manifest = text(Manifest0),
        require(byte_size(Manifest) =< ?MAX_MANIFEST_BYTES, invalid_release_manifest),
        Lines0 = binary:split(Manifest, <<"\n">>, [global]),
        Lines = drop_one_trailing_empty(Lines0),
        case Lines of
            [<<"damagebdd-install-v2">>, Network, Contract, Token, Version, Platform, Sha,
             Meta, Asset, Path, Digest] ->
                require(matches(Network, <<"\\A[a-z0-9_-]{1,64}\\z">>), invalid_release_network),
                _ = encoded_id(contract_pubkey, Contract),
                require(matches(Token, <<"\\A[1-9][0-9]{0,38}\\z">>), invalid_release_token),
                require(valid_release(Version) andalso Version =/= <<"latest">>, invalid_release),
                require(valid_platform(Platform), invalid_platform),
                require(Sha =:= <<>> orelse matches(Sha, <<"\\A([0-9a-f]{40}|[0-9a-f]{64})\\z">>),
                    invalid_git_sha),
                require(safe_cid(Meta) andalso safe_cid(Asset), invalid_release_cid),
                require(Path =:= <<>> orelse valid_asset_path(Path), invalid_asset_path),
                require(matches(Digest, <<"\\A[0-9a-f]{64}\\z">>), invalid_package_sha256),
                {ok, #{schema_version => 2, network_id => Network, contract_id => Contract,
                    token_id => binary_to_integer(Token), release => Version, platform => Platform,
                    git_sha => Sha, metadata_cid => Meta, asset_cid => Asset,
                    asset_path => Path, sha256 => Digest}};
            _ ->
                {error, invalid_release_manifest}
        end
    end).

drop_one_trailing_empty([]) -> [];
drop_one_trailing_empty(Lines) ->
    case lists:reverse(Lines) of
        [<<>> | Rest] -> lists:reverse(Rest);
        _ -> Lines
    end.

%% Platform is an opaque release identity, not a fixed DamageBDD distro enum.
%% Keep it bounded and delimiter/path safe, while accepting normal platform
%% identifiers such as ubuntu-22.04-amd64, fedora-40-amd64, macos-15-arm64
%% and future build targets. Installation-specific compatibility is validated
%% separately by check_installation/2 and platform_package_format/2.
valid_platform(Value) when is_binary(Value) ->
    matches(Value, <<"\\A[A-Za-z0-9][A-Za-z0-9._+-]{0,95}\\z">>);
valid_platform(_) ->
    false.
valid_release(Value) when is_binary(Value) ->
    matches(Value, <<"\\A[A-Za-z0-9][A-Za-z0-9._+-]{0,159}\\z">>);
valid_release(_) ->
    false.

%% CID syntax/URL-safety check only, NOT a multihash/content verification.
%% Byte integrity is checked using the SHA-256 committed through the NFT metadata CID.
safe_cid(Value) -> damage_ipfs:valid_cid(Value).
valid_asset_path(Path) -> damage_ipfs:valid_relative_path(Path).

gateway(Value) ->
    Base = string:trim(text(Value), trailing, "/"),
    case uri_string:parse(Base) of
        #{scheme := <<"https">>, host := Host} = Parsed when Host =/= <<>> ->
            require(
                not maps:is_key(userinfo, Parsed) andalso
                    not maps:is_key(query, Parsed) andalso not maps:is_key(fragment, Parsed),
                invalid_release_gateway
            ),
            require(matches(Base, <<"\\A[!-~]+\\z">>), invalid_release_gateway),
            Base;
        _ ->
            throw({release_error, invalid_release_gateway})
    end.

%% Hash only a regular file below the trusted build run directory; no shell
%% commands or untrusted absolute paths. Workspace must not be concurrently
%% writable by an untrusted process (the checks are not an OS sandbox).
-spec package_sha256(file:filename_all(), file:filename_all()) ->
    {ok, binary()} | {error, term()}.
package_sha256(RunDir0, Relative0) ->
    guarded(fun() ->
        Root = filename:absname(binary_to_list(text(RunDir0))),
        Relative = binary_to_list(text(Relative0)),
        Parts = filename:split(Relative),
        require(
            filename:pathtype(Relative) =:= relative andalso Parts =/= [] andalso
                lists:all(fun(P) -> P =/= "." andalso P =/= ".." end, Parts),
            invalid_package_path
        ),
        File = checked_path(Root, Parts),
        case file:open(File, [read, binary, raw]) of
            {ok, Fd} ->
                try
                    hash_file(Fd, crypto:hash_init(sha256))
                after
                    file:close(Fd)
                end;
            {error, _} ->
                {error, package_read_failed}
        end
    end).
checked_path(Dir, [Last]) ->
    File = filename:join(Dir, Last),
    case file:read_link_info(File) of
        {ok, #file_info{type = regular}} -> File;
        _ -> throw({release_error, package_not_regular})
    end;
checked_path(Dir, [Part | Rest]) ->
    Next = filename:join(Dir, Part),
    case file:read_link_info(Next) of
        {ok, #file_info{type = directory}} -> checked_path(Next, Rest);
        _ -> throw({release_error, invalid_package_directory})
    end.
hash_file(Fd, State) ->
    case file:read(Fd, 1048576) of
        {ok, Data} ->
            hash_file(Fd, crypto:hash_update(State, Data));
        eof ->
            {ok, hex_digest(crypto:hash_final(State))};
        {error, _} ->
            {error, package_read_failed}
    end.

bounded(Fun, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() -> Parent ! {Ref, guarded(Fun)} end),
    receive
        {Ref, Result} ->
            erlang:demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, _} ->
            {error, release_query_failed}
    after Timeout ->
        exit(Pid, kill),
        %% DOWN follows any result sent by the same worker; drain that result
        %% after observing DOWN to avoid polluting the HTTP process mailbox.
        receive
            {'DOWN', Monitor, process, Pid, _} -> ok
        end,
        receive
            {Ref, _} -> ok
        after 0 -> ok
        end,
        {error, release_query_timeout}
    end.

%% One decoder for discovery and build steps. Discovery sanitizes these errors
%% in query_option/1; build steps retain the contract failure classification.
call_return(Call) when is_map(Call) ->
    Type = call_return_field(return_type, Call),
    Value = call_return_field(return_value, Call),
    case Type of
        ok -> {ok, Value};
        "ok" -> {ok, Value};
        <<"ok">> -> {ok, Value};
        revert -> {error, {revert, Value}};
        "revert" -> {error, {revert, Value}};
        <<"revert">> -> {error, {revert, Value}};
        undefined -> {error, missing_return_type};
        _ -> {error, {unexpected_return_type, Type, Value}}
    end;
call_return(_) -> {error, contract_call_failed}.

%% The contract wrapper retains raw node fields under binary keys and adds
%% decoded FATE fields under string keys. Prefer those decoded fields before
%% atom/binary aliases, otherwise option_value/1 receives a cb_ bytearray.
%% Use find/2 so an explicitly supplied malformed value is not hidden by a
%% fallback. Keep the general map_value/3 precedence unchanged.
call_return_field(Key, Call) ->
    case maps:find(atom_to_list(Key), Call) of
        {ok, Value} -> Value;
        error -> map_value(Key, Call, undefined)
    end.

contract_source() -> damage_ae:contract_path(damage, ?NFT_SOURCE).

%% Canonical serialization is also the expected oracle answer. Keep it here,
%% not copied into the Gherkin adapter. Validation remains in parse_release/1.
release_answer(Token, Version, Platform, Sha, Meta, Asset) ->
    iolist_to_binary(lists:join(<<"|">>, [integer_to_binary(Token), Version,
        Platform, Sha, <<"ipfs://", Meta/binary>>, <<"ipfs://", Asset/binary>>])).

map_value(Key, Map, Default) when is_map(Map) ->
    maps:get(
        Key,
        Map,
        maps:get(
            atom_to_binary(Key, utf8),
            Map,
            maps:get(atom_to_list(Key), Map, Default)
        )
    );
map_value(_, _, Default) ->
    Default.

encoded_id(Type, Value) ->
    Bin = text(Value),
    try aeser_api_encoder:decode(Bin) of
        {Type, Bytes} when byte_size(Bytes) =:= 32 -> Bin;
        _ -> throw({release_error, invalid_release_identifier})
    catch
        _:_ -> throw({release_error, invalid_release_identifier})
    end.

matches(Value, Pattern) -> re:run(Value, Pattern, [{capture, none}]) =:= match.
text(Bin) when is_binary(Bin) -> Bin;
text(List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) -> Bin;
        _ -> throw({release_error, invalid_release_text})
    end;
text(_) ->
    throw({release_error, invalid_release_text}).
require(true, _) -> ok;
require(false, Reason) -> throw({release_error, Reason}).
must({ok, _} = Ok) -> Ok;
must({error, Reason}) -> throw({release_error, Reason}).
guarded(Fun) ->
    try
        Fun()
    catch
        throw:{release_error, Reason} ->
            {error, Reason};
        Class:_Reason ->
            %% Never log KeyPair, raw chain responses, or request secrets.
            ?LOG_WARNING("Build release operation failed class=~p", [Class]),
            {error, release_backend_failed}
    end.
