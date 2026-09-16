%%%-------------------------------------------------------------------
%%% DamageBDD build-release NFT + native aeternity oracle steps.
%%%
%%% Flow used by the existing build features:
%%%   1. artifact -> IPFS CID
%%%   2. metadata JSON -> IPFS CID
%%%   3. mint one AEX-141 release NFT
%%%   4. create a zero-fee native oracle query for "latest"
%%%   5. answer that query from the contract-owned oracle
%%%
%%% The permanent release record lives in the NFT contract. Native aeternity
%%% oracles are query/response, so each release creates a new immutable oracle
%%% answer rather than overwriting an existing key/value record.
%%%-------------------------------------------------------------------
-module(steps_release_nft).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([step/6, step_dry/6]).
-export([test_oracle_query/2, test_oracle_query/3]).

-define(CONTRACT_FILE, "contracts/build_release_nft.aes").
-define(DEFAULT_ORACLE_TTL, 500000).
-define(DEFAULT_QUERY_TTL, 100).
-define(DEFAULT_RESPONSE_TTL, 50000).

-define(STEP_USE_CONTRACT, [
    "I am using build release NFT contract", ContractId
]).
-define(STEP_DEPLOY_CONTRACT, [
    "I deploy the build release NFT contract with oracle TTL", OracleTtl
]).
-define(STEP_MINT_LEGACY, [
    "I mint an NFT with metadata IPFS hash in",
    MetaVar,
    "and asset hash in",
    AssetVar
]).
-define(STEP_MINT_PLATFORM, [
    "I mint a build release NFT for platform",
    Platform,
    "with metadata IPFS hash in",
    MetaVar,
    "and asset hash in",
    AssetVar
]).
-define(STEP_MINT_EXPLICIT, [
    "I mint build release",
    ReleaseName,
    "for platform",
    Platform,
    "with git SHA",
    GitSha,
    "metadata IPFS hash in",
    MetaVar,
    "and asset hash in",
    AssetVar
]).
-define(STEP_PUBLISH_INSTALL, [
    "I publish the minted build release for installation using package file",
    PackageFile,
    "and IPFS path",
    AssetPath
]).
-define(STEP_STORE_MINT, [
    "I store the mint result in", Variable
]).

%% ------------------------------------------------------------------
%% Dry-run clauses: advertise only the steps implemented by this module.
%% ------------------------------------------------------------------
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_USE_CONTRACT, _Body) ->
    _ = ContractId,
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_DEPLOY_CONTRACT, _Body) ->
    _ = OracleTtl,
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_MINT_LEGACY, _Body) ->
    _ = {MetaVar, AssetVar},
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_MINT_PLATFORM, _Body) ->
    _ = {Platform, MetaVar, AssetVar},
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_MINT_EXPLICIT, _Body) ->
    _ = {ReleaseName, Platform, GitSha, MetaVar, AssetVar},
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_PUBLISH_INSTALL, _Body) ->
    _ = {PackageFile, AssetPath},
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_STORE_MINT, _Body) ->
    _ = Variable,
    Context.

%% ------------------------------------------------------------------
%% Configuration/deployment.
%% ------------------------------------------------------------------
step(_Config, Context, _Keyword, _LineNo, ?STEP_USE_CONTRACT, _Body) ->
    Ct = to_bin(ContractId),
    case Ct of
        <<"ct_", _/binary>> ->
            maps:put(build_release_nft_contract, Ct, Context);
        _ ->
            fail(Context, {invalid_build_release_nft_contract, Ct})
    end;
step(_Config, Context, _Keyword, _LineNo, ?STEP_DEPLOY_CONTRACT, _Body) ->
    case {parse_pos_int(OracleTtl), context_account(Context)} of
        {{ok, Ttl}, {ok, Account}} ->
            %% Idempotent: account registry is checked first. Deployment only
            %% occurs when this account has no <<"build_release_nft">> entry.
            case damage_contract_bootstrap:ensure_build_release_nft(Account, Ttl) of
                {ok, ContractId} ->
                    maps:merge(
                        Context,
                        #{
                            build_release_nft_contract => ContractId,
                            build_release_nft_deploy => ensured
                        }
                    );
                {error, Why} ->
                    fail(Context, {build_release_nft_ensure_failed, Why})
            end;
        {{error, Why}, _} ->
            fail(Context, {invalid_oracle_ttl, OracleTtl, Why});
        {_, {error, Why}} ->
            fail(Context, Why)
    end;
%% ------------------------------------------------------------------
%% Existing build-feature compatibility.
%%
%% The content-addressed asset CID is a safe fallback release identifier.
%% Platform and git SHA can be supplied in context/config; otherwise platform
%% is "generic" and git SHA is empty.
%% ------------------------------------------------------------------
step(_Config, Context0, <<"When">>, _LineNo, ?STEP_MINT_LEGACY, _Body) ->
    case release_inputs(Context0, MetaVar, AssetVar) of
        {ok, MetaCid, AssetCid} ->
            Platform = infer_platform(Context0),
            ReleaseName = infer_release_name(Context0, AssetCid),
            GitSha = infer_git_sha(Context0),
            mint_release_and_pin(Context0, ReleaseName, Platform, GitSha, MetaCid, AssetCid);
        {error, Why} ->
            fail(Context0, Why)
    end;
%% Preferred concise step for build features. The asset CID remains the unique
%% release id unless release_name/git_sha were already placed in Context.
step(_Config, Context0, <<"When">>, _LineNo, ?STEP_MINT_PLATFORM, _Body) ->
    case release_inputs(Context0, MetaVar, AssetVar) of
        {ok, MetaCid, AssetCid} ->
            ReleaseName = infer_release_name(Context0, AssetCid),
            GitSha = infer_git_sha(Context0),
            mint_release_and_pin(
                Context0, ReleaseName, to_bin(Platform), GitSha, MetaCid, AssetCid
            );
        {error, Why} ->
            fail(Context0, Why)
    end;
%% Explicit release/version + platform + commit form for release pipelines that
%% already have those values in Gherkin/template context.
step(_Config, Context0, <<"When">>, _LineNo, ?STEP_MINT_EXPLICIT, _Body) ->
    case release_inputs(Context0, MetaVar, AssetVar) of
        {ok, MetaCid, AssetCid} ->
            mint_release_and_pin(
                Context0,
                to_bin(ReleaseName),
                to_bin(Platform),
                to_bin(GitSha),
                MetaCid,
                AssetCid
            );
        {error, Why} ->
            fail(Context0, Why)
    end;
%% Separate promotion from minting: only a verified release with a known
%% package byte checksum becomes installable. No build is promoted on a GET.
step(Config, Context, <<"When">>, _LineNo, ?STEP_PUBLISH_INSTALL, _Body) ->
    case
        {
            maps:get(build_release_mint_result, Context, undefined),
            proplists:get_value(run_dir, Config)
        }
    of
        {Mint, RunDir} when is_map(Mint), RunDir =/= undefined ->
            case damage_release_nft:package_sha256(RunDir, PackageFile) of
                {ok, Digest} ->
                    case release_keypair(Context) of
                        {ok, KeyPair} ->
                            case damage_release_nft:publish(KeyPair, Mint, AssetPath, Digest) of
                                {ok, Published} ->
                                    Context#{
                                        build_release_install_result => Published,
                                        build_release_mint_result => maps:merge(Mint, Published)
                                    };
                                {error, Why} ->
                                    fail(Context, {release_publication_failed, Why})
                            end;
                        {error, Why} ->
                            fail(Context, Why)
                    end;
                {error, Why} ->
                    fail(Context, {package_hash_failed, Why})
            end;
        _ ->
            fail(Context, release_publication_requires_mint_and_run_dir)
    end;
%% Preserve the exact existing build-feature idiom:
%%   When I mint ...
%%   And I store the mint result in "mint"
step(_Config, Context, _Keyword, _LineNo, ?STEP_STORE_MINT, _Body) ->
    case maps:get(build_release_mint_result, Context, undefined) of
        undefined ->
            fail(Context, build_release_mint_not_available);
        MintResult ->
            maps:put(Variable, MintResult, Context)
    end.

%% ------------------------------------------------------------------
%% Release + oracle transaction flow.
%% ------------------------------------------------------------------
mint_release_and_pin(Context0, ReleaseName0, Platform0, GitSha0, MetaCid0, AssetCid0) ->
    ReleaseName = to_bin(ReleaseName0),
    Platform = to_bin(Platform0),
    GitSha = to_bin(GitSha0),
    MetaCid = strip_ipfs_prefix(to_bin(MetaCid0)),
    AssetCid = strip_ipfs_prefix(to_bin(AssetCid0)),

    case validate_release_fields(ReleaseName, Platform, MetaCid, AssetCid) of
        ok ->
            case resolve_contract(Context0) of
                {ok, ContractId} ->
                    case release_keypair(Context0) of
                        {ok, KeyPair} ->
                            #{public_key := MintTo0} = KeyPair,
                            MintTo = to_bin(MintTo0),
                            %% Restart-safe: a previous attempt may have minted the
                            %% immutable release before a later oracle response failed.
                            case
                                ensure_release_token(
                                    KeyPair,
                                    ContractId,
                                    MintTo,
                                    ReleaseName,
                                    Platform,
                                    GitSha,
                                    MetaCid,
                                    AssetCid
                                )
                            of
                                {ok, TokenId, MintCall} ->
                                    pin_global_latest(
                                        Context0,
                                        KeyPair,
                                        ContractId,
                                        TokenId,
                                        ReleaseName,
                                        Platform,
                                        GitSha,
                                        MetaCid,
                                        AssetCid,
                                        MintCall
                                    );
                                {error, Why} ->
                                    fail(Context0, Why)
                            end;
                        {error, Why} ->
                            fail(Context0, Why)
                    end;
                {error, Why} ->
                    fail(Context0, Why)
            end;
        {error, Why} ->
            fail(Context0, Why)
    end.

ensure_release_token(
    KeyPair,
    ContractId,
    MintTo,
    ReleaseName,
    Platform,
    GitSha,
    MetaCid,
    AssetCid
) ->
    LookupArgs = [to_list(ReleaseName), to_list(Platform)],
    case
        damage_ae:contract_query(
            KeyPair,
            ContractId,
            contract_source(),
            "release_token",
            LookupArgs
        )
    of
        LookupCall when is_map(LookupCall) ->
            case call_return(LookupCall) of
                {ok, EncodedOption} ->
                    case option_value(EncodedOption) of
                        {ok, TokenId} when is_integer(TokenId) ->
                            ?LOG_NOTICE(
                                "Build release already minted contract=~p token_id=~p release=~p platform=~p; reusing",
                                [ContractId, TokenId, ReleaseName, Platform]
                            ),
                            {ok, TokenId, #{reused => true}};
                        none ->
                            mint_new_release(
                                KeyPair,
                                ContractId,
                                MintTo,
                                ReleaseName,
                                Platform,
                                GitSha,
                                MetaCid,
                                AssetCid
                            );
                        {ok, Unexpected} ->
                            {error, {unexpected_existing_release_token, Unexpected, LookupCall}};
                        {error, Why} ->
                            {error, {existing_release_token_decode_failed, Why, LookupCall}}
                    end;
                {error, Why} ->
                    {error, {existing_release_lookup_failed, Why, LookupCall}}
            end;
        Error ->
            {error, {existing_release_lookup_failed, Error}}
    end.

mint_new_release(
    KeyPair,
    ContractId,
    MintTo,
    ReleaseName,
    Platform,
    GitSha,
    MetaCid,
    AssetCid
) ->
    MintArgs = [
        to_list(MintTo),
        to_list(ReleaseName),
        to_list(Platform),
        to_list(GitSha),
        to_list(MetaCid),
        to_list(AssetCid)
    ],
    %% The account owns/signs the NFT mutation while the DamageBDD node pays
    %% the outer PayingFor fee.
    case
        damage_ae:contract_call_payfor_user(
            KeyPair,
            ContractId,
            contract_source(),
            "mint_release",
            MintArgs
        )
    of
        MintCall when is_map(MintCall) ->
            case call_return(MintCall) of
                {ok, TokenId} when is_integer(TokenId) ->
                    {ok, TokenId, maps:put(reused, false, MintCall)};
                {ok, Unexpected} ->
                    {error, {unexpected_mint_return_value, Unexpected, MintCall}};
                {error, Why} ->
                    {error, {build_release_mint_failed, Why, MintCall}}
            end;
        Error ->
            {error, {build_release_mint_failed, Error}}
    end.

pin_global_latest(
    Context0,
    KeyPair,
    ContractId,
    TokenId,
    ReleaseName,
    Platform,
    GitSha,
    MetaCid,
    AssetCid,
    MintCall
) ->
    QueryTtl = env_pos_int(build_release_oracle_query_ttl, ?DEFAULT_QUERY_TTL),
    ResponseTtl = env_pos_int(build_release_oracle_response_ttl, ?DEFAULT_RESPONSE_TTL),
    %% Empty platform asks the contract to create the canonical "latest" query.
    QueryArgs = ["", integer_to_list(QueryTtl), integer_to_list(ResponseTtl)],
    case
        damage_ae:contract_call_payfor_user(
            KeyPair, ContractId, contract_source(), "create_latest_query", QueryArgs
        )
    of
        QueryCall when is_map(QueryCall) ->
            case call_return(QueryCall) of
                {ok, RawQueryId} ->
                    case normalize_query_id(RawQueryId) of
                        {ok, QueryId} ->
                            %% Verify the round-tripped oq_ id before Oracle.respond.
                            %% A fresh valid query must resolve and have no answer.
                            case oracle_query_preflight(KeyPair, ContractId, QueryId) of
                                ok ->
                                    respond_latest_and_verify(
                                        Context0,
                                        KeyPair,
                                        ContractId,
                                        QueryId,
                                        TokenId,
                                        ReleaseName,
                                        Platform,
                                        GitSha,
                                        MetaCid,
                                        AssetCid,
                                        MintCall,
                                        QueryCall
                                    );
                                {error, Why} ->
                                    fail(
                                        Context0,
                                        {oracle_query_preflight_failed, QueryId, Why}
                                    )
                            end;
                        {error, Why} ->
                            fail(Context0, {oracle_query_id_decode_failed, Why, RawQueryId})
                    end;
                {error, Why} ->
                    fail(Context0, {latest_oracle_query_failed, Why, QueryCall})
            end;
        Error ->
            fail(Context0, {latest_oracle_query_failed, Error})
    end.

oracle_query_preflight(KeyPair, ContractId, QueryId) ->
    case oracle_query_arg(QueryId) of
        {ok, QueryArg} ->
            case
                damage_ae:contract_query(
                    KeyPair,
                    ContractId,
                    contract_source(),
                    "get_oracle_answer",
                    [QueryArg]
                )
            of
                QueryCheck when is_map(QueryCheck) ->
                    case call_return(QueryCheck) of
                        {ok, EncodedOption} ->
                            case option_value(EncodedOption) of
                                none ->
                                    ok;
                                {ok, ExistingAnswer} ->
                                    {error, {query_already_answered, ExistingAnswer}};
                                {error, Why} ->
                                    {error, {query_answer_decode_failed, Why, QueryCheck}}
                            end;
                        {error, Why} ->
                            {error, {query_not_resolvable, Why, QueryCheck}}
                    end;
                Error ->
                    {error, {query_not_resolvable, Error}}
            end;
        {error, Why} ->
            {error, {invalid_oracle_query_id, QueryId, Why}}
    end.

respond_latest_and_verify(
    Context0,
    KeyPair,
    ContractId,
    QueryId,
    TokenId,
    ReleaseName,
    Platform,
    GitSha,
    MetaCid,
    AssetCid,
    MintCall,
    QueryCall
) ->
    case oracle_query_arg(QueryId) of
        {ok, QueryArg} ->
            case
                damage_ae:contract_call_payfor_user(
                    KeyPair,
                    ContractId,
                    contract_source(),
                    "respond_latest",
                    [QueryArg]
                )
            of
                ResponseCall when is_map(ResponseCall) ->
                    case call_return(ResponseCall) of
                        {ok, _Unit} ->
                            case
                                damage_ae:contract_query(
                                    KeyPair,
                                    ContractId,
                                    contract_source(),
                                    "get_oracle_answer",
                                    [QueryArg]
                                )
                            of
                                AnswerCall when is_map(AnswerCall) ->
                                    case call_return(AnswerCall) of
                                        {ok, EncodedOption} ->
                                            case option_value(EncodedOption) of
                                                {ok, Answer0} ->
                                                    Answer = to_bin(Answer0),
                                                    Expected = release_answer(
                                                        TokenId,
                                                        ReleaseName,
                                                        Platform,
                                                        GitSha,
                                                        MetaCid,
                                                        AssetCid
                                                    ),
                                                    case Answer =:= Expected of
                                                        true ->
                                                            Result = #{
                                                                contract_id => ContractId,
                                                                token_id => TokenId,
                                                                release => ReleaseName,
                                                                platform => Platform,
                                                                git_sha => GitSha,
                                                                metadata_cid => MetaCid,
                                                                asset_cid => AssetCid,
                                                                mint_status => mint_status(
                                                                    MintCall
                                                                ),
                                                                mint_tx_hash => tx_hash(MintCall),
                                                                oracle_question => <<"latest">>,
                                                                oracle_query_id => QueryId,
                                                                oracle_query_tx_hash => tx_hash(
                                                                    QueryCall
                                                                ),
                                                                oracle_response_tx_hash => tx_hash(
                                                                    ResponseCall
                                                                ),
                                                                oracle_answer => Answer
                                                            },
                                                            maps:put(
                                                                build_release_mint_result,
                                                                Result,
                                                                Context0
                                                            );
                                                        false ->
                                                            fail(
                                                                Context0,
                                                                {oracle_answer_mismatch, Expected,
                                                                    Answer}
                                                            )
                                                    end;
                                                none ->
                                                    fail(
                                                        Context0, {oracle_answer_missing, QueryId}
                                                    );
                                                {error, Why} ->
                                                    fail(
                                                        Context0, {oracle_answer_decode_failed, Why}
                                                    )
                                            end;
                                        {error, Why} ->
                                            fail(
                                                Context0,
                                                {oracle_answer_query_failed, Why, AnswerCall}
                                            )
                                    end;
                                Error ->
                                    fail(Context0, {oracle_answer_query_failed, Error})
                            end;
                        {error, Why} ->
                            fail(Context0, {latest_oracle_response_failed, Why, ResponseCall})
                    end;
                Error ->
                    fail(Context0, {latest_oracle_response_failed, Error})
            end;
        {error, Why} ->
            fail(Context0, {invalid_oracle_query_id, QueryId, Why})
    end.

%% ------------------------------------------------------------------
%% Manual live-chain oracle-query argument test.
%%
%% Quick use from `rebar3 shell`:
%%
%%   steps_release_nft:test_oracle_query(
%%       <<"ct_...">>,
%%       <<"oq_...">>
%%   ).
%%
%% The test deliberately exercises the same `get_oracle_answer` entrypoint
%% using three argument representations. This is a manual integration test,
%% not an EUnit test: it requires a reachable aeternity node and deployed
%% BuildReleaseNFT contract.
%% ------------------------------------------------------------------
-spec test_oracle_query(binary() | list(), binary() | list()) -> map().
test_oracle_query(ContractId, QueryId) ->
    test_oracle_query(secrets:node_keypair(), ContractId, QueryId).

-spec test_oracle_query(map(), binary() | list(), binary() | list()) -> map().
test_oracle_query(KeyPair, ContractId0, QueryId0) when is_map(KeyPair) ->
    ContractId = to_bin(ContractId0),
    QueryId = to_bin(QueryId0),
    case decode_oracle_query_id(QueryId) of
        {ok, QueryBin} ->
            Tests = [
                {encoded_string, [to_list(QueryId)]},
                {oracle_query, [{oracle_query, QueryBin}]},
                {oracle_query_id, [{oracle_query_id, QueryBin}]}
            ],
            Results = maps:from_list([
                {Name, test_oracle_query_call(KeyPair, ContractId, Args)}
             || {Name, Args} <- Tests
            ]),
            Result = #{
                contract_id => ContractId,
                query_id => QueryId,
                decoded_query_bytes => QueryBin,
                results => Results
            },
            ?LOG_NOTICE("Build release oracle query argument test: ~p", [Result]),
            Result;
        {error, Why} ->
            Result = #{
                contract_id => ContractId,
                query_id => QueryId,
                error => Why
            },
            ?LOG_ERROR("Build release oracle query argument test failed to decode query id: ~p", [
                Result
            ]),
            Result
    end.

test_oracle_query_call(KeyPair, ContractId, Args) ->
    try
        damage_ae:contract_query(
            KeyPair,
            ContractId,
            contract_source(),
            "get_oracle_answer",
            Args
        )
    of
        Result when is_map(Result) ->
            #{
                args => Args,
                call_return => call_return(Result),
                result => Result
            };
        Other ->
            #{args => Args, result => Other}
    catch
        Class:Reason:Stacktrace ->
            #{
                args => Args,
                exception => #{
                    class => Class,
                    reason => Reason,
                    stacktrace => Stacktrace
                }
            }
    end.

decode_oracle_query_id(<<"oq_", _/binary>> = QueryId) ->
    try aeser_api_encoder:decode(QueryId) of
        {oracle_query_id, QueryBin} when is_binary(QueryBin), byte_size(QueryBin) =:= 32 ->
            {ok, QueryBin};
        {oracle_query, QueryBin} when is_binary(QueryBin), byte_size(QueryBin) =:= 32 ->
            {ok, QueryBin};
        Other ->
            {error, {unexpected_oracle_query_decode, Other}}
    catch
        Class:Reason ->
            {error, {oracle_query_decode_failed, Class, Reason}}
    end;
decode_oracle_query_id(QueryId) ->
    {error, {invalid_oracle_query_id, QueryId}}.

%% Contract ABI expects the FATE oracle_query value, not the printable oq_ id.
%% vanillae does not currently resolve the user-defined query_id alias, so pass
%% the already-decoded FATE term explicitly. The live integration test in
%% test_oracle_query/2 proves this is the representation accepted by
%% aeb_fate_encoding and the deployed BuildReleaseNFT contract.
oracle_query_arg(QueryId) ->
    case decode_oracle_query_id(to_bin(QueryId)) of
        {ok, QueryBin} ->
            {ok, {oracle_query, QueryBin}};
        {error, _} = Error ->
            Error
    end.

%% ------------------------------------------------------------------
%% Contract result decoding helpers.
%% ------------------------------------------------------------------
call_return(Map) when is_map(Map) ->
    ReturnType = map_get_any(["return_type", <<"return_type">>, return_type], Map, undefined),
    ReturnValue = map_get_any(["return_value", <<"return_value">>, return_value], Map, undefined),
    case ReturnType of
        "ok" -> {ok, ReturnValue};
        <<"ok">> -> {ok, ReturnValue};
        ok -> {ok, ReturnValue};
        "revert" -> {error, {revert, ReturnValue}};
        <<"revert">> -> {error, {revert, ReturnValue}};
        revert -> {error, {revert, ReturnValue}};
        undefined -> {error, {missing_return_type, Map}};
        Other -> {error, {unexpected_return_type, Other, ReturnValue}}
    end.

normalize_query_id(<<"oq_", _/binary>> = Q) ->
    {ok, Q};
normalize_query_id(Q) when is_list(Q) ->
    normalize_query_id(to_bin(Q));
normalize_query_id({oracle_query, Bin}) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    encode_oracle_query_id(Bin);
normalize_query_id({oracle_query_id, Bin}) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    encode_oracle_query_id(Bin);
normalize_query_id({oracle_query, Q}) ->
    normalize_query_id(Q);
normalize_query_id({oracle_query_id, Q}) ->
    normalize_query_id(Q);
normalize_query_id({tuple, {Q}}) ->
    normalize_query_id(Q);
normalize_query_id({tuple, Q}) ->
    normalize_query_id(Q);
normalize_query_id({Q}) ->
    normalize_query_id(Q);
normalize_query_id(Bin) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    encode_oracle_query_id(Bin);
normalize_query_id(Other) ->
    {error, {unsupported_oracle_query_id, Other}}.

encode_oracle_query_id(Bin) ->
    try aeser_api_encoder:encode(oracle_query_id, Bin) of
        Encoded -> {ok, to_bin(Encoded)}
    catch
        Class:Reason -> {error, {oracle_query_id_encode_failed, Class, Reason}}
    end.

option_value({variant, [0, 1], 0, {}}) -> none;
option_value({variant, [0, 1], 1, {Value}}) -> {ok, Value};
option_value({variant, _Arities, 0, {}}) -> none;
option_value({variant, _Arities, 1, {Value}}) -> {ok, Value};
option_value({some, Value}) -> {ok, Value};
option_value({Some, Value}) when Some =:= 'Some' -> {ok, Value};
option_value(none) -> none;
option_value('None') -> none;
option_value(Value) when is_binary(Value); is_list(Value) -> {ok, Value};
option_value(Other) -> {error, {unsupported_option_value, Other}}.

release_answer(TokenId, ReleaseName, Platform, GitSha, MetaCid, AssetCid) ->
    iolist_to_binary([
        integer_to_binary(TokenId),
        <<"|">>,
        ReleaseName,
        <<"|">>,
        Platform,
        <<"|">>,
        GitSha,
        <<"|ipfs://">>,
        MetaCid,
        <<"|ipfs://">>,
        AssetCid
    ]).

%% ------------------------------------------------------------------
%% Input/config helpers.
%% ------------------------------------------------------------------
contract_source() ->
    damage_ae:contract_path(damage, ?CONTRACT_FILE).

resolve_contract(Context) ->
    case
        map_get_any(
            [
                build_release_nft_contract,
                <<"build_release_nft_contract">>,
                "build_release_nft_contract"
            ],
            Context,
            undefined
        )
    of
        undefined ->
            case context_account(Context) of
                {ok, Account} ->
                    %% Registry-first lazy resolution. This reuses the account's
                    %% existing contract and deploys/registers only when absent.
                    damage_contract_bootstrap:ensure_build_release_nft(Account);
                {error, _} = Error ->
                    Error
            end;
        Ct0 ->
            %% Explicit BDD override remains available for migration/recovery.
            validate_contract_id(Ct0)
    end.

context_account(Context) ->
    case
        map_get_any(
            [public_key, <<"public_key">>, "public_key", address, <<"address">>, "address"],
            Context,
            undefined
        )
    of
        <<"ak_", _/binary>> = Account ->
            {ok, Account};
        Account0 when is_list(Account0) ->
            case to_bin(Account0) of
                <<"ak_", _/binary>> = Account -> {ok, Account};
                Other -> {error, {invalid_build_release_account, Other}}
            end;
        undefined ->
            {error, build_release_account_missing};
        Other ->
            {error, {invalid_build_release_account, Other}}
    end.

release_keypair(Context) ->
    case context_account(Context) of
        {ok, Account} ->
            try identity_server:reload_account(Account) of
                #{public_key := Pub0, private_key := PrivateKey} = KeyPair when
                    is_binary(PrivateKey), PrivateKey =/= <<>>
                ->
                    Pub = to_bin(Pub0),
                    case Pub =:= Account of
                        true -> {ok, KeyPair#{public_key := Pub}};
                        false -> {error, {build_release_account_mismatch, Account, Pub}}
                    end;
                notfound ->
                    {error, {build_release_identity_not_found, Account}};
                {error, Why} ->
                    {error, {build_release_identity_reload_failed, Account, Why}};
                Other ->
                    {error, {invalid_build_release_identity, Account, Other}}
            catch
                Class:Reason:Stacktrace ->
                    ?LOG_ERROR(
                        "Build release account reload failed account=~p class=~p reason=~p stack=~p",
                        [Account, Class, Reason, Stacktrace]
                    ),
                    {error, {build_release_identity_reload_crashed, Account, Class, Reason}}
            end;
        {error, _} = Error ->
            Error
    end.

validate_contract_id(Ct0) ->
    Ct = to_bin(Ct0),
    case Ct of
        <<"ct_", _/binary>> -> {ok, Ct};
        _ -> {error, {invalid_build_release_nft_contract, Ct}}
    end.

release_inputs(Context, MetaVar, AssetVar) ->
    case {context_var(Context, MetaVar), context_var(Context, AssetVar)} of
        {{ok, MetaCid}, {ok, AssetCid}} ->
            {ok, to_bin(MetaCid), to_bin(AssetCid)};
        {{error, Why}, _} ->
            {error, {metadata_ipfs_hash_lookup_failed, MetaVar, Why}};
        {_, {error, Why}} ->
            {error, {asset_ipfs_hash_lookup_failed, AssetVar, Why}}
    end.

context_var(Context, Key0) ->
    KeyBin = to_bin(Key0),
    KeyList = to_list(KeyBin),
    case map_find_any([Key0, KeyList, KeyBin], Context) of
        {ok, Value} ->
            {ok, Value};
        error ->
            case existing_atom(KeyBin) of
                {ok, Atom} ->
                    case maps:find(Atom, Context) of
                        {ok, Value} -> {ok, Value};
                        error -> {error, not_found}
                    end;
                error ->
                    {error, not_found}
            end
    end.

infer_platform(Context) ->
    case
        map_get_any(
            [build_release_platform, <<"build_release_platform">>, "build_release_platform"],
            Context,
            undefined
        )
    of
        undefined ->
            case infer_platform_from_meta(Context) of
                undefined ->
                    case application:get_env(damage, build_release_platform) of
                        {ok, P} -> to_bin(P);
                        undefined -> <<"generic">>
                    end;
                P ->
                    to_bin(P)
            end;
        P ->
            to_bin(P)
    end.

infer_platform_from_meta(Context) ->
    case map_get_any([meta, <<"meta">>, "meta"], Context, undefined) of
        M when is_map(M) ->
            map_get_any(
                [distribution, <<"distribution">>, "distribution", platform, <<"platform">>],
                M,
                undefined
            );
        _ ->
            undefined
    end.

infer_release_name(Context, AssetCid) ->
    case
        map_get_any(
            [
                build_release,
                <<"build_release">>,
                "build_release",
                release_name,
                <<"release_name">>,
                "release_name",
                git_describe,
                <<"git_describe">>,
                "git_describe"
            ],
            Context,
            undefined
        )
    of
        undefined -> to_bin(AssetCid);
        R -> to_bin(R)
    end.

infer_git_sha(Context) ->
    case
        map_get_any(
            [git_sha, <<"git_sha">>, "git_sha", git_commit, <<"git_commit">>, "git_commit"],
            Context,
            undefined
        )
    of
        undefined -> <<>>;
        Sha -> to_bin(Sha)
    end.

validate_release_fields(<<>>, _Platform, _MetaCid, _AssetCid) ->
    {error, release_name_required};
validate_release_fields(_ReleaseName, <<>>, _MetaCid, _AssetCid) ->
    {error, release_platform_required};
validate_release_fields(_ReleaseName, _Platform, <<>>, _AssetCid) ->
    {error, metadata_cid_required};
validate_release_fields(_ReleaseName, _Platform, _MetaCid, <<>>) ->
    {error, asset_cid_required};
validate_release_fields(_ReleaseName, _Platform, _MetaCid, _AssetCid) ->
    ok.

strip_ipfs_prefix(<<"ipfs://", Rest/binary>>) -> Rest;
strip_ipfs_prefix(Bin) -> Bin.

parse_pos_int(V) when is_integer(V), V > 0 -> {ok, V};
parse_pos_int(V) when is_binary(V) ->
    try
        parse_pos_int(binary_to_integer(V))
    catch
        _:_ -> {error, not_integer}
    end;
parse_pos_int(V) when is_list(V) ->
    try
        parse_pos_int(list_to_integer(V))
    catch
        _:_ -> {error, not_integer}
    end;
parse_pos_int(_) ->
    {error, not_positive_integer}.

env_pos_int(Key, Default) ->
    case application:get_env(damage, Key) of
        {ok, Value} ->
            case parse_pos_int(Value) of
                {ok, I} -> I;
                _ -> Default
            end;
        undefined ->
            Default
    end.

existing_atom(Bin) ->
    try
        {ok, binary_to_existing_atom(Bin, utf8)}
    catch
        _:_ -> error
    end.

map_find_any([K | Ks], Map) ->
    case maps:find(K, Map) of
        {ok, _} = Found -> Found;
        error -> map_find_any(Ks, Map)
    end;
map_find_any([], _Map) ->
    error.

map_get_any(Keys, Map, Default) when is_map(Map) ->
    case map_find_any(Keys, Map) of
        {ok, Value} -> Value;
        error -> Default
    end.

tx_hash(Map) when is_map(Map) ->
    map_get_any(["tx_hash", <<"tx_hash">>, tx_hash], Map, undefined);
tx_hash(_) ->
    undefined.

mint_status(Map) when is_map(Map) ->
    case maps:get(reused, Map, false) of
        true -> reused;
        false -> minted
    end;
mint_status(_) ->
    minted.

fail(Context, Reason) ->
    ?LOG_ERROR("build release NFT step failed: ~p", [Reason]),
    maps:put(fail, damage_utils:strf("Build release NFT failed: ~p", [Reason]), Context).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

to_list(B) when is_binary(B) -> unicode:characters_to_list(B);
to_list(L) when is_list(L) -> L;
to_list(A) when is_atom(A) -> atom_to_list(A);
to_list(I) when is_integer(I) -> integer_to_list(I);
to_list(Other) -> lists:flatten(io_lib:format("~p", [Other])).
