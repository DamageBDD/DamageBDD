%%% Read-only discovery and explicit publisher operations for build-release NFTs.
%%% Config is an OTP application-env proplist. HTTP callers cannot select a
%%% contract, caller account, gateway, source file, or contract entrypoint.
-module(damage_release_nft).
-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/file.hrl").
-include_lib("kernel/include/logger.hrl").

-export([
    latest/0, latest/1,
    release/2,
    parse_release/1,
    parse_manifest/1,
    install_manifest/1,
    valid_platform/1,
    valid_release/1,
    deploy_index/2,
    publish/4,
    package_sha256/2
]).
-ifdef(TEST).
-export([decode_snapshot/4, option_value/1, bounded/2, valid_asset_path/1]).
-endif.

-define(INDEX_SOURCE, "contracts/build_release_index.aes").
-define(MAX_MANIFEST_BYTES, 4096).

-spec latest() -> {ok, map()} | {error, term()}.
latest() -> read_release(latest, <<>>).
-spec latest(binary() | string()) -> {ok, map()} | {error, term()}.
latest(Platform) -> read_release(latest, Platform).
-spec release(binary() | string(), binary() | string()) -> {ok, map()} | {error, term()}.
release(Release, Platform) -> read_release({release, Release}, Platform).

read_release(Selector0, Platform0) ->
    guarded(fun() ->
        Platform = text(Platform0),
        require(Platform =:= <<>> orelse valid_platform(Platform), invalid_platform),
        Selector = normalize_selector(Selector0),
        require(Selector =:= latest orelse Platform =/= <<>>, invalid_platform),
        Config = read_config(),
        {Function, Args} =
            case Selector of
                latest ->
                    {"latest_release", [binary_to_list(Platform)]};
                {release, Version} ->
                    {"get_release", [binary_to_list(Version), binary_to_list(Platform)]}
            end,
        Timeout = maps:get(timeout, Config),
        bounded(
            fun() ->
                %% contract_call_dry/5 in the supplied damage_ae uses the public
                %% account/nonce only. Its private_key pattern is unused. Do NOT
                %% replace this with contract_call/5 (which signs and broadcasts).
                PublicCaller = #{public_key => maps:get(reader, Config), private_key => undefined},
                Call = damage_ae:contract_call_dry(
                    PublicCaller, maps:get(index, Config), index_source(), Function, Args
                ),
                case call_return(Call) of
                    {ok, Snapshot} -> decode_snapshot(Snapshot, Config, Selector, Platform);
                    {error, _} -> {error, release_query_failed}
                end
            end,
            Timeout
        )
    end).

normalize_selector(latest) ->
    latest;
normalize_selector({release, Version0}) ->
    Version = text(Version0),
    require(valid_release(Version) andalso Version =/= <<"latest">>, invalid_release),
    {release, Version}.

read_config() ->
    Base = publisher_config(),
    Reader = encoded_id(account_pubkey, required_env(build_release_reader_account)),
    Network = text(required_env(ae_network_id)),
    require(matches(Network, <<"\\A[a-z0-9_-]{1,64}\\z">>), invalid_release_network),
    Gateway = gateway(
        application:get_env(damage, build_release_ipfs_gateway, "https://ipfs.io/ipfs")
    ),
    Timeout = application:get_env(damage, build_release_query_timeout, 10000),
    require(
        is_integer(Timeout) andalso Timeout >= 100 andalso Timeout =< 60000,
        invalid_release_query_timeout
    ),
    Base#{reader => Reader, network => Network, gateway => Gateway, timeout => Timeout}.

publisher_config() ->
    #{
        index => encoded_id(contract_pubkey, required_env(build_release_index_contract)),
        nft => encoded_id(contract_pubkey, required_env(build_release_nft_contract))
    }.

required_env(Key) ->
    case application:get_env(damage, Key) of
        {ok, Value} -> Value;
        undefined -> throw({release_error, {missing_release_config, Key}})
    end.

index_source() ->
    damage_ae:contract_path(damage, ?INDEX_SOURCE).

%% damage_ae unwraps the outer FATE tuple in some versions, but not others.
decode_snapshot({tuple, Snapshot}, Config, Selector, Platform) ->
    decode_snapshot(Snapshot, Config, Selector, Platform);
decode_snapshot({Source, Option}, Config, Selector, Platform) ->
    guarded(fun() ->
        SourceId = source_contract_id(Source),
        require(SourceId =:= maps:get(nft, Config), release_source_mismatch),
        case option_value(Option) of
            none ->
                {error, not_found};
            {ok, Manifest} ->
                case parse_manifest(Manifest) of
                    {ok, Release} ->
                        require(
                            Platform =:= <<>> orelse maps:get(platform, Release) =:= Platform,
                            release_platform_mismatch
                        ),
                        case Selector of
                            latest ->
                                ok;
                            {release, Version} ->
                                require(
                                    maps:get(release, Release) =:= Version, release_version_mismatch
                                )
                        end,
                        Base = maps:get(gateway, Config),
                        Asset = maps:get(asset_cid, Release),
                        Path = maps:get(asset_path, Release),
                        Suffix =
                            case Path of
                                <<>> -> <<>>;
                                _ -> <<"/", Path/binary>>
                            end,
                        Meta = maps:get(metadata_cid, Release),
                        {ok, Release#{
                            schema_version => 1,
                            network_id => maps:get(network, Config),
                            index_contract_id => maps:get(index, Config),
                            contract_id => SourceId,
                            asset_url => <<Base/binary, "/", Asset/binary, Suffix/binary>>,
                            metadata_url => <<Base/binary, "/", Meta/binary>>
                        }};
                    {error, _} = Error ->
                        Error
                end;
            {error, _} = Error ->
                Error
        end
    end);
decode_snapshot(_, _, _, _) ->
    {error, invalid_release_snapshot}.

source_contract_id({address, Bytes}) when is_binary(Bytes), byte_size(Bytes) =:= 32 ->
    text(aeser_api_encoder:encode(contract_pubkey, Bytes));
source_contract_id({contract, Bytes}) when is_binary(Bytes), byte_size(Bytes) =:= 32 ->
    text(aeser_api_encoder:encode(contract_pubkey, Bytes));
source_contract_id(Source) ->
    encoded_id(contract_pubkey, Source).

option_value({variant, [0, 1], 0, {}}) -> none;
option_value({variant, [0, 1], 1, {Value}}) -> {ok, Value};
option_value({some, Value}) -> {ok, Value};
option_value({'Some', Value}) -> {ok, Value};
option_value(none) -> none;
option_value('None') -> none;
option_value(_) -> {error, invalid_release_option}.

-spec parse_release(binary() | string()) -> {ok, map()} | {error, term()}.
parse_release(Answer0) ->
    guarded(fun() ->
        Answer = text(Answer0),
        require(byte_size(Answer) =< ?MAX_MANIFEST_BYTES, invalid_release_answer),
        case binary:split(Answer, <<"|">>, [global]) of
            [
                Token,
                Version,
                Platform,
                Sha,
                <<"ipfs://", Meta/binary>>,
                <<"ipfs://", Asset/binary>>
            ] ->
                require(matches(Token, <<"\\A(0|[1-9][0-9]{0,38})\\z">>), invalid_release_token),
                require(valid_release(Version) andalso Version =/= <<"latest">>, invalid_release),
                require(valid_platform(Platform), invalid_platform),
                require(
                    Sha =:= <<>> orelse matches(Sha, <<"\\A([0-9a-f]{40}|[0-9a-f]{64})\\z">>),
                    invalid_git_sha
                ),
                require(safe_cid(Meta) andalso safe_cid(Asset), invalid_release_cid),
                {ok, #{
                    token_id => binary_to_integer(Token),
                    release => Version,
                    platform => Platform,
                    git_sha => Sha,
                    metadata_cid => Meta,
                    asset_cid => Asset
                }};
            _ ->
                {error, invalid_release_answer}
        end
    end).

-spec parse_manifest(binary() | string()) -> {ok, map()} | {error, term()}.
parse_manifest(Manifest0) ->
    guarded(fun() ->
        Manifest = text(Manifest0),
        require(byte_size(Manifest) =< ?MAX_MANIFEST_BYTES, invalid_release_manifest),
        case binary:split(Manifest, <<"|">>, [global]) of
            [Token, Version, Platform, Sha, Meta, Asset, Path, Digest] ->
                case
                    parse_release(
                        iolist_to_binary(
                            lists:join(
                                <<"|">>,
                                [Token, Version, Platform, Sha, Meta, Asset]
                            )
                        )
                    )
                of
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

%% This is DATA, not shell code. All fields have already been validated.
%% Fixed twelve-line wire format; blank git_sha and asset_path are significant.
-spec install_manifest(map()) -> binary().
install_manifest(Release) ->
    Values = [
        <<"damagebdd-install-v1">>,
        maps:get(network_id, Release),
        maps:get(index_contract_id, Release),
        maps:get(contract_id, Release),
        integer_to_binary(maps:get(token_id, Release)),
        maps:get(release, Release),
        maps:get(platform, Release),
        maps:get(git_sha, Release),
        maps:get(metadata_cid, Release),
        maps:get(asset_cid, Release),
        maps:get(asset_path, Release),
        maps:get(sha256, Release)
    ],
    iolist_to_binary([[Value, <<"\n">>] || Value <- Values]).

valid_platform(Value) when is_binary(Value) ->
    matches(Value, <<"\\A[a-z0-9][a-z0-9_-]{0,95}\\z">>);
valid_platform(_) ->
    false.
valid_release(Value) when is_binary(Value) ->
    matches(Value, <<"\\A[A-Za-z0-9][A-Za-z0-9._+-]{0,159}\\z">>);
valid_release(_) ->
    false.

%% CID syntax/URL-safety check only, NOT a multihash/content verification.
%% Byte integrity is checked using the publisher's on-chain SHA-256.
safe_cid(Value) ->
    matches(Value, <<"\\A(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{20,127})\\z">>).

valid_asset_path(<<>>) ->
    true;
valid_asset_path(Path) when is_binary(Path), byte_size(Path) =< 512 ->
    lists:all(
        fun(Part) ->
            Part =/= <<".">> andalso Part =/= <<"..">> andalso
                matches(Part, <<"\\A[A-Za-z0-9._+-]+\\z">>)
        end,
        binary:split(Path, <<"/">>, [global])
    );
valid_asset_path(_) ->
    false.

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

%% Explicit deployment only. Never called from latest/release/HTTP handlers.
-spec deploy_index(map(), binary() | string()) -> {ok, binary()} | {error, term()}.
deploy_index(KeyPair, NftContract) ->
    guarded(fun() ->
        Nft = encoded_id(contract_pubkey, NftContract),
        {contract_pubkey, Bytes} = aeser_api_encoder:decode(Nft),
        Address = aeser_api_encoder:encode(account_pubkey, Bytes),
        Call = damage_ae:contract_deploy_for(KeyPair, index_source(), [
            binary_to_list(text(Address))
        ]),
        case map_value(contract_id, Call, undefined) of
            undefined -> {error, release_index_deploy_failed};
            Ct -> {ok, encoded_id(contract_pubkey, Ct)}
        end
    end).

%% Called explicitly by the publication BDD step after successful mint/oracle
%% verification. The index verifies the NFT mapping and oracle again on-chain.
-spec publish(map(), map(), binary() | string(), binary() | string()) ->
    {ok, map()} | {error, term()}.
publish(KeyPair, Mint, AssetPath0, Digest0) ->
    guarded(fun() ->
        Config = publisher_config(),
        Source = encoded_id(contract_pubkey, maps:get(contract_id, Mint)),
        require(Source =:= maps:get(nft, Config), release_source_mismatch),
        %% A dot means the root package CID in Gherkin, whose tokenizer may
        %% discard an empty quoted argument. Wire manifests still use "".
        Path =
            case text(AssetPath0) of
                <<".">> -> <<>>;
                Value -> Value
            end,
        Digest = text(Digest0),
        Answer = release_answer(Mint),
        Manifest = <<Answer/binary, "|", Path/binary, "|", Digest/binary>>,
        {ok, Checked} = must(parse_manifest(Manifest)),
        require(text(maps:get(oracle_answer, Mint)) =:= Answer, release_oracle_answer_mismatch),
        Query = oracle_query_arg(maps:get(oracle_query_id, Mint)),
        Args =
            [Query, maps:get(token_id, Checked)] ++
                [
                    binary_to_list(maps:get(K, Checked))
                 || K <-
                        [release, platform, git_sha, metadata_cid, asset_cid, asset_path, sha256]
                ],
        Call = damage_ae:contract_call_payfor_user(
            KeyPair, maps:get(index, Config), index_source(), "publish_release", Args
        ),
        case call_return(Call) of
            {ok, true} ->
                {ok, Checked#{
                    index_contract_id => maps:get(index, Config),
                    contract_id => Source,
                    publish_tx_hash => map_value(tx_hash, Call, null)
                }};
            _ ->
                {error, release_publication_failed}
        end
    end).

release_answer(Mint) ->
    Token = maps:get(token_id, Mint),
    require(is_integer(Token) andalso Token >= 0, invalid_release_token),
    iolist_to_binary([
        integer_to_binary(Token),
        "|",
        text(maps:get(release, Mint)),
        "|",
        text(maps:get(platform, Mint)),
        "|",
        text(maps:get(git_sha, Mint)),
        "|ipfs://",
        text(maps:get(metadata_cid, Mint)),
        "|ipfs://",
        text(maps:get(asset_cid, Mint))
    ]).

oracle_query_arg(Value) ->
    case aeser_api_encoder:decode(text(Value)) of
        {oracle_query_id, Bytes} when byte_size(Bytes) =:= 32 -> {oracle_query, Bytes};
        {oracle_query, Bytes} when byte_size(Bytes) =:= 32 -> {oracle_query, Bytes};
        _ -> throw({release_error, invalid_oracle_query_id})
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
            {ok,
                list_to_binary(
                    string:lowercase(
                        binary_to_list(
                            binary:encode_hex(crypto:hash_final(State))
                        )
                    )
                )};
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

call_return(Call) when is_map(Call) ->
    case map_value(return_type, Call, undefined) of
        ok -> {ok, map_value(return_value, Call, undefined)};
        "ok" -> {ok, map_value(return_value, Call, undefined)};
        <<"ok">> -> {ok, map_value(return_value, Call, undefined)};
        _ -> {error, contract_call_failed}
    end;
call_return(_) ->
    {error, contract_call_failed}.

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
