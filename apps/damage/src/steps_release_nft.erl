%%%-------------------------------------------------------------------
%%% DamageBDD build-release NFT + native aeternity oracle steps.
%%%
%%% Flow used by the existing build features:
%%%   1. artifact -> IPFS CID
%%%   2. prepare/check installation metadata, then metadata JSON -> IPFS CID
%%%   3. mint one AEX-141 release NFT (the production publication point)
%%%   4. optionally announce a platform snapshot through the native oracle
%%%      (disabled by default; announcement failure never undoes a mint)
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

-import(damage_release_nft, [contract_source/0, call_return/1,
    option_value/1, release_answer/6]).
-ifdef(TEST).
-export([existing_release_matches/2, oracle_announcement_result/2, checked_mint_inputs/6]).
-endif.
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
%% Recognize the retired syntax only to reject it in dry-run BEFORE a mint.
%% Never guess a host path, hash different bytes, or silently mark it published.
-define(STEP_PUBLISH_INSTALL, [
    "I publish the minted build release for installation using package file",
    PackageFile,
    "and IPFS path",
    AssetPath
]).
-define(STEP_PREPARE_INSTALL, [
    "I prepare installation metadata in", MetaVar,
    "for platform", Platform,
    "from IPFS asset hash in", AssetVar,
    "with manifest path", ManifestPath
]).
-define(STEP_STORE_MINT, [
    "I store the mint result in", Variable
]).
-define(STEP_POST_NOSTR, [
    "I post the minted build release NFT to nostr"
]).
-define(STEP_POST_NOSTR_SALE, [
    "I post the minted build release NFT to nostr for",
    PriceDamage,
    "DAMAGE with Lightning purchase"
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
    obsolete_install_publication(Context);
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_PREPARE_INSTALL, _Body) ->
    _ = {MetaVar, Platform, AssetVar, ManifestPath},
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_STORE_MINT, _Body) ->
    _ = Variable,
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_POST_NOSTR, _Body) ->
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_POST_NOSTR_SALE, _Body) ->
    _ = PriceDamage,
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
step(_Config, Context, <<"When">>, _LineNo, ?STEP_MINT_LEGACY, _Body) ->
    mint_from_context(Context, MetaVar, AssetVar, #{});
step(_Config, Context, <<"When">>, _LineNo, ?STEP_MINT_PLATFORM, _Body) ->
    mint_from_context(Context, MetaVar, AssetVar, #{platform => to_bin(Platform)});
step(_Config, Context, <<"When">>, _LineNo, ?STEP_MINT_EXPLICIT, _Body) ->
    mint_from_context(Context, MetaVar, AssetVar,
        #{release => to_bin(ReleaseName), platform => to_bin(Platform), git_sha => to_bin(GitSha)});
%% Also reject the old operation if invoked without a preceding dry-run.
step(_Config, Context, _Keyword, _LineNo, ?STEP_PUBLISH_INSTALL, _Body) ->
    _ = {PackageFile, AssetPath},
    obsolete_install_publication(Context);
%% The package checksum/path must enter NFT-linked metadata BEFORE minting.
%% The manifest and package are both read from the same verified IPFS artifact.
step(_Config, Context, <<"When">>, _LineNo, ?STEP_PREPARE_INSTALL, _Body) ->
    case {context_var(Context, MetaVar), context_var(Context, AssetVar)} of
        {{ok, Meta}, {ok, Asset}} when is_map(Meta) ->
            case damage_release_nft:prepare_metadata(Meta, Platform, Asset, ManifestPath) of
                {ok, Prepared} ->
                    case damage_release_nft:prepared_installation(Prepared) of
                        {ok, Expected} ->
                            Updated = put_context_var(Context, MetaVar, Prepared),
                            Updated#{build_release_installation_expected => Expected,
                                build_release_platform => maps:get(platform, Expected),
                                git_sha => maps:get(git_sha, Expected)};
                        {error, Why} -> fail(Context, {installation_metadata_failed, Why})
                    end;
                {error, Why} -> fail(Context, {installation_metadata_failed, Why})
            end;
        _ -> fail(Context, installation_metadata_requires_metadata_and_asset)
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
    end;
step(Config, Context, _Keyword, _LineNo, ?STEP_POST_NOSTR, Body) ->
    post_minted_release_nft(Config, Context, Body, none);
step(Config, Context, _Keyword, _LineNo, ?STEP_POST_NOSTR_SALE, Body) ->
    case parse_pos_number(PriceDamage) of
        {ok, DamageAmount} ->
            post_minted_release_nft(
                Config,
                Context,
                Body,
                #{damage_amount => DamageAmount, damage_text => to_bin(PriceDamage)}
            );
        {error, Why} ->
            fail(Context, {invalid_build_release_nft_price, PriceDamage, Why})
    end.

%% ------------------------------------------------------------------
%% Nostr release card + optional Lightning sale offer.
%%
%% The mint is already final before this step runs. Publication is deliberately
%% post-mint so an IPFS/Nostr/Lightning outage can never make the build release
%% appear unminted or cause a retry to mint a second token.
%% ------------------------------------------------------------------
post_minted_release_nft(Config, Context0, Body, Sale0) ->
    case maps:get(build_release_mint_result, Context0, undefined) of
        Mint when is_map(Mint) ->
            Opts = normalize_post_options(Body),
            case build_sale_quote(Sale0, Opts) of
                {ok, Quote} ->
                    case generate_release_card(Config, Mint, Quote, Opts) of
                        {ok, Image} ->
                            case maybe_create_sale_invoice(Mint, Quote, Opts) of
                                {ok, Purchase} ->
                                    Listing = #{
                                        mint => Mint,
                                        image => Image,
                                        quote => Quote,
                                        purchase => Purchase
                                    },
                                    Context1 = Context0#{build_release_nft_listing => Listing},
                                    publish_release_listing(Context1, Mint, Image, Quote, Purchase, Opts);
                                {error, Why} ->
                                    fail(Context0, {lightning_purchase_offer_failed, Why})
                            end;
                        {error, Why} ->
                            fail(Context0, {release_nft_image_failed, Why})
                    end;
                {error, Why} ->
                    fail(Context0, {release_nft_spot_quote_failed, Why})
            end;
        _ ->
            fail(Context0, build_release_mint_not_available)
    end.

build_sale_quote(none, _Opts) ->
    {ok, none};
build_sale_quote(#{damage_amount := DamageAmount, damage_text := DamageText}, Opts) ->
    MaxAgeMs = option_pos_int(
        Opts,
        [<<"price_max_age_ms">>, price_max_age_ms, "price_max_age_ms"],
        env_pos_int(build_release_nft_price_max_age_ms, 20 * 60 * 1000)
    ),
    try price_feed:damage_to_sats_quote(DamageAmount, MaxAgeMs) of
        {ok, Quote} when is_map(Quote) ->
            {ok, Quote#{damage_text => DamageText}};
        {error, _} = Error ->
            Error;
        Other ->
            {error, {unexpected_price_quote_response, Other}}
    catch
        exit:Reason -> {error, {price_feed_unavailable, Reason}};
        Class:Reason -> {error, {price_feed_failed, Class, Reason}}
    end.

maybe_create_sale_invoice(_Mint, none, _Opts) ->
    {ok, none};
maybe_create_sale_invoice(Mint, Quote, Opts) ->
    Expiry = option_pos_int(
        Opts,
        [<<"invoice_expiry_seconds">>, invoice_expiry_seconds, "invoice_expiry_seconds"],
        env_pos_int(build_release_nft_invoice_expiry_seconds, 15 * 60)
    ),
    Token = maps:get(token_id, Mint),
    TokenBin = to_bin(Token),
    Release = maps:get(release, Mint, <<>>),
    Platform = maps:get(platform, Mint, <<>>),
    Sats = maps:get(sats, Quote),
    Nonce = binary:encode_hex(crypto:strong_rand_bytes(6)),
    Label = <<"build_nft:", TokenBin/binary, ":", Nonce/binary>>,
    Description = iolist_to_binary([
        <<"DamageBDD build release NFT #">>, TokenBin,
        <<" ">>, short_text(Release, 48), <<" / ">>, short_text(Platform, 32)
    ]),
    try damage_cln:create_invoice(Sats * 1000, Description, Expiry, Label) of
        Invoice when is_map(Invoice) ->
            case map_get_any([bolt11, <<"bolt11">>, "bolt11"], Invoice, undefined) of
                undefined ->
                    {error, {invoice_missing_bolt11, compact_map(Invoice)}};
                Bolt110 ->
                    Bolt11 = to_bin(Bolt110),
                    {ok, #{
                        bolt11 => Bolt11,
                        lightning_uri => <<"lightning:", Bolt11/binary>>,
                        payment_hash => map_get_any(
                            [payment_hash, <<"payment_hash">>, "payment_hash"],
                            Invoice,
                            undefined
                        ),
                        expires_at => map_get_any(
                            [expires_at, <<"expires_at">>, "expires_at"],
                            Invoice,
                            undefined
                        ),
                        expiry_seconds => Expiry,
                        label => Label,
                        sats => Sats
                    }}
            end;
        Other ->
            {error, {unexpected_invoice_response, Other}}
    catch
        exit:Reason -> {error, {invoice_service_unavailable, Reason}};
        Class:Reason -> {error, {invoice_create_failed, Class, Reason}}
    end.

generate_release_card(Config, Mint, Quote, Opts) ->
    case lists:keyfind(run_dir, 1, Config) of
        {run_dir, RunDir0} ->
            RunDir = to_list(RunDir0),
            Token = maps:get(token_id, Mint),
            Name = lists:flatten(io_lib:format("build-release-nft-~B.svg", [Token])),
            Path = filename:join([RunDir, "nft", Name]),
            Svg = build_release_card_svg(Mint, Quote),
            case filelib:ensure_dir(Path) of
                ok ->
                    case file:write_file(Path, Svg, [binary]) of
                        ok ->
                            case safe_ipfs_add_file(Path) of
                                {ok, AddResult} ->
                                    case ipfs_file_cid(AddResult, Name) of
                                        {ok, Cid} ->
                                            Gateway = image_gateway(Opts),
                                            Url = append_gateway_cid(Gateway, Cid),
                                            {ok, #{
                                                cid => Cid,
                                                uri => <<"ipfs://", Cid/binary>>,
                                                url => Url,
                                                mime => <<"image/svg+xml">>,
                                                dimensions => <<"1200x630">>,
                                                sha256 => lower_hex(crypto:hash(sha256, Svg)),
                                                file => to_bin(Path)
                                            }};
                                        {error, _} = Error ->
                                            Error
                                    end;
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, Why} ->
                            {error, {write_release_card_failed, Path, Why}}
                    end;
                {error, Why} ->
                    {error, {release_card_directory_failed, Path, Why}}
            end;
        false ->
            {error, missing_run_dir}
    end.

safe_ipfs_add_file(Path) ->
    try damage_ipfs:add({file, to_bin(Path)}) of
        {ok, AddResult} -> {ok, AddResult};
        {error, _} = Error -> Error;
        Other -> {error, {unexpected_ipfs_add_response, Other}}
    catch
        exit:Reason -> {error, {ipfs_unavailable, Reason}};
        Class:Reason -> {error, {ipfs_add_failed, Class, Reason}}
    end.

ipfs_file_cid(HashList, Name0) when is_list(HashList) ->
    case HashList of
        [First | _] when is_map(First) ->
            Name = to_bin(Name0),
            Named = [
                to_bin(Hash)
             || Item <- HashList,
                Hash <- [map_get_any([<<"Hash">>, "Hash", hash, <<"hash">>], Item, undefined)],
                ItemName <- [map_get_any([<<"Name">>, "Name", name, <<"name">>], Item, undefined)],
                Hash =/= undefined,
                ItemName =/= undefined,
                to_bin(filename:basename(to_list(ItemName))) =:= Name
            ],
            case Named of
                [Cid | _] -> {ok, Cid};
                [] ->
                    Cids = [
                        to_bin(Hash)
                     || Item <- HashList,
                        Hash <- [map_get_any([<<"Hash">>, "Hash", hash, <<"hash">>], Item, undefined)],
                        Hash =/= undefined
                    ],
                    case lists:reverse(Cids) of
                        [Cid | _] -> {ok, Cid};
                        [] -> {error, {ipfs_hash_not_found, HashList}}
                    end
            end;
        _ ->
            %% Some legacy IPFS clients return a CID string directly.
            case is_charlist(HashList) of
                true -> {ok, to_bin(HashList)};
                false -> {error, {invalid_ipfs_add_result, HashList}}
            end
    end;
ipfs_file_cid(Cid, _Name) when is_binary(Cid) ->
    {ok, Cid};
ipfs_file_cid(Other, _Name) ->
    {error, {invalid_ipfs_add_result, Other}}.

publish_release_listing(Context0, Mint, Image, Quote, Purchase, Opts) ->
    {Content, Tags} = release_nostr_payload(Mint, Image, Quote, Purchase),
    Relays = listing_relays(Context0, Opts),
    TimeoutMs = option_pos_int(
        Opts,
        [<<"publish_timeout_ms">>, publish_timeout_ms, "publish_timeout_ms"],
        50000
    ),
    try damage_nostr:create_signed_event(1, Content, Tags) of
        {ok, Event} when is_map(Event) ->
            case nostr_pool:ensure_started(Relays) of
                ok ->
                    case nostr_pool:publish_sync(Event, Relays, TimeoutMs) of
                        ok ->
                            PostResult = #{
                                event_id => maps:get(<<"id">>, Event, undefined),
                                pubkey => maps:get(<<"pubkey">>, Event, undefined),
                                relays => Relays,
                                image_cid => maps:get(cid, Image),
                                image_url => maps:get(url, Image),
                                quote => Quote,
                                purchase => Purchase
                            },
                            Context0#{
                                build_release_nft_nostr_event => Event,
                                build_release_nft_post_result => PostResult
                            };
                        {error, Why} ->
                            fail(Context0, {nostr_publish_failed, Why})
                    end;
                {error, Why} ->
                    fail(Context0, {nostr_pool_start_failed, Why})
            end;
        Other ->
            fail(Context0, {nostr_event_sign_failed, Other})
    catch
        exit:Reason -> fail(Context0, {nostr_publish_exit, Reason});
        Class:Reason -> fail(Context0, {nostr_publish_crashed, Class, Reason})
    end.

release_nostr_payload(Mint, Image, Quote, Purchase) ->
    Token = to_bin(maps:get(token_id, Mint)),
    Contract = to_bin(maps:get(contract_id, Mint)),
    Release = to_bin(maps:get(release, Mint, <<>>)),
    Platform = to_bin(maps:get(platform, Mint, <<>>)),
    GitSha = to_bin(maps:get(git_sha, Mint, <<>>)),
    Meta = strip_ipfs_prefix(to_bin(maps:get(metadata_cid, Mint, <<>>))),
    Asset = strip_ipfs_prefix(to_bin(maps:get(asset_cid, Mint, <<>>))),
    ImageUrl = maps:get(url, Image),
    Base = [
        <<"⚡ DamageBDD Build Release NFT\n\n">>,
        <<"Release: ">>, Release, <<"\n">>,
        <<"Platform: ">>, Platform, <<"\n">>,
        <<"Token: #">>, Token, <<"\n">>,
        <<"Contract: ">>, Contract, <<"\n">>,
        <<"Git: ">>, GitSha, <<"\n\n">>,
        <<"Metadata: ipfs://">>, Meta, <<"\n">>,
        <<"Artifact: ipfs://">>, Asset, <<"\n">>,
        <<"Image: ">>, ImageUrl, <<"\n">>
    ],
    Sale = sale_note_lines(Quote, Purchase),
    Content = iolist_to_binary([
        Base,
        Sale,
        <<"\n#DamageBDD #BuildNFT #aeternity #nostr">>
    ]),
    Alt = iolist_to_binary([
        <<"DamageBDD build release NFT #">>, Token,
        <<" for ">>, Release, <<" on ">>, Platform
    ]),
    Imeta = [
        <<"imeta">>,
        <<"url ", ImageUrl/binary>>,
        <<"m image/svg+xml">>,
        <<"dim 1200x630">>,
        <<"alt ", Alt/binary>>,
        <<"x ", (maps:get(sha256, Image))/binary>>
    ],
    Tags0 = [
        [<<"t">>, <<"DamageBDD">>],
        [<<"t">>, <<"BuildNFT">>],
        [<<"t">>, Platform],
        [<<"r">>, <<"ipfs://", Meta/binary>>],
        [<<"r">>, <<"ipfs://", Asset/binary>>],
        Imeta
    ],
    Tags = sale_note_tags(Quote, Purchase, Tags0),
    {Content, Tags}.

sale_note_lines(none, none) ->
    <<>>;
sale_note_lines(Quote, Purchase) ->
    DamageText = maps:get(damage_text, Quote),
    Sats = integer_to_binary(maps:get(sats, Quote)),
    BTC = price_text(maps:get(btc_usdt, Quote)),
    DamageUSDT = price_text(maps:get(damage_usdt, Quote)),
    Bolt11 = maps:get(bolt11, Purchase),
    Expiry = integer_to_binary(maps:get(expiry_seconds, Purchase)),
    [
        <<"\nFor sale: ">>, DamageText, <<" DAMAGE ≈ ">>, Sats, <<" sats\n">>,
        <<"Spot: DAMAGE/USDT ">>, DamageUSDT, <<" • BTC/USDT ">>, BTC, <<"\n">>,
        <<"⚡ Lightning invoice (spot quote, expires in ">>, Expiry, <<"s):\n">>,
        <<"lightning:">>, Bolt11, <<"\n">>
    ].

sale_note_tags(none, none, Tags) ->
    Tags;
sale_note_tags(Quote, Purchase, Tags) ->
    Tags ++ [
        [<<"price">>, maps:get(damage_text, Quote), <<"DAMAGE">>],
        [<<"price">>, integer_to_binary(maps:get(sats, Quote)), <<"SAT">>],
        [<<"lightning">>, maps:get(bolt11, Purchase)]
    ].

build_release_card_svg(Mint, Quote) ->
    Token = to_bin(maps:get(token_id, Mint)),
    Contract = to_bin(maps:get(contract_id, Mint)),
    Release = xml_escape(short_text(maps:get(release, Mint, <<>>), 44)),
    Platform = xml_escape(short_text(maps:get(platform, Mint, <<>>), 32)),
    GitSha = xml_escape(short_text(maps:get(git_sha, Mint, <<>>), 18)),
    Asset = xml_escape(short_text(strip_ipfs_prefix(to_bin(maps:get(asset_cid, Mint, <<>>))), 52)),
    ContractShort = xml_escape(short_text(Contract, 48)),
    Seed = crypto:hash(sha256, <<Contract/binary, ":", Token/binary>>),
    <<A, B, C, D, E, F, _/binary>> = Seed,
    Color1 = color_hex(24 + (A rem 80), 35 + (B rem 75), 80 + (C rem 100)),
    Color2 = color_hex(60 + (D rem 130), 25 + (E rem 85), 90 + (F rem 120)),
    SaleBadge = release_card_sale_badge(Quote),
    iolist_to_binary([
        <<"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"630\" viewBox=\"0 0 1200 630\">">>,
        <<"<defs><linearGradient id=\"bg\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\">">>,
        <<"<stop offset=\"0%\" stop-color=\"">>, Color1, <<"\"/><stop offset=\"100%\" stop-color=\"">>, Color2, <<"\"/></linearGradient>">>,
        <<"<linearGradient id=\"shine\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\"><stop offset=\"0%\" stop-color=\"#ffffff\" stop-opacity=\"0.08\"/><stop offset=\"100%\" stop-color=\"#ffffff\" stop-opacity=\"0.01\"/></linearGradient></defs>">>,
        <<"<rect width=\"1200\" height=\"630\" rx=\"36\" fill=\"url(#bg)\"/>">>,
        <<"<circle cx=\"1080\" cy=\"90\" r=\"230\" fill=\"#ffffff\" opacity=\"0.055\"/><circle cx=\"1050\" cy=\"580\" r=\"300\" fill=\"#000000\" opacity=\"0.08\"/>">>,
        <<"<rect x=\"48\" y=\"42\" width=\"1104\" height=\"546\" rx=\"28\" fill=\"url(#shine)\" stroke=\"#ffffff\" stroke-opacity=\"0.18\"/>">>,
        <<"<text x=\"82\" y=\"105\" fill=\"#ffffff\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"34\" font-weight=\"800\">DamageBDD</text>">>,
        <<"<text x=\"82\" y=\"143\" fill=\"#ffffff\" opacity=\"0.70\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"18\" letter-spacing=\"4\">BUILD RELEASE NFT</text>">>,
        <<"<text x=\"82\" y=\"236\" fill=\"#ffffff\" opacity=\"0.68\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"19\">RELEASE</text>">>,
        <<"<text x=\"82\" y=\"281\" fill=\"#ffffff\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"42\" font-weight=\"750\">">>, Release, <<"</text>">>,
        <<"<text x=\"82\" y=\"333\" fill=\"#ffffff\" opacity=\"0.82\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"24\">">>, Platform, <<"</text>">>,
        <<"<rect x=\"820\" y=\"82\" width=\"270\" height=\"92\" rx=\"22\" fill=\"#000000\" opacity=\"0.20\"/>">>,
        <<"<text x=\"845\" y=\"117\" fill=\"#ffffff\" opacity=\"0.68\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"16\">TOKEN</text>">>,
        <<"<text x=\"845\" y=\"153\" fill=\"#ffffff\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"30\" font-weight=\"800\">#">>, xml_escape(Token), <<"</text>">>,
        <<"<text x=\"82\" y=\"405\" fill=\"#ffffff\" opacity=\"0.62\" font-family=\"ui-monospace,SFMono-Regular,monospace\" font-size=\"15\">contract  ">>, ContractShort, <<"</text>">>,
        <<"<text x=\"82\" y=\"438\" fill=\"#ffffff\" opacity=\"0.62\" font-family=\"ui-monospace,SFMono-Regular,monospace\" font-size=\"15\">git       ">>, GitSha, <<"</text>">>,
        <<"<text x=\"82\" y=\"471\" fill=\"#ffffff\" opacity=\"0.62\" font-family=\"ui-monospace,SFMono-Regular,monospace\" font-size=\"15\">artifact  ">>, Asset, <<"</text>">>,
        SaleBadge,
        <<"<text x=\"82\" y=\"555\" fill=\"#ffffff\" opacity=\"0.68\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"17\">Content-addressed build artifact • AEX-141 release record</text>">>,
        <<"</svg>">>
    ]).

release_card_sale_badge(none) ->
    <<>>;
release_card_sale_badge(Quote) ->
    DamageText = xml_escape(maps:get(damage_text, Quote)),
    Sats = integer_to_binary(maps:get(sats, Quote)),
    [
        <<"<rect x=\"82\" y=\"495\" width=\"650\" height=\"40\" rx=\"20\" fill=\"#000000\" opacity=\"0.18\"/>">>,
        <<"<text x=\"102\" y=\"521\" fill=\"#ffffff\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"17\" font-weight=\"700\">FOR SALE • ">>,
        DamageText, <<" DAMAGE • ≈ ">>, Sats, <<" sats • Lightning</text>">>
    ].

listing_relays(Context, Opts) ->
    case map_get_any([<<"relays">>, relays, "relays"], Opts, undefined) of
        Rs when is_list(Rs), Rs =/= [] ->
            [to_bin(R) || R <- Rs];
        _ ->
            nostr_pool:default_relays(Context)
    end.

normalize_post_options(M) when is_map(M) ->
    M;
normalize_post_options(<<>>) ->
    #{};
normalize_post_options(Bin) when is_binary(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        M when is_map(M) -> M;
        _ -> #{}
    catch
        _:_ -> #{}
    end;
normalize_post_options(List) when is_list(List) ->
    normalize_post_options(to_bin(List));
normalize_post_options(_) ->
    #{}.

option_pos_int(Opts, Keys, Default) ->
    case map_get_any(Keys, Opts, Default) of
        Value ->
            case parse_pos_int(Value) of
                {ok, I} -> I;
                _ -> Default
            end
    end.

image_gateway(Opts) ->
    case map_get_any(
        [<<"image_gateway">>, image_gateway, "image_gateway"], Opts, undefined
    ) of
        undefined ->
            case application:get_env(damage, build_release_nft_image_gateway) of
                {ok, Value} -> to_bin(Value);
                undefined -> <<"https://damagebdd.com/ipfs">>
            end;
        Value ->
            to_bin(Value)
    end.

append_gateway_cid(Gateway0, Cid) ->
    Gateway = trim_trailing_slash(to_bin(Gateway0)),
    <<Gateway/binary, "/", Cid/binary>>.

trim_trailing_slash(<<>>) -> <<>>;
trim_trailing_slash(Bin) ->
    case binary:last(Bin) of
        $/ -> trim_trailing_slash(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

parse_pos_number(V) when is_integer(V), V > 0 ->
    {ok, float(V)};
parse_pos_number(V) when is_float(V), V > 0 ->
    {ok, V};
parse_pos_number(V) when is_binary(V) ->
    parse_pos_number(binary_to_list(V));
parse_pos_number(V) when is_list(V) ->
    S = string:trim(V),
    case string:to_float(S) of
        {F, []} when F > 0 -> {ok, F};
        {error, no_float} ->
            case string:to_integer(S) of
                {I, []} when I > 0 -> {ok, float(I)};
                _ -> {error, not_positive_number}
            end;
        _ -> {error, not_positive_number}
    end;
parse_pos_number(_) ->
    {error, not_positive_number}.

price_text(V) when is_float(V) ->
    to_bin(io_lib:format("~.8g", [V]));
price_text(V) ->
    to_bin(V).

short_text(Value, MaxChars) ->
    Bin = to_bin(Value),
    try unicode:characters_to_list(Bin) of
        Chars ->
            case length(Chars) =< MaxChars of
                true -> Bin;
                false -> unicode:characters_to_binary(lists:sublist(Chars, MaxChars - 1) ++ [16#2026])
            end
    catch
        _:_ -> Bin
    end.

xml_escape(Value) ->
    B0 = to_bin(Value),
    B1 = binary:replace(B0, <<"&">>, <<"&amp;">>, [global]),
    B2 = binary:replace(B1, <<"<">>, <<"&lt;">>, [global]),
    B3 = binary:replace(B2, <<">">>, <<"&gt;">>, [global]),
    B4 = binary:replace(B3, <<"\"">>, <<"&quot;">>, [global]),
    binary:replace(B4, <<"'">>, <<"&apos;">>, [global]).

color_hex(R, G, B) ->
    iolist_to_binary(io_lib:format("#~2.16.0B~2.16.0B~2.16.0B", [R, G, B])).

lower_hex(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

is_charlist([]) -> true;
is_charlist([C | Rest]) when is_integer(C), C >= 0, C =< 255 -> is_charlist(Rest);
is_charlist(_) -> false.

compact_map(Map) when is_map(Map) ->
    #{keys => maps:keys(Map), size => map_size(Map)};
compact_map(Other) ->
    Other.

%% Deterministic, dependency-free error: no filesystem, IPFS, key or chain access.
obsolete_install_publication(Context) ->
    Context#{fail =>
        <<"Build release NFT failed: obsolete_install_publication_step. "
          "Prepare installation metadata from the artifact CID BEFORE uploading "
          "meta.json and minting. Remove the post-mint package-file publication "
          "step; container-to-IPFS export does not populate run_dir/docker/out. "
          "A previously successful mint is not rolled back.">>}.

%% ------------------------------------------------------------------
%% Release + oracle transaction flow.
%% ------------------------------------------------------------------
mint_from_context(Context, MetaVar, AssetVar, Overrides) ->
    case release_inputs(Context, MetaVar, AssetVar) of
        {ok, MetaCid, AssetCid} ->
            %% Explicit fields must not evaluate an irrelevant fallback (for
            %% example malformed legacy metadata when platform is explicit).
            Release = mint_field(release, Overrides, fun() -> infer_release_name(Context, AssetCid) end),
            Platform = mint_field(platform, Overrides, fun() -> infer_platform(Context) end),
            GitSha = mint_field(git_sha, Overrides, fun() -> infer_git_sha(Context) end),
            mint_release_and_pin(Context, Release, Platform, GitSha, MetaCid, AssetCid);
        {error, Why} -> fail(Context, Why)
    end.

mint_field(Key, Fields, Fallback) ->
    case maps:find(Key, Fields) of
        {ok, Value} -> Value;
        error -> Fallback()
    end.

mint_release_and_pin(Context0, ReleaseName0, Platform0, GitSha0, MetaCid0, AssetCid0) ->
    ReleaseName = to_bin(ReleaseName0),
    Platform = to_bin(Platform0),
    GitSha = to_bin(GitSha0),
    MetaCid = strip_ipfs_prefix(to_bin(MetaCid0)),
    AssetCid = strip_ipfs_prefix(to_bin(AssetCid0)),

    case checked_mint_inputs(Context0, ReleaseName, Platform, GitSha, MetaCid, AssetCid) of
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
                                    finish_release(
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
                            case damage_release_nft:token_release(KeyPair, ContractId, TokenId) of
                                {ok, Existing} ->
                                    Expected = #{release => ReleaseName, platform => Platform,
                                        git_sha => GitSha, metadata_cid => MetaCid, asset_cid => AssetCid},
                                    case existing_release_matches(Existing, Expected) of
                                        true -> {ok, TokenId, #{reused => true}};
                                        false -> {error, {existing_release_content_mismatch, TokenId}}
                                    end;
                                {error, Why} -> {error, {existing_release_read_failed, Why}}
                            end;
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

%% Minting already committed the latest NFT pointer. Discovery never depends
%% on a mutable "latest" oracle question. Announcements are opt-in snapshots.
finish_release(Context, KeyPair, Contract, Token, Release, Platform, GitSha, Meta, Asset, MintCall) ->
    Mint = #{contract_id => Contract, token_id => Token, release => Release,
        platform => Platform, git_sha => GitSha, metadata_cid => Meta, asset_cid => Asset,
        mint_status => mint_status(MintCall), mint_tx_hash => tx_hash(MintCall),
        oracle_status => disabled},
    Base = Context#{build_release_mint_result => Mint},
    case application:get_env(damage, build_release_announce_oracle, false) of
        false -> Base;
        true ->
            Outcome = try pin_platform_latest(Base, KeyPair, Contract, Token, Release,
                Platform, GitSha, Meta, Asset)
            catch _:_ -> #{fail => oracle_announcement_failed} end,
            oracle_announcement_result(Base, Outcome)
    end.

oracle_announcement_result(Base, #{fail := _}) ->
    ?LOG_WARNING("Release NFT minted; optional oracle announcement failed. Do not remint."),
    Mint = maps:get(build_release_mint_result, Base),
    Base#{build_release_mint_result := Mint#{oracle_status => failed,
        oracle_error => oracle_announcement_failed}};
oracle_announcement_result(_Base, #{build_release_mint_result := Mint} = Result) ->
    Result#{build_release_mint_result := Mint#{oracle_status => announced}}.

existing_release_matches(Existing, Expected) ->
    maps:with([release, platform, git_sha, metadata_cid, asset_cid], Existing) =:= Expected.

pin_platform_latest(
    Context0,
    KeyPair,
    ContractId,
    TokenId,
    ReleaseName,
    Platform,
    GitSha,
    MetaCid,
    AssetCid
) ->
    QueryTtl = env_pos_int(build_release_oracle_query_ttl, ?DEFAULT_QUERY_TTL),
    ResponseTtl = env_pos_int(build_release_oracle_response_ttl, ?DEFAULT_RESPONSE_TTL),
    %% Platform snapshots avoid cross-platform interference. The current
    %% contract still resolves the token at response time; same-platform races
    %% can therefore produce a failed OPTIONAL announcement, never a failed mint.
    QueryArgs = [to_list(Platform), integer_to_list(QueryTtl), integer_to_list(ResponseTtl)],
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
                                                            Mint = maps:get(build_release_mint_result, Context0),
                                                            Result = Mint#{
                                                                oracle_question => <<"latest:", Platform/binary>>,
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

%% ------------------------------------------------------------------
%% Input/config helpers.
%% ------------------------------------------------------------------
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
            case application:get_env(damage, build_release_nft_contract) of
                {ok, Configured} -> validate_contract_id(Configured);
                undefined ->
                    case context_account(Context) of
                        {ok, Account} -> damage_contract_bootstrap:ensure_build_release_nft(Account);
                        {error, _} = Error -> Error
                    end
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

checked_mint_inputs(Context, Release, Platform, GitSha, MetaCid, AssetCid) ->
    %% This also rejects ':' release-key collisions and '|' wire delimiters.
    case damage_release_nft:parse_release(release_answer(1, Release, Platform, GitSha, MetaCid, AssetCid)) of
        {ok, Identity} ->
            case is_boolean(application:get_env(damage, build_release_announce_oracle, false)) of
                false -> {error, invalid_build_release_announce_oracle};
                true -> verify_prepared_metadata(Context, Identity)
            end;
        {error, Why} -> {error, {invalid_release_fields, Why}}
    end.

verify_prepared_metadata(Context, Identity) ->
    case maps:find(build_release_installation_expected, Context) of
        error ->
            case application:get_env(damage, build_release_require_installation, false) of
                true -> {error, installation_metadata_not_prepared};
                false -> ok;
                _ -> {error, invalid_build_release_require_installation}
            end;
        {ok, Expected} when is_map(Expected) ->
            %% Re-read the FINAL metadata CID. Uploading an older/different meta
            %% variable after preparation must not silently publish a bad build.
            case damage_release_nft:installation(Identity) of
                {ok, Actual} ->
                    case damage_release_nft:installation_identity(Actual) =:= Expected of
                        true -> ok;
                        false -> {error, prepared_installation_metadata_mismatch}
                    end;
                {error, Why} -> {error, {prepared_installation_metadata_invalid, Why}}
            end;
        _ -> {error, invalid_prepared_installation_metadata}
    end.

put_context_var(Context, Key, Value) ->
    Bin = to_bin(Key),
    Keys0 = [Key, Bin, to_list(Bin)],
    Keys = case existing_atom(Bin) of {ok, Atom} -> [Atom | Keys0]; error -> Keys0 end,
    lists:foldl(fun(K, Acc) -> maps:put(K, Value, Acc) end, Context, Keys).

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
