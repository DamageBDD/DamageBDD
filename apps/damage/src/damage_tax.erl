%%% Small orchestration API. The journal is intentionally distinct from NWC balances.
-module(damage_tax).
-export([start_link/1, ingest_cln/1, import_chain/2, import_nwc/2,
         fetch_and_archive_quote/3, fetch_and_archive_quote/4, records/1]).

start_link(JournalPath) -> damage_tax_store:start_link(JournalPath).

-spec ingest_cln(binary()) -> {ok, non_neg_integer()} | {error, term()}.
ingest_cln(Tenant) ->
    %% A CLN node can contain payments for multiple businesses. Do not
    %% attribute global node history to an arbitrary caller/wallet account.
    %% This is an operator-only internal API with explicit ownership binding.
    case application:get_env(damage, tax_cln_owner, undefined) of
        Tenant when is_binary(Tenant), byte_size(Tenant) > 0 ->
            case damage_tax_cln:collect(Tenant) of
                {ok, Items} -> append_witnesses(Items, 0);
                Error -> Error
            end;
        _ -> {error, tax_cln_owner_not_configured_or_mismatched}
    end.

-spec import_chain(binary(), map()) -> {ok, non_neg_integer()} | {error, term()}.
import_chain(Tenant, ChainEvent) ->
    Witness = selected_evidence(ChainEvent, [chain, tx_hash, confirmed_at,
        asset, amount_atomic, scale, direction, transfer_index,
        block_hash, block_height, confirmations]),
    import_event(damage_tax_event:from_chain(Tenant, ChainEvent), Witness).

-spec import_nwc(binary(), map()) -> {ok, non_neg_integer()} | {error, term()}.
import_nwc(Tenant, LedgerEvent) ->
    Witness = selected_evidence(LedgerEvent, [ledger_ct, ref, at, amount_msat,
        direction, tx_hash, block_height, meta_sha256]),
    import_event(damage_tax_event:from_nwc(Tenant, LedgerEvent), Witness).

import_event({ok, Events}, Source) when is_map(Source) ->
    %% Source is a strict allowlist of tax-relevant metadata. Never archive
    %% arbitrary private keys, tokens, payment preimages or RPC credentials.
    Witness = damage_tax_canonical:encode(Source),
    append_witnesses([{E, Witness} || E <- Events], 0);
import_event(Error, _) -> Error.

append_witnesses([], N) -> {ok, N};
append_witnesses([{Event, Witness} | Rest], N) ->
    SHA = damage_tax_canonical:sha256_hex(Witness),
    case damage_tax_store:archive_evidence(Witness) of
        {ok, SHA} ->
            case damage_tax_store:append(Event#{<<"snapshot_sha256">> => SHA}) of
                {ok, duplicate} -> append_witnesses(Rest, N);
                {ok, _Digest} -> append_witnesses(Rest, N + 1);
                AppendError -> AppendError
            end;
        ArchiveError -> ArchiveError
    end.

-spec fetch_and_archive_quote(cryptocompare | coingecko, binary(), integer()) ->
    {ok, map()} | {error, term()}.
fetch_and_archive_quote(Provider, Asset, Ts) ->
    fetch_and_archive_quote(Provider, Asset, Ts, <<"AUD">>).

fetch_and_archive_quote(Provider, Asset, Ts, Currency) ->
    case damage_tax_prices:fetch(Provider, Asset, Ts, Currency) of
        {ok, #{quote := Quote, evidence_body := Body}} ->
            SHA = maps:get(<<"body_sha256">>, Quote),
            case damage_tax_store:archive_evidence(Body) of
                {ok, SHA} -> {ok, Quote#{<<"archive_sha256">> => SHA}};
                ArchiveError -> ArchiveError
            end;
        FetchError -> FetchError
    end.

records(Tenant) ->
    case damage_tax_store:entries() of
        {ok, Entries} ->
            {ok, [E || #{<<"event">> := E} <- Entries,
                       maps:get(<<"tenant">>, E) =:= Tenant]};
        Error -> Error
    end.

selected_evidence(Raw, Keys) ->
    maps:from_list([{atom_to_binary(K, utf8), scalar(V)} ||
        K <- Keys,
        V <- [damage_tax_event:get(Raw, K, undefined)],
        V =/= undefined]).

scalar(V) when is_binary(V); is_integer(V); is_boolean(V) -> V;
scalar(V) when is_atom(V) -> atom_to_binary(V, utf8);
scalar(V) when is_list(V) -> unicode:characters_to_binary(V);
scalar(_) -> <<"redacted_non_scalar">>.
