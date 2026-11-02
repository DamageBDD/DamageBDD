%% Incoming Lightning payments only. A browser or notification can request a
%% re-query but can never supply authoritative settlement data.
-module(ecai_personality_cln).
-export([ensure_invoice/1, lookup_invoice/1, ready/0, validate_config/1]).

%% Pure preflight: reject unusable frozen configuration before reserving an
%% edition. This does not claim the node is reachable or has inbound liquidity.
validate_config(Config) ->
    case safe(fun() -> identity(Config) end) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

ready() ->
    safe(fun() -> treasury(application:get_env(ecai, personality_lightning, #{})) end).

ensure_invoice(Order) ->
    safe(fun() ->
        Expected = expected(Order),
        Identity = treasury(maps:get(lightning_config, Order, #{})),
        case find_invoice(Expected) of
            absent ->
                %% The coordinator must persist Label BEFORE reaching here.
                %% CLN labels are unique, including after ambiguous RPC results.
                %% Never create an invoice with a replacement/random label.
                %% DamageBDD's cln:create_invoice/4 requires integer millisatoshis.
                _ = try damage_cln:create_invoice(
                    maps:get(amount_msat, Expected), <<"ECAI personality edition">>,
                    maps:get(expiry, Expected), maps:get(label, Expected))
                    catch _:_ -> uncertain end,
                case find_invoice(Expected) of
                    absent -> fail(invoice_creation_uncertain);
                    Invoice -> maps:merge(Invoice, Identity)
                end;
            Invoice -> maps:merge(Invoice, Identity)
        end
    end).

lookup_invoice(Order) ->
    safe(fun() ->
        Expected = expected(Order),
        Identity = treasury(maps:get(lightning_config, Order, #{})),
        case find_invoice(Expected) of
            absent -> fail(invoice_not_found);
            Invoice -> maps:merge(Invoice, Identity)
        end
    end).

expected(Order) ->
    Label = maps:get(label, Order, undefined),
    Price = maps:get(price_sats, Order, undefined),
    Expiry = maps:get(invoice_expiry_seconds, Order, 900),
    require(is_binary(Label) andalso byte_size(Label) > 0 andalso
            byte_size(Label) =< 128, invalid_invoice_label),
    require(is_integer(Price) andalso Price > 0 andalso
            Price =< 2100000000000000, invalid_invoice_amount),
    require(is_integer(Expiry) andalso Expiry >= 60 andalso
            Expiry =< 604800, invalid_invoice_expiry),
    #{label => Label, amount_msat => Price * 1000, expiry => Expiry,
      payment_hash => maps:get(payment_hash, Order, undefined),
      bolt11 => maps:get(bolt11, Order, undefined)}.

treasury(Config) ->
    Identity = identity(Config),
    Info = object(damage_cln:getinfo()),
    require(field(id, Info) =:= maps:get(treasury_node, Identity) andalso
            field(network, Info) =:= maps:get(network, Identity),
            treasury_identity_or_network_mismatch),
    Identity.

identity(Config) when is_map(Config) ->
    Node = maps:get(treasury_node, Config, undefined),
    Network = maps:get(network, Config, undefined),
    require(is_binary(Node) andalso byte_size(Node) =:= 66 andalso
            hex(Node), lightning_not_configured),
    require(lists:member(Network, [<<"bitcoin">>, <<"testnet">>, <<"regtest">>,
                                  <<"signet">>]), lightning_not_configured),
    require(is_boolean(maps:get(allow_mainnet, Config, false)),
            lightning_not_configured),
    require(Network =/= <<"bitcoin">> orelse
            maps:get(allow_mainnet, Config, false) =:= true,
            mainnet_not_authorized),
    #{treasury_node => Node, network => Network};
identity(_) -> fail(lightning_not_configured).

find_invoice(Expected) ->
    Label = maps:get(label, Expected),
    Reply = object(damage_cln:list_invoices_by_label(Label)),
    case field(invoices, Reply) of
        [] -> absent;
        [M] when is_map(M) -> normalize(M, Expected);
        L when is_list(L), length(L) > 1 -> fail(ambiguous_invoice);
        _ -> fail(invalid_cln_response)
    end.

normalize(M, Expected) ->
    Label = field(label, M),
    require(Label =:= maps:get(label, Expected), invoice_label_mismatch),
    Amount = msat(field(amount_msat, M)),
    require(Amount =:= maps:get(amount_msat, Expected), invoice_amount_mismatch),
    Hash = field(payment_hash, M),
    require(is_binary(Hash) andalso byte_size(Hash) =:= 64 andalso hex(Hash),
            invalid_cln_payment_hash),
    same_when_known(maps:get(payment_hash, Expected), Hash, invoice_hash_mismatch),
    Bolt11 = field(bolt11, M),
    require(is_binary(Bolt11) andalso byte_size(Bolt11) > 4 andalso
            byte_size(Bolt11) =< 8192 andalso is_invoice(Bolt11), invalid_cln_invoice),
    same_when_known(maps:get(bolt11, Expected), Bolt11, invoice_bolt11_mismatch),
    Status = case field(status, M) of
        <<"unpaid">> -> unpaid;
        <<"paid">> -> paid;
        <<"expired">> -> expired;
        _ -> fail(invalid_cln_invoice_status)
    end,
    Received = case {Status, field(amount_received_msat, M)} of
        {paid, V} -> msat(V);
        {_, undefined} -> 0;
        {_, V} -> msat(V)
    end,
    require(Status =/= paid orelse Received >= Amount, invoice_underpaid),
    Expires = field(expires_at, M),
    require(is_integer(Expires) andalso Expires > 0, invalid_cln_expiry),
    #{label => Label, bolt11 => Bolt11, payment_hash => Hash,
      amount_msat => Amount, amount_received_msat => Received,
      status => Status, expires_at => Expires}.

same_when_known(undefined, _, _) -> ok;
same_when_known(null, _, _) -> ok;
same_when_known(A, B, Error) -> require(A =:= B, Error).

is_invoice(<<"ln", Rest/binary>>) ->
    %% CLN owns BOLT11 decoding; constrain this output to its URI-safe alphabet.
    re:run(Rest, <<"^[a-z0-9]+$">>, [{capture, none}]) =:= match;
is_invoice(_) -> false.

hex(B) -> re:run(B, <<"^[0-9a-fA-F]+$">>, [{capture, none}]) =:= match.

field(K, M) -> maps:get(K, M, maps:get(atom_to_binary(K, utf8), M, undefined)).
object({ok, M}) when is_map(M) -> object(M);
object(M) when is_map(M) ->
    require(field(error, M) =:= undefined andalso field(code, M) =:= undefined,
            cln_rpc_error), M;
object(_) -> fail(cln_unavailable).

msat(N) when is_integer(N), N >= 0 -> N;
msat(#{msat := N}) -> msat(N);
msat(#{<<"msat">> := N}) -> msat(N);
msat(B) when is_binary(B), byte_size(B) =< 32 ->
    case re:run(B, <<"^([0-9]+)msat$">>, [{capture, [1], binary}]) of
        {match, [N]} -> binary_to_integer(N);
        _ -> fail(invalid_cln_msat)
    end;
msat(_) -> fail(invalid_cln_msat).

require(true, _) -> ok;
require(false, Error) -> fail(Error).
safe(F) ->
    try {ok, F()}
    catch throw:{personality_cln, Error} -> {error, Error};
          _:_ -> {error, cln_unavailable} end.
fail(Error) -> throw({personality_cln, Error}).
