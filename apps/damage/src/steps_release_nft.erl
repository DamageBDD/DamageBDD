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
-include_lib("eunit/include/eunit.hrl").
-export([existing_release_matches/2, oracle_announcement_result/2, checked_mint_inputs/6]).
-endif.
-define(DEFAULT_QUERY_TTL, 100).
-define(DEFAULT_RESPONSE_TTL, 50000).

-define(STEP_DISCOVERY_CONFIGURED, ["the build release discovery is configured"]).
-define(STEP_VERIFY_DISCOVERY, ["the latest installable build release must match the minted NFT"]).
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
    "DAMAGE with Lightning checkout"
]).
-define(STEP_CREATE_CHECKOUT, [
    "I create a Lightning checkout invoice for buyer", Buyer
]).
-define(STEP_SETTLE_CHECKOUT, [
    "I settle the Lightning checkout and transfer the build release NFT"
]).

%% ------------------------------------------------------------------
%% Dry-run clauses: advertise only the steps implemented by this module.
%% ------------------------------------------------------------------
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_DISCOVERY_CONFIGURED, _Body) ->
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_VERIFY_DISCOVERY, _Body) ->
    Context;
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
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_CREATE_CHECKOUT, _Body) ->
    _ = Buyer,
    Context;
step_dry(_Config, Context, _Keyword, _LineNo, ?STEP_SETTLE_CHECKOUT, _Body) ->
    Context.

%% ------------------------------------------------------------------
%% Configuration/deployment.
%% ------------------------------------------------------------------
step(_Config, Context, _Keyword, _LineNo, ?STEP_DISCOVERY_CONFIGURED, _Body) ->
    case installation_discovery_config(Context) of
        {ok, Config} ->
            Context#{build_release_nft_contract => maps:get(nft, Config),
                build_release_discovery_config => Config};
        {error, Why} -> fail(Context, {release_discovery_configuration_failed, Why})
    end;
step(_Config, Context, _Keyword, _LineNo, ?STEP_VERIFY_DISCOVERY, _Body) ->
    verify_installable_mint(Context);
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
                            PreparedContext = put_context_var(Updated, "git_sha", maps:get(git_sha, Expected)),
                            ReleaseContext = case maps:find(<<"release">>, Prepared) of
                                {ok, Version} -> put_context_var(PreparedContext, "build_release", Version);
                                error -> PreparedContext
                            end,
                            ReleaseContext#{build_release_installation_expected => Expected,
                                build_release_platform => maps:get(platform, Expected)};
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
    end;
step(_Config, Context, _Keyword, _LineNo, ?STEP_CREATE_CHECKOUT, Body) ->
    create_build_release_checkout(Context, Buyer, Body);
step(_Config, Context, _Keyword, _LineNo, ?STEP_SETTLE_CHECKOUT, _Body) ->
    settle_build_release_checkout(Context).

%% ------------------------------------------------------------------
%% Nostr release card + optional Lightning sale offer.
%%
%% The mint is already final before this step runs. Publication is deliberately
%% post-mint so an IPFS/Nostr/Lightning outage can never make the build release
%% appear unminted or cause a retry to mint a second token.
%% ------------------------------------------------------------------
post_minted_release_nft(Config, Context0, Body, Sale) ->
    case maps:get(build_release_mint_result, Context0, undefined) of
        Mint when is_map(Mint) ->
            Opts = normalize_post_options(Body),
            case generate_release_card(Config, Mint, Sale, Opts) of
                {ok, Image} ->
                    Listing = #{
                        mint => Mint,
                        image => Image,
                        sale => Sale,
                        opts => Opts
                    },
                    Context1 = Context0#{build_release_nft_listing => Listing},
                    publish_release_listing(Context1, Mint, Image, Sale, Opts);
                {error, Why} ->
                    fail(Context0, {release_nft_image_failed, Why})
            end;
        _ ->
            fail(Context0, build_release_mint_not_available)
    end.

create_build_release_checkout(Context0, Buyer0, Body) ->
    Buyer = to_bin(Buyer0),
    Opts = normalize_post_options(Body),
    Listing = maps:get(build_release_nft_listing, Context0, undefined),
    case {validate_checkout_buyer(Buyer), Listing} of
        {ok, #{mint := Mint, sale := Sale}} when is_map(Sale) ->
            case build_sale_quote(Sale, Opts) of
                {ok, Quote} ->
                    case create_checkout_invoice(Context0, Mint, Buyer, Quote, Opts) of
                        {ok, Checkout} ->
                            Context0#{build_release_nft_checkout => Checkout};
                        {error, Why} ->
                            fail(Context0, {lightning_checkout_failed, Why})
                    end;
                {error, Why} ->
                    fail(Context0, {release_nft_spot_quote_failed, Why})
            end;
        {ok, #{sale := none}} ->
            fail(Context0, build_release_nft_not_listed_for_sale);
        {ok, _} ->
            fail(Context0, build_release_nft_listing_not_available);
        {{error, Why}, _} ->
            fail(Context0, {invalid_build_release_nft_buyer, Buyer, Why})
    end.

validate_checkout_buyer(Buyer) ->
    try aeser_api_encoder:decode(Buyer) of
        {account_pubkey, PubKey} when is_binary(PubKey), byte_size(PubKey) =:= 32 -> ok;
        Other -> {error, {unexpected_account_encoding, Other}}
    catch
        Class:Reason -> {error, {account_decode_failed, Class, Reason}}
    end.

build_sale_quote(#{damage_amount := DamageAmount, damage_text := DamageText}, Opts) ->
    MaxAgeMs = option_pos_int(
        Opts,
        [<<"price_max_age_ms">>, price_max_age_ms, "price_max_age_ms"],
        env_pos_int(build_release_nft_price_max_age_ms, 2 * 60 * 1000)
    ),
    case price_feed:damage_to_sats_quote(DamageAmount, MaxAgeMs) of
        {ok, Quote} when is_map(Quote) ->
            {ok, Quote#{damage_text => DamageText}};
        {error, _} = Error ->
            Error;
        Other ->
            {error, {unexpected_price_quote_response, Other}}
    end.

create_checkout_invoice(Context, Mint, Buyer, Quote, Opts) ->
    Expiry = option_pos_int(
        Opts,
        [<<"invoice_expiry_seconds">>, invoice_expiry_seconds, "invoice_expiry_seconds"],
        env_pos_int(build_release_nft_invoice_expiry_seconds, 5 * 60)
    ),
    Contract = to_bin(maps:get(contract_id, Mint)),
    Token = maps:get(token_id, Mint),
    Key = {Contract, Token},
    LockId = checkout_operation_lock_id(Key),
    case global:trans(
        LockId,
        fun() -> create_checkout_invoice_locked(Context, Mint, Buyer, Quote, Opts, Expiry, Key) end
    ) of
        aborted -> {error, checkout_creation_lock_aborted};
        {aborted, Reason} -> {error, {checkout_creation_lock_failed, Reason}};
        Result -> Result
    end.

create_checkout_invoice_locked(Context, Mint, Buyer, Quote, Opts, Expiry, Key) ->
    case ensure_release_owned_by_seller(Context, Mint, Buyer) of
        ok ->
            CheckoutId = checkout_id(Opts),
            Label = checkout_label(Key, CheckoutId),
            ReservationFields = checkout_reservation_fields(Context, Quote),
            case damage_release_nft_checkout_store:reserve(
                Key, Buyer, CheckoutId, Label, ReservationFields
            ) of
                {ok, new, _Record} ->
                    create_reserved_checkout_invoice(Key, Mint, Buyer, Quote, Label, Expiry);
                {ok, existing, Existing} ->
                    reconcile_existing_checkout(Key, Mint, Buyer, Quote, Expiry, Existing, Opts);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

checkout_reservation_fields(Context, Quote) ->
    Base = #{quote => Quote},
    case checkout_listing_snapshot(Context) of
        undefined -> Base;
        Listing -> Base#{listing => Listing}
    end.

checkout_listing_snapshot(Context) ->
    case maps:get(build_release_nft_listing, Context, undefined) of
        Listing when is_map(Listing) ->
            case maps:get(build_release_nft_nostr_event, Context, undefined) of
                Event when is_map(Event) ->
                    case nostr_event_created_at(Event) of
                        CreatedAt when is_integer(CreatedAt), CreatedAt > 0 ->
                            Listing#{nostr_created_at => CreatedAt};
                        _ -> Listing
                    end;
                _ ->
                    Listing
            end;
        _ ->
            undefined
    end.

nostr_event_created_at(Event) when is_map(Event) ->
    map_get_any([created_at, <<"created_at">>, "created_at"], Event, 0);
nostr_event_created_at(_) ->
    0.

ensure_release_owned_by_seller(Context, Mint, Buyer) ->
    case release_keypair(Context) of
        {ok, KeyPair} ->
            Seller = to_bin(maps:get(public_key, KeyPair)),
            case Seller =:= Buyer of
                true ->
                    {error, buyer_is_current_owner};
                false ->
                    case release_token_owner(KeyPair, Mint) of
                        {ok, Seller} -> ok;
                        {ok, Owner} -> {error, {build_release_nft_not_owned_by_seller, Owner}};
                        {error, _} = Error -> Error
                    end
            end;
        {error, _} = Error ->
            Error
    end.

release_token_owner(KeyPair, Mint) ->
    Contract = maps:get(contract_id, Mint),
    Token = maps:get(token_id, Mint),
    case damage_ae:contract_query(
        KeyPair,
        Contract,
        contract_source(),
        "owner",
        [integer_to_list(Token)]
    ) of
        OwnerCall when is_map(OwnerCall) ->
            case call_return(OwnerCall) of
                {ok, EncodedOption} ->
                    case option_value(EncodedOption) of
                        {ok, Owner} -> {ok, to_bin(Owner)};
                        none -> {error, {build_release_nft_token_not_found, Token}};
                        {error, Why} -> {error, {build_release_nft_owner_decode_failed, Why}}
                    end;
                {error, Why} ->
                    {error, {build_release_nft_owner_query_failed, Why}}
            end;
        Error ->
            {error, {build_release_nft_owner_query_failed, Error}}
    end.

checkout_id(Opts) ->
    case map_get_any([<<"checkout_id">>, checkout_id, "checkout_id"], Opts, undefined) of
        undefined -> lower_hex(crypto:strong_rand_bytes(12));
        Value -> to_bin(Value)
    end.

checkout_label({Contract, Token}, CheckoutId) ->
    TokenBin = to_bin(Token),
    <<"build_nft:", Contract/binary, ":", TokenBin/binary, ":", CheckoutId/binary>>.

create_reserved_checkout_invoice(Key, Mint, Buyer, Quote, Label, Expiry) ->
    TokenBin = to_bin(maps:get(token_id, Mint)),
    Description = iolist_to_binary([
        <<"DamageBDD build release NFT #">>, TokenBin,
        <<" for ">>, Buyer
    ]),
    Sats = maps:get(sats, Quote),
    try damage_cln:create_invoice(Sats * 1000, Description, Expiry, Label) of
        Invoice when is_map(Invoice) ->
            persist_checkout_invoice(Key, Mint, Buyer, Quote, Label, Expiry, Invoice);
        {error, _} = Error ->
            recover_created_invoice(Key, Mint, Buyer, Quote, Label, Expiry, Error);
        Other ->
            recover_created_invoice(
                Key,
                Mint,
                Buyer,
                Quote,
                Label,
                Expiry,
                {unexpected_invoice_response, Other}
            )
    catch
        exit:Reason ->
            recover_created_invoice(
                Key, Mint, Buyer, Quote, Label, Expiry, {invoice_service_unavailable, Reason}
            );
        Class:Reason ->
            recover_created_invoice(
                Key, Mint, Buyer, Quote, Label, Expiry, {invoice_create_failed, Class, Reason}
            )
    end.

persist_checkout_invoice(Key, Mint, Buyer, Quote, Label, Expiry, Invoice) ->
    case checkout_from_invoice(Mint, Buyer, Quote, Label, Expiry, Invoice) of
        {ok, Checkout} ->
            StoreFields = maps:with(
                [buyer, label, payment_hash, expires_at, sats, quote],
                Checkout
            ),
            case damage_release_nft_checkout_store:attach_invoice(Key, StoreFields) of
                {ok, _} -> {ok, Checkout};
                {error, Why} -> {error, {checkout_store_update_failed, Why}}
            end;
        {error, _} = Error ->
            %% An invoice exists and may still be payable. Never release the
            %% token reservation merely because its response was malformed.
            Error
    end.

recover_created_invoice(Key, Mint, Buyer, Quote, Label, Expiry, CreateFailure) ->
    case lookup_checkout_invoice(Label) of
        {ok, Invoice} ->
            persist_checkout_invoice(Key, Mint, Buyer, Quote, Label, Expiry, Invoice);
        not_found ->
            %% A transport failure can race CLN committing the invoice. Keep
            %% the reservation and exact label; a retry reuses the same label,
            %% whose CLN uniqueness prevents a second payable invoice.
            {error, {invoice_create_uncertain, Label, CreateFailure, not_found}};
        {error, LookupFailure} ->
            %% Creation is ambiguous. Keep the reservation so a later retry
            %% reconciles this exact label instead of opening a second invoice.
            {error, {invoice_create_uncertain, Label, CreateFailure, LookupFailure}}
    end.

reconcile_existing_checkout(Key, Mint, Buyer, Quote, Expiry, Existing, Opts) ->
    ExistingBuyer = maps:get(buyer, Existing, undefined),
    Label = maps:get(label, Existing, undefined),
    case {ExistingBuyer =:= Buyer, Label} of
        {_, undefined} ->
            {error, {invalid_checkout_store_record, Existing}};
        {SameBuyer, _} ->
            case lookup_checkout_invoice(Label) of
                {ok, Invoice} ->
                    ExistingQuote = existing_checkout_quote(Existing, Invoice, Quote),
                    case invoice_status(Invoice) of
                        expired ->
                            _ = damage_release_nft_checkout_store:mark_status(Key, expired),
                            retry_checkout_after_expiry(Key, Mint, Buyer, Quote, Expiry, Opts);
                        paid when SameBuyer ->
                            _ = damage_release_nft_checkout_store:mark_status(Key, paid),
                            checkout_from_invoice(Mint, Buyer, ExistingQuote, Label, Expiry, Invoice);
                        paid ->
                            {error, {checkout_paid_pending_settlement, ExistingBuyer, Label}};
                        _ when SameBuyer ->
                            checkout_from_invoice(Mint, Buyer, ExistingQuote, Label, Expiry, Invoice);
                        Status ->
                            {error, {checkout_in_progress, ExistingBuyer, Status}}
                    end;
                not_found ->
                    case {SameBuyer, maps:get(status, Existing, reserved)} of
                        {true, reserved} ->
                            ReservedQuote = maps:get(quote, Existing, Quote),
                            create_reserved_checkout_invoice(
                                Key, Mint, Buyer, ReservedQuote, Label, Expiry
                            );
                        {_, expired} ->
                            retry_checkout_after_expiry(
                                Key, Mint, Buyer, Quote, Expiry, Opts
                            );
                        {_, Status} ->
                            {error, {persisted_checkout_invoice_missing, Label, Status}}
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

existing_checkout_quote(Existing, Invoice, FallbackQuote) ->
    StoredQuote = maps:get(quote, Existing, FallbackQuote),
    quote_with_invoice_amount(StoredQuote, Invoice).

retry_checkout_after_expiry(Key, Mint, Buyer, Quote, Expiry, Opts) ->
    BaseId = checkout_id(Opts),
    CheckoutId = <<BaseId/binary, "-", (lower_hex(crypto:strong_rand_bytes(4)))/binary>>,
    Label = checkout_label(Key, CheckoutId),
    case damage_release_nft_checkout_store:reserve(
        Key, Buyer, CheckoutId, Label, #{quote => Quote}
    ) of
        {ok, new, _} -> create_reserved_checkout_invoice(Key, Mint, Buyer, Quote, Label, Expiry);
        {ok, existing, Record} -> {error, {checkout_in_progress, Record}};
        {error, _} = Error -> Error
    end.

lookup_checkout_invoice(Label) ->
    case damage_cln:list_invoices_by_label(Label) of
        #{invoices := []} -> not_found;
        #{invoices := [Invoice | _]} when is_map(Invoice) -> {ok, Invoice};
        #{<<"invoices">> := []} -> not_found;
        #{<<"invoices">> := [Invoice | _]} when is_map(Invoice) -> {ok, Invoice};
        {error, _} = Error -> Error;
        Other -> {error, {unexpected_invoice_lookup_response, Other}}
    end.

checkout_from_invoice(Mint, Buyer, Quote0, Label, Expiry, Invoice) ->
    case map_get_any([bolt11, <<"bolt11">>, "bolt11"], Invoice, undefined) of
        undefined ->
            {error, {invoice_missing_bolt11, compact_map(Invoice)}};
        Bolt110 ->
            Status = invoice_status(Invoice),
            case Status of
                expired ->
                    {error, {checkout_invoice_expired, Label}};
                _ ->
                    Quote = quote_with_invoice_amount(Quote0, Invoice),
                    Bolt11 = to_bin(Bolt110),
                    {ok, #{
                        mint => Mint,
                        buyer => Buyer,
                        quote => Quote,
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
                        status => Status,
                        sats => maps:get(sats, Quote)
                    }}
            end
    end.

quote_with_invoice_amount(Quote, Invoice) when is_map(Quote) ->
    case invoice_sats(Invoice) of
        {ok, Sats} -> Quote#{sats => Sats};
        error -> Quote
    end.

invoice_sats(Invoice) ->
    Amount = map_get_any([amount_msat, <<"amount_msat">>, "amount_msat"], Invoice, undefined),
    case msat_value(Amount) of
        Msat when is_integer(Msat), Msat > 0 -> {ok, (Msat + 999) div 1000};
        _ -> error
    end.

msat_value(V) when is_integer(V) -> V;
msat_value(#{msat := V}) -> msat_value(V);
msat_value(#{<<"msat">> := V}) -> msat_value(V);
msat_value(V) when is_list(V) -> msat_value(to_bin(V));
msat_value(V) when is_binary(V) ->
    Numeric =
        case binary:split(V, <<"msat">>) of
            [N, <<>>] -> N;
            _ -> V
        end,
    try binary_to_integer(Numeric) catch _:_ -> undefined end;
msat_value(_) -> undefined.

settle_build_release_checkout(Context0) ->
    case maps:get(build_release_nft_checkout, Context0, undefined) of
        #{label := Label, buyer := Buyer, mint := Mint} = Checkout ->
            Contract = to_bin(maps:get(contract_id, Mint)),
            Token = maps:get(token_id, Mint),
            Key = {Contract, Token},
            LockId = checkout_operation_lock_id(Key),
            case global:trans(
                LockId,
                fun() ->
                    settle_build_release_checkout_locked(
                        Context0, Checkout, Mint, Buyer, Label, Key
                    )
                end
            ) of
                aborted ->
                    fail(Context0, checkout_settlement_lock_aborted);
                {aborted, Reason} ->
                    fail(Context0, {checkout_settlement_lock_failed, Reason});
                Result ->
                    Result
            end;
        _ ->
            fail(Context0, build_release_nft_checkout_not_available)
    end.

checkout_operation_lock_id(Key) ->
    {{?MODULE, {checkout_operation, Key}}, self()}.

settle_build_release_checkout_locked(Context0, Checkout, Mint, Buyer, Label, Key) ->
    case damage_release_nft_checkout_store:get(Key) of
        {ok, #{buyer := Buyer, label := Label, status := settled}} ->
            reconcile_already_settled_checkout(Context0, Checkout, Mint, Buyer, Key);
        {ok, #{buyer := Buyer, label := Label} = Stored} ->
            settle_bound_checkout(Context0, Checkout, Mint, Buyer, Label, Key, Stored);
        {ok, Existing} ->
            fail(Context0, {checkout_binding_mismatch, Existing});
        not_found ->
            fail(Context0, build_release_nft_checkout_not_persisted);
        {error, Why} ->
            fail(Context0, {checkout_store_failed, Why})
    end.

reconcile_already_settled_checkout(Context0, Checkout, Mint, Buyer, Key) ->
    case release_keypair(Context0) of
        {ok, KeyPair} ->
            case release_token_owner(KeyPair, Mint) of
                {ok, Buyer} ->
                    finalize_checkout_settlement(
                        Context0, Checkout, Mint, Buyer, undefined, Key, already_settled
                    );
                {ok, Owner} ->
                    fail(Context0, {settled_checkout_owner_mismatch, Buyer, Owner});
                {error, Why} ->
                    fail(Context0, {settled_checkout_owner_check_failed, Why})
            end;
        {error, Why} ->
            fail(Context0, Why)
    end.

settle_bound_checkout(Context0, Checkout, Mint, Buyer, Label, Key, Stored) ->
    case lookup_checkout_invoice(Label) of
        {ok, Invoice} ->
            case invoice_status(Invoice) of
                paid ->
                    case maps:get(status, Stored, pending) of
                        settling ->
                            reconcile_settling_checkout(
                                Context0, Checkout, Mint, Buyer, Invoice, Key, Stored
                            );
                        _ ->
                            case damage_release_nft_checkout_store:mark_status(Key, paid) of
                                {ok, _} ->
                                    transfer_paid_build_release(
                                        Context0, Checkout, Mint, Buyer, Invoice, Key
                                    );
                                {error, Why} ->
                                    fail(Context0, {checkout_store_paid_failed, Why})
                            end
                    end;
                Status ->
                    fail(Context0, {lightning_checkout_not_paid, Status})
            end;
        not_found ->
            fail(Context0, {lightning_checkout_invoice_not_found, Label});
        {error, Why} ->
            fail(Context0, {lightning_checkout_lookup_failed, Why})
    end.

transfer_paid_build_release(Context0, Checkout, Mint, Buyer, Invoice, Key) ->
    Contract = maps:get(contract_id, Mint),
    Token = maps:get(token_id, Mint),
    case release_keypair(Context0) of
        {ok, KeyPair} ->
            Seller = to_bin(maps:get(public_key, KeyPair)),
            case release_token_owner(KeyPair, Mint) of
                {ok, Buyer} ->
                    finalize_checkout_settlement(
                        Context0, Checkout, Mint, Buyer, Invoice, Key, already_owned_by_buyer
                    );
                {ok, Seller} ->
                    case damage_release_nft_checkout_store:put_fields(Key, #{
                        status => settling,
                        transfer_started_at => erlang:system_time(second)
                    }) of
                        {ok, _} ->
                            Args = [to_list(Buyer), integer_to_list(Token), "None"],
                            TransferResult = damage_ae:contract_call_payfor_user_safe(
                                KeyPair,
                                Contract,
                                contract_source(),
                                "transfer",
                                Args
                            ),
                            settle_safe_transfer_result(
                                Context0,
                                Checkout,
                                Mint,
                                Buyer,
                                Invoice,
                                Key,
                                KeyPair,
                                TransferResult
                            );
                        {error, Why} ->
                            fail(Context0, {checkout_store_settling_failed, Why})
                    end;
                {ok, Owner} ->
                    fail(Context0, {build_release_nft_no_longer_owned_by_seller, Owner});
                {error, Why} ->
                    fail(Context0, {build_release_nft_owner_check_failed, Why})
            end;
        {error, Why} ->
            fail(Context0, Why)
    end.

settle_safe_transfer_result(
    Context0, Checkout, Mint, Buyer, Invoice, Key, _KeyPair,
    {confirmed, TxHash, TransferCall}
) when is_map(TransferCall) ->
    _ = damage_release_nft_checkout_store:put_fields(Key, #{
        transfer_tx_hash => to_bin(TxHash),
        transfer_confirmed_at => erlang:system_time(second)
    }),
    case call_return(TransferCall) of
        {ok, _} ->
            finalize_checkout_settlement(
                Context0,
                Checkout,
                Mint,
                Buyer,
                Invoice,
                Key,
                #{tx_hash => to_bin(TxHash), result => TransferCall}
            );
        {error, Why} ->
            %% The transaction is confirmed and the contract call failed, so
            %% ownership did not move. Return to paid: a retry is safe.
            restore_paid_checkout_after_definite_failure(
                Context0,
                Key,
                {build_release_nft_transfer_rejected, to_bin(TxHash), Why, TransferCall}
            )
    end;
settle_safe_transfer_result(
    Context0, _Checkout, _Mint, _Buyer, _Invoice, Key, _KeyPair,
    {not_submitted, Reason}
) ->
    %% No transaction reached post_tx/1. Re-open settlement from the paid state
    %% instead of leaving the checkout permanently stuck in settling.
    restore_paid_checkout_after_definite_failure(
        Context0, Key, {build_release_nft_transfer_not_submitted, Reason}
    );
settle_safe_transfer_result(
    Context0, Checkout, Mint, Buyer, Invoice, Key, KeyPair,
    {uncertain, TxHash, Reason}
) ->
    _ = persist_uncertain_transfer(Key, TxHash, Reason),
    reconcile_transfer_outcome(
        Context0,
        Checkout,
        Mint,
        Buyer,
        Invoice,
        Key,
        KeyPair,
        {build_release_nft_transfer_uncertain, TxHash, Reason}
    );
settle_safe_transfer_result(
    Context0, Checkout, Mint, Buyer, Invoice, Key, KeyPair, Unexpected
) ->
    _ = persist_uncertain_transfer(Key, undefined, {unexpected_safe_transfer_result, Unexpected}),
    reconcile_transfer_outcome(
        Context0,
        Checkout,
        Mint,
        Buyer,
        Invoice,
        Key,
        KeyPair,
        {build_release_nft_transfer_uncertain, Unexpected}
    ).

restore_paid_checkout_after_definite_failure(Context0, Key, Failure) ->
    case damage_release_nft_checkout_store:put_fields(Key, #{
        status => paid,
        transfer_error => compact_transfer_error(Failure),
        transfer_failed_at => erlang:system_time(second)
    }) of
        {ok, _} -> fail(Context0, Failure);
        {error, Why} -> fail(Context0, {checkout_store_paid_restore_failed, Failure, Why})
    end.

persist_uncertain_transfer(Key, TxHash, Reason) ->
    Fields0 = #{
        status => settling,
        transfer_error => compact_transfer_error(Reason),
        transfer_uncertain_at => erlang:system_time(second)
    },
    Fields =
        case TxHash of
            undefined -> Fields0;
            _ -> Fields0#{transfer_tx_hash => to_bin(TxHash)}
        end,
    damage_release_nft_checkout_store:put_fields(Key, Fields).

compact_transfer_error(Term) ->
    %% Keep DETS records bounded and avoid persisting large stacktraces/maps.
    to_bin(io_lib:format("~P", [Term, 12])).

reconcile_transfer_outcome(Context0, Checkout, Mint, Buyer, Invoice, Key, KeyPair, Failure) ->
    Seller = to_bin(maps:get(public_key, KeyPair)),
    case release_token_owner(KeyPair, Mint) of
        {ok, Buyer} ->
            finalize_checkout_settlement(
                Context0, Checkout, Mint, Buyer, Invoice, Key, reconciled_after_transfer
            );
        {ok, Seller} ->
            %% Keep status=settling. A retry must reconcile ownership rather
            %% than submit another transfer while the original result is unknown.
            fail(Context0, {build_release_nft_transfer_uncertain, Failure});
        {ok, Owner} ->
            fail(Context0, {build_release_nft_transfer_owner_changed, Owner, Failure});
        {error, Why} ->
            fail(Context0, {build_release_nft_transfer_outcome_unknown, Failure, Why})
    end.

reconcile_settling_checkout(Context0, Checkout, Mint, Buyer, Invoice, Key, Stored) ->
    case release_keypair(Context0) of
        {ok, KeyPair} ->
            Seller = to_bin(maps:get(public_key, KeyPair)),
            case release_token_owner(KeyPair, Mint) of
                {ok, Buyer} ->
                    finalize_checkout_settlement(
                        Context0, Checkout, Mint, Buyer, Invoice, Key, reconciled_settlement
                    );
                {ok, Seller} ->
                    fail(Context0, {
                        build_release_nft_transfer_still_uncertain,
                        maps:get(transfer_tx_hash, Stored, undefined)
                    });
                {ok, Owner} ->
                    fail(Context0, {build_release_nft_transfer_owner_changed, Owner});
                {error, Why} ->
                    fail(Context0, {build_release_nft_transfer_owner_check_failed, Why})
             end;
         {error, Why} ->
             fail(Context0, Why)
    end.

finalize_checkout_settlement(Context0, Checkout, Mint, Buyer, Invoice, Key, TransferResult) ->
    case damage_release_nft_checkout_store:put_fields(Key, #{
        status => settled,
        settled_at => erlang:system_time(second),
        transfer_result => compact_transfer_error(TransferResult)
    }) of
        {ok, _} ->
            Checkout1 = Checkout#{status => settled},
            Checkout2 =
                case Invoice of
                    undefined -> Checkout1;
                    _ -> Checkout1#{paid_invoice => Invoice}
                end,
            Context1 = Context0#{
                build_release_nft_checkout := Checkout2,
                build_release_nft_transfer => TransferResult
            },
            best_effort_publish_sold_listing(Context1, Mint, Buyer);
        {error, Why} ->
            fail(Context0, {checkout_store_settlement_failed, Why})
    end.

best_effort_publish_sold_listing(Context0, Mint, Buyer) ->
    Contract = to_bin(maps:get(contract_id, Mint)),
    Token = maps:get(token_id, Mint),
    Key = {Contract, Token},
    case checkout_listing_for_sold_publish(Context0, Mint) of
        {ok, #{image := Image, sale := Sale} = Listing} when is_map(Sale) ->
            Opts = maps:get(opts, Listing, #{}),
            SoldSale = Sale#{status => sold, buyer => Buyer},
            case generate_sold_release_card(Mint, SoldSale, Image, Opts) of
                {ok, SoldImage} ->
                    PreviousCreatedAt = maps:get(nostr_created_at, Listing, 0),
                    wait_for_nostr_replacement_slot(PreviousCreatedAt),
                    SoldListing = Listing#{image => SoldImage, sale => SoldSale},
                    Context1 = Context0#{build_release_nft_listing => SoldListing},
                    Published0 = publish_release_listing(
                        Context1, Mint, SoldImage, SoldSale, Opts
                    ),
                    Published = normalize_sold_publish_result(Published0, PreviousCreatedAt),
                    persist_sold_listing_publish(Key, SoldListing, Published);
                {error, Why} ->
                    Context0#{build_release_nft_sold_publish_error => {sold_card_failed, Why}}
            end;
        {error, Why} ->
            Context0#{build_release_nft_sold_publish_error => Why}
    end.

checkout_listing_for_sold_publish(Context, Mint) ->
    Contract = to_bin(maps:get(contract_id, Mint)),
    Token = maps:get(token_id, Mint),
    Key = {Contract, Token},
    StoredListing =
        case damage_release_nft_checkout_store:get(Key) of
            {ok, #{listing := Listing}} when is_map(Listing) -> Listing;
            _ -> undefined
        end,
    case maps:get(build_release_nft_listing, Context, undefined) of
        Listing0 when is_map(Listing0) ->
            {ok, merge_listing_metadata(Listing0, StoredListing)};
        _ when is_map(StoredListing) ->
            {ok, StoredListing};
        _ ->
            {error, sold_listing_metadata_not_persisted}
    end.

merge_listing_metadata(Listing, Stored) when is_map(Stored) ->
    case maps:get(nostr_created_at, Listing, undefined) of
        undefined ->
            case maps:get(nostr_created_at, Stored, undefined) of
                undefined -> Listing;
                CreatedAt -> Listing#{nostr_created_at => CreatedAt}
            end;
        _ -> Listing
    end;
merge_listing_metadata(Listing, _) ->
    Listing.

generate_sold_release_card(Mint, SoldSale, ActiveImage, Opts) ->
    Path = sold_release_card_path(Mint, ActiveImage),
    Svg = build_release_card_svg(Mint, SoldSale),
    case filelib:ensure_dir(Path) of
        ok ->
            case file:write_file(Path, Svg, [binary]) of
                ok ->
                    case safe_ipfs_add_file(Path) of
                        {ok, AddResult} ->
                            Name = filename:basename(Path),
                            case ipfs_file_cid(AddResult, Name) of
                                {ok, Cid} ->
                                    Gateway = image_gateway(Opts),
                                    {ok, #{
                                        cid => Cid,
                                        uri => <<"ipfs://", Cid/binary>>,
                                        url => append_gateway_cid(Gateway, Cid),
                                        mime => <<"image/svg+xml">>,
                                        dimensions => <<"1200x630">>,
                                        sha256 => lower_hex(crypto:hash(sha256, Svg)),
                                        file => to_bin(Path)
                                    }};
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, Why} -> {error, {write_sold_release_card_failed, Path, Why}}
            end;
        {error, Why} ->
            {error, {sold_release_card_directory_failed, Path, Why}}
    end.

sold_release_card_path(Mint, ActiveImage) ->
    Token = maps:get(token_id, Mint),
    case maps:get(file, ActiveImage, undefined) of
        File when is_binary(File); is_list(File) ->
            Existing = to_list(File),
            Root = filename:rootname(Existing),
            Root ++ "-sold.svg";
        _ ->
            TmpDir =
                case os:getenv("TMPDIR") of
                    false -> "/tmp";
                    Dir -> Dir
                end,
            filename:join(
                TmpDir,
                lists:flatten(io_lib:format("damage-build-release-nft-~B-sold.svg", [Token]))
            )
    end.

wait_for_nostr_replacement_slot(PreviousCreatedAt)
    when is_integer(PreviousCreatedAt), PreviousCreatedAt > 0 ->
    Now = erlang:system_time(second),
    DelayMs = replacement_delay_ms(PreviousCreatedAt, Now),
    case DelayMs > 0 of
        true -> timer:sleep(DelayMs);
        false -> ok
    end;
wait_for_nostr_replacement_slot(_) ->
    ok.

replacement_delay_ms(PreviousCreatedAt, Now) when Now =< PreviousCreatedAt ->
    (PreviousCreatedAt + 1 - Now) * 1000;
replacement_delay_ms(_PreviousCreatedAt, _Now) ->
    0.

normalize_sold_publish_result(Published, PreviousCreatedAt) ->
    case maps:take(fail, Published) of
        {Reason, Clean} ->
            Clean#{build_release_nft_sold_publish_error => Reason};
        error ->
            Event = maps:get(build_release_nft_nostr_event, Published, #{}),
            CreatedAt = nostr_event_created_at(Event),
            case PreviousCreatedAt > 0 andalso CreatedAt =< PreviousCreatedAt of
                true ->
                    Published#{
                        build_release_nft_sold_publish_error => {
                            replacement_timestamp_not_newer,
                            PreviousCreatedAt,
                            CreatedAt
                        }
                    };
                false ->
                    Published
            end
    end.

persist_sold_listing_publish(Key, SoldListing, Published) ->
    case maps:get(build_release_nft_sold_publish_error, Published, undefined) of
        undefined ->
            case maps:get(build_release_nft_nostr_event, Published, undefined) of
                Event when is_map(Event) ->
                    CreatedAt = nostr_event_created_at(Event),
                    EventId = map_get_any([id, <<"id">>, "id"], Event, undefined),
                    PersistedListing =
                        case CreatedAt of
                            Ts when is_integer(Ts), Ts > 0 -> SoldListing#{nostr_created_at => Ts};
                            _ -> SoldListing
                        end,
                    Fields0 = #{listing => PersistedListing},
                    Fields =
                        case EventId of
                            undefined -> Fields0;
                            _ -> Fields0#{sold_nostr_event_id => to_bin(EventId)}
                        end,
                    case damage_release_nft_checkout_store:put_fields(Key, Fields) of
                        {ok, _} -> Published;
                        {error, Why} ->
                            Published#{build_release_nft_sold_publish_error => {
                                sold_listing_persist_failed, Why
                            }}
                    end;
                _ ->
                    Published#{build_release_nft_sold_publish_error => sold_event_missing}
            end;
        _ ->
            Published
    end.


invoice_status(Invoice) ->
    case map_get_any([status, <<"status">>, "status"], Invoice, unknown) of
        paid -> paid;
        <<"paid">> -> paid;
        "paid" -> paid;
        complete -> paid;
        <<"complete">> -> paid;
        "complete" -> paid;
        unpaid -> unpaid;
        <<"unpaid">> -> unpaid;
        "unpaid" -> unpaid;
        expired -> expired;
        <<"expired">> -> expired;
        "expired" -> expired;
        Other -> Other
    end.

generate_release_card(Config, Mint, Sale, Opts) ->
    case lists:keyfind(run_dir, 1, Config) of
        {run_dir, RunDir0} ->
            RunDir = to_list(RunDir0),
            Token = maps:get(token_id, Mint),
            Name = lists:flatten(io_lib:format("build-release-nft-~B.svg", [Token])),
            Path = filename:join([RunDir, "nft", Name]),
            Svg = build_release_card_svg(Mint, Sale),
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

publish_release_listing(Context0, Mint, Image, Sale, Opts) ->
    {Kind, Content, Tags} = release_nostr_payload(Mint, Image, Sale),
    Relays = listing_relays(Context0, Opts),
    TimeoutMs = option_pos_int(
        Opts,
        [<<"publish_timeout_ms">>, publish_timeout_ms, "publish_timeout_ms"],
        50000
    ),
    try damage_nostr:create_signed_event(Kind, Content, Tags) of
        {ok, Event} when is_map(Event) ->
            case nostr_pool:ensure_started(Relays) of
                ok ->
                    EventId = maps:get(<<"id">>, Event, undefined),
                    ?LOG_INFO(
                        "Publishing build release NFT Nostr event event_id=~p relays=~p",
                        [EventId, Relays]
                    ),
                    case nostr_pool:publish_sync_detailed(Event, Relays, TimeoutMs) of
                        {ok, PublishAck} ->
                            PostResult = #{
                                event_id => EventId,
                                pubkey => maps:get(<<"pubkey">>, Event, undefined),
                                relays => Relays,
                                publish_ack => PublishAck,
                                image_cid => maps:get(cid, Image),
                                image_url => maps:get(url, Image),
                                sale => Sale
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

release_nostr_payload(Mint, Image, Sale) ->
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
    Content = iolist_to_binary([
        Base,
        sale_note_lines(Sale),
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
    case Sale of
        none ->
            {1, Content, Tags0};
        #{status := sold, damage_text := DamageText} ->
            DTag = <<"build-release-nft:", Contract/binary, ":", Token/binary>>,
            {30078, Content, Tags0 ++ [
                [<<"d">>, DTag],
                [<<"price">>, DamageText, <<"DAMAGE">>],
                [<<"status">>, <<"sold">>]
            ]};
        #{damage_text := DamageText} ->
            %% NIP-33 parameterized replaceable event: retries replace the same
            %% token listing instead of creating duplicate sale announcements.
            DTag = <<"build-release-nft:", Contract/binary, ":", Token/binary>>,
            {30078, Content, Tags0 ++ [
                [<<"d">>, DTag],
                [<<"price">>, DamageText, <<"DAMAGE">>],
                [<<"payment">>, <<"lightning">>]
            ]}
    end.

sale_note_lines(none) ->
    <<>>;
sale_note_lines(#{status := sold, damage_text := DamageText}) ->
    [
        <<"\n✅ Sold • ">>, DamageText, <<" DAMAGE\n">>,
        <<"The Lightning checkout for this NFT is closed.\n">>
    ];
sale_note_lines(#{damage_text := DamageText}) ->
    [
        <<"\n💎 For sale: ">>, DamageText, <<" DAMAGE\n">>,
        <<"⚡ Lightning checkout available. A fresh spot-priced invoice is generated for each buyer.\n">>
    ].

build_release_card_svg(Mint, Sale) ->
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
    SaleBadge = release_card_sale_badge(Sale),
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
release_card_sale_badge(#{status := sold, damage_text := DamageText0}) ->
    DamageText = xml_escape(DamageText0),
    [
        <<"<rect x=\"82\" y=\"495\" width=\"650\" height=\"40\" rx=\"20\" fill=\"#000000\" opacity=\"0.18\"/>">>,
        <<"<text x=\"102\" y=\"521\" fill=\"#ffffff\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"17\" font-weight=\"700\">SOLD • ">>,
        DamageText, <<" DAMAGE</text>">>
    ];
release_card_sale_badge(#{damage_text := DamageText0}) ->
    DamageText = xml_escape(DamageText0),
    [
        <<"<rect x=\"82\" y=\"495\" width=\"650\" height=\"40\" rx=\"20\" fill=\"#000000\" opacity=\"0.18\"/>">>,
        <<"<text x=\"102\" y=\"521\" fill=\"#ffffff\" font-family=\"Inter,system-ui,sans-serif\" font-size=\"17\" font-weight=\"700\">ASK • ">>,
        DamageText, <<" DAMAGE • Lightning</text>">>
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

-ifdef(TEST).
invoice_status_test() ->
    ?assertEqual(paid, invoice_status(#{status => paid})),
    ?assertEqual(paid, invoice_status(#{<<"status">> => <<"complete">>})),
    ?assertEqual(unpaid, invoice_status(#{status => unpaid})),
    ?assertEqual(expired, invoice_status(#{status => <<"expired">>})).

invoice_sats_test() ->
    ?assertEqual({ok, 123}, invoice_sats(#{amount_msat => 123000})),
    ?assertEqual({ok, 123}, invoice_sats(#{<<"amount_msat">> => <<"123000msat">>})),
    ?assertEqual({ok, 123}, invoice_sats(#{amount_msat => #{msat => 123000}})).

replacement_delay_ms_test() ->
    ?assertEqual(1000, replacement_delay_ms(100, 100)),
    ?assertEqual(2000, replacement_delay_ms(100, 99)),
    ?assertEqual(0, replacement_delay_ms(100, 101)).

checkout_operation_lock_id_test() ->
    KeyA = {<<"ct_a">>, 1},
    KeyB = {<<"ct_a">>, 2},
    {{?MODULE, {checkout_operation, KeyA}}, Requester} = checkout_operation_lock_id(KeyA),
    ?assertEqual(self(), Requester),
    ?assertNotEqual(
        element(1, checkout_operation_lock_id(KeyA)),
        element(1, checkout_operation_lock_id(KeyB))
    ).

sold_badge_test() ->
    Badge = iolist_to_binary(release_card_sale_badge(#{status => sold, damage_text => <<"100">>})),
    ?assertMatch({_, _}, binary:match(Badge, <<"SOLD">>)),
    ?assertEqual(nomatch, binary:match(Badge, <<"ASK">>)).

sale_listing_is_replaceable_test() ->
    Mint = #{
        token_id => 42,
        contract_id => <<"ct_test">>,
        release => <<"v1.2.3">>,
        platform => <<"archlinux">>,
        git_sha => <<"deadbeef">>,
        metadata_cid => <<"QmMeta">>,
        asset_cid => <<"QmAsset">>
    },
    Image = #{
        url => <<"https://example.test/ipfs/QmImage">>,
        sha256 => <<"0123456789abcdef">>
    },
    Sale = #{damage_amount => 100.0, damage_text => <<"100">>},
    {30078, Content, Tags} = release_nostr_payload(Mint, Image, Sale),
    ?assertMatch({_, _}, binary:match(Content, <<"fresh spot-priced invoice">>)),
    ?assert(lists:member([<<"d">>, <<"build-release-nft:ct_test:42">>], Tags)),
    ?assertNot(lists:any(fun([<<"lightning">> | _]) -> true; (_) -> false end, Tags)),
    Sold = Sale#{status => sold},
    {30078, SoldContent, SoldTags} = release_nostr_payload(Mint, Image, Sold),
    ?assertMatch({_, _}, binary:match(SoldContent, <<"Sold">>)),
    ?assert(lists:member([<<"status">>, <<"sold">>], SoldTags)),
    ?assertNot(lists:member([<<"payment">>, <<"lightning">>], SoldTags)).
-endif.

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
resolve_contract(#{build_release_installation_expected := _} = Context) ->
    %% Installation builds must never disappear into an automatically deployed
    %% per-account NFT. Only the public reader's configured contract is valid.
    case installation_discovery_config(Context) of
        {ok, Config} -> {ok, maps:get(nft, Config)};
        {error, _} = Error -> Error
    end;
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

installation_discovery_config(Context) ->
    case damage_release_nft:discovery_config() of
        {ok, Config} ->
            Contract = maps:get(nft, Config),
            Override = map_get_any([build_release_nft_contract, <<"build_release_nft_contract">>,
                "build_release_nft_contract"], Context, Contract),
            case to_bin(Override) =:= Contract of
                true -> {ok, Config};
                false -> {error, build_release_discovery_contract_mismatch}
            end;
        {error, _} = Error -> Error
    end.

%% This reads the exact same resolver as /api/releases/latest?platform=... .
%% Failure never rolls back a successful mint and must never trigger reminting
%% into another registry. The read/assertion can safely be retried by itself.
verify_installable_mint(Context0) ->
    Context = maps:without([build_release_install_result, build_release_install_manifest], Context0),
    case {maps:find(build_release_mint_result, Context),
          maps:find(build_release_installation_expected, Context)} of
        {{ok, Mint}, {ok, Expected}} when is_map(Mint), is_map(Expected) ->
            case installation_discovery_config(Context) of
                {ok, Config} ->
                    Network = maps:get(network, Config),
                    case damage_release_nft:latest(maps:get(platform, Mint)) of
                        {ok, Discovered} ->
                            case damage_release_nft:verify_publication(
                                Mint#{network_id => Network}, Expected, Discovered) of
                                ok ->
                                    Context#{build_release_install_result => Discovered,
                                        build_release_install_manifest =>
                                            damage_release_nft:install_manifest(Discovered)};
                                {error, Why} -> fail(Context, Why)
                            end;
                        {error, Why} -> fail(Context, {release_discovery_verification_failed, Why})
                    end;
                {error, Why} -> fail(Context, {release_discovery_configuration_failed, Why})
            end;
        _ -> fail(Context, prepared_installation_and_mint_required)
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
