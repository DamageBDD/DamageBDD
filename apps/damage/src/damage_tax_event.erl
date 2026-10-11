%%% Source-specific event normalisation. Tax class is NEVER inferred from flow direction.
-module(damage_tax_event).
-export([from_cln_invoice/2, from_cln_payment/2, from_chain/2, from_nwc/2,
         validate/1, get/3, to_binary/1, msat/1]).

-define(MSAT_PER_BTC, 100000000000).

-spec from_cln_invoice(binary(), map()) -> {ok, [map()]} | skip | {error, term()}.
from_cln_invoice(Tenant, Invoice) when is_map(Invoice) ->
    case to_binary(get(Invoice, status, undefined)) of
        <<"paid">> -> paid_invoice(Tenant, Invoice);
        _ -> skip
    end.

paid_invoice(Tenant, Raw) ->
    case {positive_msat(get(Raw, amount_received_msat, undefined)),
          positive_int(get(Raw, paid_at, undefined)),
          nonempty(get(Raw, payment_hash, undefined))} of
        {{ok, Amount}, {ok, At}, {ok, Hash}} ->
            LabelHash = damage_tax_canonical:commitment(get(Raw, label, <<>>)),
            Evidence = #{amount_received_msat => Amount, paid_at => At,
                         payment_hash => Hash, label_sha256 => LabelHash,
                         status => <<"paid">>},
            {ok, [make(Tenant, <<"cln_invoice">>, Hash, <<"receipt">>,
                       <<"in">>, At, <<"BTC">>, Amount, ?MSAT_PER_BTC,
                       Evidence, #{<<"payment_hash">> => Hash,
                                   <<"label_sha256">> => LabelHash})]};
        _ -> {error, {incomplete_paid_invoice, hash_hint(Raw)}}
    end.

-spec from_cln_payment(binary(), map()) -> {ok, [map()]} | skip | {error, term()}.
from_cln_payment(Tenant, Raw) when is_map(Raw) ->
    case to_binary(get(Raw, status, undefined)) of
        <<"complete">> -> complete_payment(Tenant, Raw);
        _ -> skip
    end.

complete_payment(Tenant, Raw) ->
    case {positive_msat(get(Raw, amount_msat, undefined)),
          positive_msat(get(Raw, amount_sent_msat, undefined)),
          positive_int(get(Raw, completed_at, undefined)),
          nonempty(get(Raw, payment_hash, undefined))} of
        {{ok, Principal}, {ok, Sent}, {ok, At}, {ok, Hash}} when Sent >= Principal ->
            Group = to_binary(get(Raw, groupid, <<"0">>)),
            %% groupid disambiguates retries; partid distinguishes MPP parts.
            %% Existing CLN listpays group-level rows normally omit partid.
            Part = to_binary(get(Raw, partid, <<>>)),
            Ref = case Part of
                <<>> -> <<Hash/binary, ":", Group/binary>>;
                _ -> <<Hash/binary, ":", Group/binary, ":", Part/binary>>
            end,
            Fees = Sent - Principal,
            Evidence = #{payment_hash => Hash, groupid => Group, partid => Part, at => At,
                         amount_msat => Principal, amount_sent_msat => Sent,
                         status => <<"complete">>},
            Payment = make(Tenant, <<"cln_payment">>, Ref, <<"payment">>,
                           <<"out">>, At, <<"BTC">>, Principal, ?MSAT_PER_BTC,
                           Evidence, #{<<"payment_hash">> => Hash,
                                       <<"groupid">> => Group}),
            FeeEvents = case Fees of
                0 -> [];
                _ -> [make(Tenant, <<"cln_payment">>, Ref, <<"routing_fee">>,
                           <<"out">>, At, <<"BTC">>, Fees, ?MSAT_PER_BTC,
                           Evidence, #{<<"payment_hash">> => Hash,
                                       <<"groupid">> => Group})]
            end,
            {ok, [Payment | FeeEvents]};
        _ -> {error, {incomplete_complete_payment, hash_hint(Raw)}}
    end.

%%% Caller supplies confirmed chain records with native asset scale and amount.
%%% Does not assume a chain transfer is taxable or that channel movements are disposals.
-spec from_chain(binary(), map()) -> {ok, [map()]} | {error, term()}.
from_chain(Tenant, Raw) ->
    case {nonempty(get(Raw, chain, undefined)),
          nonempty(get(Raw, tx_hash, undefined)),
          positive_int(get(Raw, confirmed_at, undefined)),
          nonempty(get(Raw, asset, undefined)),
          positive_int(get(Raw, amount_atomic, undefined)),
          positive_int(get(Raw, scale, undefined)),
          direction(get(Raw, direction, undefined)),
          nonempty(get(Raw, block_hash, undefined)),
          positive_int(get(Raw, block_height, undefined)),
          positive_int(get(Raw, confirmations, undefined))} of
        {{ok, Chain}, {ok, TxId}, {ok, At}, {ok, Asset},
         {ok, Amount}, {ok, Scale}, {ok, Dir},
         {ok, BlockHash}, {ok, Height}, {ok, Confirmations}} ->
            TransferIndex = to_binary(get(Raw, transfer_index, <<"0">>)),
            Ref = <<TxId/binary, ":", TransferIndex/binary>>,
            Evidence = #{chain => Chain, tx_hash => TxId, confirmed_at => At,
                         amount_atomic => Amount, scale => Scale, asset => Asset,
                         direction => Dir, transfer_index => TransferIndex,
                         block_hash => BlockHash, block_height => Height,
                         confirmations => Confirmations},
            {ok, [make(Tenant, <<"chain:", Chain/binary>>, Ref, <<"transfer">>,
                       Dir, At, Asset, Amount, Scale, Evidence,
                       #{<<"tx_hash">> => TxId, <<"chain">> => Chain,
                         <<"block_hash">> => BlockHash,
                         <<"block_height">> => Height,
                         <<"confirmations">> => Confirmations})]};
        _ -> {error, incomplete_chain_event}
    end.

%%% NWC ledger entry is an allocation, *not* a second Bitcoin receipt/payment.
-spec from_nwc(binary(), map()) -> {ok, [map()]} | {error, term()}.
from_nwc(Tenant, Raw) ->
    case {nonempty(get(Raw, ledger_ct, undefined)),
          nonempty(get(Raw, ref, undefined)),
          positive_int(get(Raw, at, undefined)),
          positive_msat(get(Raw, amount_msat, undefined)),
          direction(get(Raw, direction, undefined))} of
        {{ok, Ledger}, {ok, Ref}, {ok, At}, {ok, Amount}, {ok, Dir}} ->
            Evidence = #{ledger_ct => Ledger, ref => Ref, at => At,
                         amount_msat => Amount, direction => Dir},
            Event = make(Tenant, <<"nwc_allocation">>,
                         <<Ledger/binary, ":", Ref/binary>>,
                         <<"allocation">>, Dir, At, <<"BTC">>, Amount,
                         ?MSAT_PER_BTC, Evidence,
                         #{<<"ledger_ct">> => Ledger, <<"ref">> => Ref}),
            {ok, [Event#{<<"default_classification">> => <<"non_tax_event">>}]};
        _ -> {error, incomplete_nwc_allocation}
    end.

make(Tenant0, Source, Ref, Kind, Dir, At, Asset, Amount, Scale, Evidence, Meta) ->
    Tenant = to_binary(Tenant0),
    Key = [<<"damage_tax_event_v1:">>, Tenant, <<":">>, Source, <<":">>,
           Ref, <<":">>, Kind],
    #{<<"id">> => damage_tax_canonical:sha256_hex(Key),
      <<"schema_version">> => 1,
      <<"tenant">> => Tenant,
      <<"source">> => Source,
      <<"source_ref">> => Ref,
      <<"kind">> => Kind,
      <<"direction">> => Dir,
      <<"occurred_at">> => At,
      <<"asset">> => Asset,
      <<"amount_atomic">> => Amount,
      <<"scale">> => Scale,
      <<"source_sha256">> => damage_tax_canonical:commitment(Evidence),
      <<"metadata">> => Meta,
      <<"default_classification">> => <<"review">>}.

-spec validate(map()) -> ok | {error, term()}.
validate(#{<<"id">> := Id, <<"tenant">> := Tenant,
           <<"occurred_at">> := Ts, <<"asset">> := Asset,
           <<"amount_atomic">> := Amount, <<"scale">> := Scale,
           <<"source_sha256">> := EvidenceHash} = E) when
        is_binary(Id), byte_size(Id) =:= 64,
        is_binary(Tenant), byte_size(Tenant) > 0,
        is_integer(Ts), Ts > 0, is_binary(Asset), byte_size(Asset) > 0,
        is_integer(Amount), Amount > 0,
        is_integer(Scale), Scale > 0,
        is_binary(EvidenceHash), byte_size(EvidenceHash) =:= 64 ->
    case lists:member(maps:get(<<"direction">>, E, undefined), [<<"in">>, <<"out">>]) of
        true -> ok;
        false -> {error, invalid_direction}
    end;
validate(_) -> {error, invalid_tax_event}.

get(Map, K, Default) when is_atom(K), is_map(Map) ->
    maps:get(K, Map, maps:get(atom_to_binary(K, utf8), Map, Default)).

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V);
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(undefined) -> <<>>;
to_binary(null) -> <<>>;
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(_) -> <<>>.

msat(V) -> positive_msat(V).
positive_msat(N) ->
    case N of
        I when is_integer(I), I > 0 -> {ok, I};
        Bin when is_binary(Bin) -> parse_amount(Bin);
        Str when is_list(Str) -> parse_amount(unicode:characters_to_binary(Str));
        _ -> error
    end.

parse_amount(<<>>) -> error;
parse_amount(Bin) ->
    B = case binary:match(Bin, <<"msat">>) of
        {Pos, 4} when Pos =:= byte_size(Bin)-4 -> binary:part(Bin, 0, Pos);
        _ -> Bin
    end,
    positive_int(B).

positive_int(N) when is_integer(N), N > 0 -> {ok, N};
positive_int(N) when is_binary(N) ->
    try
        Int = binary_to_integer(N),
        positive_int(Int)
    catch _:_ -> error end;
positive_int(N) when is_list(N) -> positive_int(to_binary(N));
positive_int(_) -> error.

nonempty(V) ->
    B = to_binary(V),
    case B of <<>> -> error; _ -> {ok, B} end.

direction(V) ->
    case to_binary(V) of
        <<"in">> -> {ok, <<"in">>};
        <<"out">> -> {ok, <<"out">>};
        _ -> error
    end.

hash_hint(Raw) ->
    %% No full invoice/payment payload or preimage in errors/logs.
    damage_tax_canonical:commitment(#{payment_hash => get(Raw, payment_hash, <<>>)}).
