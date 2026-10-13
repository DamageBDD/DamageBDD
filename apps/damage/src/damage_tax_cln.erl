%%% CLN read-only historical importer via the existing fault-contained facade.
%%% Never treats generated invoices as revenue; only settled invoices count.
%%% Does not store BOLT11, preimages, payment secrets, or raw auth material.
-module(damage_tax_cln).
-export([collect/1, collect_from/3]).

-spec collect(binary()) -> {ok, [{map(), binary()}]} | {error, term()}.
collect(Tenant) ->
    case damage_cln:list_all_invoices(#{page_limit => 200, order => asc}) of
        {error, InvoiceReason} ->
            {error, {cln_invoice_listing_failed, InvoiceReason}};
        InvoiceResponse ->
            case extract(invoices, InvoiceResponse) of
                {ok, Invoices} ->
                    case damage_cln:list_pays() of
                        {error, PaymentReason} ->
                            {error, {cln_payment_listing_failed, PaymentReason}};
                        PayResponse ->
                            case extract(pays, PayResponse) of
                                {ok, Pays} -> collect_from(Tenant, Invoices, Pays);
                                PayParseError -> PayParseError
                            end
                    end;
                InvoiceParseError ->
                    InvoiceParseError
            end
    end.

extract(_Name, {ok, Items}) when is_list(Items) -> {ok, Items};
extract(Name, {ok, Map}) when is_map(Map) -> extract(Name, Map);
extract(Name, Map) when is_map(Map) ->
    Items = damage_tax_event:get(Map, Name, undefined),
    case Items of
        L when is_list(L) -> {ok, L};
        _ -> {error, {cln_invalid_list_response, Name}}
    end;
extract(Name, _) ->
    {error, {cln_invalid_list_response, Name}}.

-spec collect_from(binary(), [map()], [map()]) ->
    {ok, [{map(), binary()}]} | {error, term()}.
collect_from(Tenant, Invoices, Pays) when is_list(Invoices), is_list(Pays) ->
    case fold_source(Tenant, invoices, Invoices, []) of
        {ok, In} ->
            case fold_source(Tenant, pays, Pays, In) of
                {ok, All} -> {ok, lists:reverse(All)};
                PaymentFoldError -> PaymentFoldError
            end;
        InvoiceFoldError ->
            InvoiceFoldError
    end;
collect_from(_, _, _) ->
    {error, invalid_cln_input}.

fold_source(_, _, [], Acc) ->
    {ok, Acc};
fold_source(Tenant, Source, [Raw | Rest], Acc) when is_map(Raw) ->
    Result =
        case Source of
            invoices -> damage_tax_event:from_cln_invoice(Tenant, Raw);
            pays -> damage_tax_event:from_cln_payment(Tenant, Raw)
        end,
    case Result of
        skip ->
            fold_source(Tenant, Source, Rest, Acc);
        {ok, Events} ->
            SafeRaw = safe_witness(Source, Raw),
            Witness = damage_tax_canonical:encode(SafeRaw),
            Snapshot = damage_tax_canonical:sha256_hex(Witness),
            WithSnapshot = [{E#{<<"snapshot_sha256">> => Snapshot}, Witness} || E <- Events],
            fold_source(Tenant, Source, Rest, lists:reverse(WithSnapshot, Acc));
        Error ->
            Error
    end;
fold_source(_, _, _, _) ->
    {error, invalid_cln_row}.

safe_witness(invoices, Raw) ->
    snapshot_fields(Raw, [
        status,
        payment_hash,
        label,
        amount_msat,
        amount_received_msat,
        paid_at,
        created_at,
        created_index,
        pay_index
    ]);
safe_witness(pays, Raw) ->
    snapshot_fields(Raw, [
        status,
        payment_hash,
        amount_msat,
        amount_sent_msat,
        created_at,
        completed_at,
        groupid,
        partid,
        destination
    ]).

snapshot_fields(Map, Keys) ->
    maps:from_list([
        {atom_to_binary(K, utf8), clean(V)}
     || K <- Keys,
        V <- [damage_tax_event:get(Map, K, undefined)],
        V =/= undefined
    ]).

clean(V) when is_integer(V); is_binary(V); is_boolean(V) -> V;
clean(V) when is_atom(V) -> atom_to_binary(V, utf8);
clean(V) when is_list(V) -> unicode:characters_to_binary(V);
clean(_) -> <<"redacted_non_scalar">>.
