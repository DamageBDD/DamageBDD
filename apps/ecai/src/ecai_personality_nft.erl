%%% AEX-141 adapter for receipts issued after server-verified Lightning settlement.
%%% Submission is NEVER fulfillment: only a matching canonical-chain receipt with
%%% the configured number of key-block confirmations returns {ok, Receipt}.
-module(ecai_personality_nft).
-export([ready/1, mint/1, lookup/1, validate_recipient/1, validate_config/1,
         contract_path/0, deploy/0, register_product/1,
         collection_key/1, order_commitment/1]).

-define(PROTOCOL, <<"ecai-personality-nft/1">>).

contract_path() -> damage_ae:contract_path(ecai, "ecai_personality_nft.aes").

%% Operator-only helpers; no private key leaves the existing secrets provider.
deploy() ->
    guarded(fun() ->
        KeyPair = signer(),
        damage_ae:contract_deploy(contract_path(),
            [<<"ECAI Personalities">>, <<"ECP">>, signer_account(KeyPair)])
    end).

register_product(Product) ->
    guarded(fun() ->
        Config = current_config(),
        Ct = configured_contract(Config, false),
        ensure_network(Config),
        KeyPair = signer(),
        valid_product(Product),
        Args = [collection_key(Product), hash32(maps:get(package_sha256, Product)),
                binary_value(maps:get(manifest_uri, Product)), maps:get(edition_limit, Product)],
        %% Submission deliberately returns pending even when a transaction hash exists.
        Result = damage_ae:contract_call(KeyPair, Ct, contract_path(),
                                        "register_collection", Args),
        submission_result(Result, Ct)
    end).

ready(Product) ->
    guarded(fun() ->
        Config = case maps:is_key(nft_config, Product) of
            true -> frozen_config(Product);
            false -> current_config()
        end,
        Ct = configured_contract(Config, true),
        ensure_network(Config),
        valid_product(Product),
        ensure_signer(Ct, signer()),
        case read(Ct, "collection_info", [collection_key(Product)]) of
            {some, Value} ->
                case tuple_value(Value) of
                    {Hash, URI, Limit, Issued}
                      when is_integer(Limit), is_integer(Issued), Issued >= 0 ->
                        require(hash_value(Hash) =:= hash32(maps:get(package_sha256, Product)),
                                collection_binding_conflict),
                        require(binary_value(URI) =:= binary_value(maps:get(manifest_uri, Product)),
                                collection_binding_conflict),
                        require(Limit =:= maps:get(edition_limit, Product), collection_binding_conflict),
                        require(Issued < Limit, sold_out),
                        ok;
                    _ -> fail(invalid_chain_response)
                end;
            none -> fail(collection_not_registered);
            _ -> fail(invalid_chain_response)
        end
    end).

mint(Order) ->
    guarded(fun() ->
        require(lists:member(maps:get(status, Order), [paid, mint_pending]), payment_not_verified),
        %% Read first: a previous attempt may have reached the chain before a crash.
        case lookup(Order) of
            {ok, not_found} -> submit_mint(Order);
            Result -> Result
        end
    end).

lookup(Order) ->
    guarded(fun() ->
        Config = frozen_config(Order),
        Ct = configured_contract(Config, true),
        ensure_network(Config),
        valid_order(Order),
        require(binary_value(read(Ct, "protocol_version", [])) =:= ?PROTOCOL,
                incompatible_contract),
        case read(Ct, "receipt_for_order", [order_commitment(Order)]) of
            none -> {ok, not_found};
            {some, Value} -> verify_receipt(tuple_value(Value), Order, Ct, Config);
            _ -> fail(invalid_chain_response)
        end
    end).

submit_mint(Order) ->
    Config = frozen_config(Order),
    Ct = configured_contract(Config, true),
    ensure_network(Config),
    KeyPair = signer(),
    ensure_signer(Ct, KeyPair),
    Args = [order_commitment(Order), collection_key(Order),
            binary_value(maps:get(recipient, Order)), hash32(maps:get(payment_hash, Order)),
            maps:get(price_sats, Order), {none}],
    %% Even a timeout is ambiguous: the node may have accepted the transaction.
    %% Durable order recovery queries the receipt before resubmitting the same key.
    Result = try damage_ae:contract_call(KeyPair, Ct, contract_path(), "mint_paid", Args)
             catch _:_ -> ambiguous end,
    case lookup(Order) of
        {ok, Receipt} when is_map(Receipt) -> {ok, merge_tx(Receipt, Result)};
        {pending, Receipt} -> {pending, merge_tx(Receipt, Result)};
        {ok, not_found} -> submission_result(Result, Ct);
        {error, _} -> {pending, merge_tx(#{contract_id => Ct, status => awaiting_chain_receipt}, Result)}
    end.

verify_receipt({TokenId, Key, Recipient, Hash, URI, Limit, PaymentHash,
                Price, MintedHeight, CurrentHeight}, Order, Ct, Config)
  when is_integer(TokenId), TokenId > 0, is_integer(Limit),
       is_integer(Price), is_integer(MintedHeight), MintedHeight >= 0,
       is_integer(CurrentHeight), CurrentHeight >= MintedHeight ->
    require(hash_value(Key) =:= collection_key(Order), receipt_binding_conflict),
    require(address_value(Recipient) =:= address_value(maps:get(recipient, Order)), receipt_binding_conflict),
    require(hash_value(Hash) =:= hash32(maps:get(package_sha256, Order)), receipt_binding_conflict),
    require(binary_value(URI) =:= binary_value(maps:get(manifest_uri, Order)), receipt_binding_conflict),
    require(Limit =:= maps:get(edition_limit, Order), receipt_binding_conflict),
    require(hash_value(PaymentHash) =:= hash32(maps:get(payment_hash, Order)), receipt_binding_conflict),
    require(Price =:= maps:get(price_sats, Order), receipt_binding_conflict),
    Required = maps:get(confirmations, Config, 3),
    require(is_integer(Required) andalso Required >= 1 andalso Required =< 100,
            invalid_confirmation_policy),
    Confirmations = CurrentHeight - MintedHeight + 1,
    Receipt = #{contract_id => Ct, token_id => TokenId,
                recipient => binary_value(maps:get(recipient, Order)),
                confirmations => Confirmations, required_confirmations => Required,
                minted_height => MintedHeight},
    case Confirmations >= Required of
        true -> {ok, Receipt};
        false -> {pending, Receipt#{status => awaiting_confirmations}}
    end;
verify_receipt(_, _, _, _) -> fail(invalid_chain_response).

ensure_signer(Ct, KeyPair) ->
    require(binary_value(read(Ct, "protocol_version", [])) =:= ?PROTOCOL, incompatible_contract),
    require(address_value(read(Ct, "minter", [])) =:= address_value(signer_account(KeyPair)),
            signer_is_not_minter).

current_config() ->
    case application:get_env(ecai, personality_nft, #{}) of
        Config when is_map(Config) -> Config;
        _ -> fail(invalid_nft_config)
    end.

frozen_config(Order) ->
    case maps:get(nft_config, Order, undefined) of
        Config when is_map(Config) -> Config;
        _ -> fail(missing_order_chain_snapshot)
    end.

validate_config(Config) ->
    guarded(fun() -> configured_contract(Config, true), ok end).

ensure_network(Config) ->
    require(binary_value(vanillae:network_id()) =:= binary_value(maps:get(network_id, Config)),
            network_mismatch).

configured_contract(Config, RequireEnabled) ->
    require((not RequireEnabled) orelse maps:get(enabled, Config, false) =:= true, nft_disabled),
    Network = binary_value(maps:get(network_id, Config, <<>>)),
    require(byte_size(Network) > 0 andalso byte_size(Network) =< 100, invalid_network_id),
    Confirmations = maps:get(confirmations, Config, 3),
    require(is_integer(Confirmations) andalso Confirmations >= 1 andalso Confirmations =< 100,
            invalid_confirmation_policy),
    Ct = binary_value(maps:get(contract_id, Config, <<>>)),
    case aeser_api_encoder:safe_decode(contract_pubkey, Ct) of
        {ok, Raw} when byte_size(Raw) =:= 32 -> Ct;
        _ -> fail(invalid_contract_id)
    end.

signer() ->
    case secrets:node_keypair() of
        #{public_key := _, private_key := _} = KeyPair -> KeyPair;
        _ -> fail(signer_unavailable)
    end.

signer_account(#{public_key := Public}) ->
    case Public of
        <<_:256>> -> aeser_api_encoder:encode(account_pubkey, Public);
        _ -> binary_value(Public)
    end.

validate_recipient(Recipient) ->
    try
        case aeser_api_encoder:safe_decode(account_pubkey, binary_value(Recipient)) of
            {ok, Raw} when byte_size(Raw) =:= 32 -> ok;
            _ -> {error, invalid_recipient}
        end
    catch _:_ -> {error, invalid_recipient} end.

valid_product(Product) ->
    Id = personality_id(Product),
    require(byte_size(Id) > 0 andalso byte_size(Id) =< 200, invalid_personality_id),
    hash32(maps:get(package_sha256, Product)),
    URI = binary_value(maps:get(manifest_uri, Product)),
    require(byte_size(URI) > 0 andalso byte_size(URI) =< 2048, invalid_manifest_uri),
    Limit = maps:get(edition_limit, Product),
    require(is_integer(Limit) andalso Limit > 0, invalid_edition_limit),
    Price = maps:get(price_sats, Product),
    require(is_integer(Price) andalso Price > 0, invalid_price),
    ok.

valid_order(Order) ->
    valid_product(Order),
    require(validate_recipient(maps:get(recipient, Order)) =:= ok, invalid_recipient),
    hash32(maps:get(payment_hash, Order)),
    order_commitment(Order),
    ok.

personality_id(#{personality_id := Id}) -> binary_value(Id);
personality_id(#{id := Id}) -> binary_value(Id).

%% Length-prefixing prevents ambiguous concatenations. Neither owner nor opaque
%% order ID is published on chain: only this one-way commitment is published.
order_commitment(Order) ->
    Id = binary_value(maps:get(id, Order)),
    Owner = binary_value(maps:get(owner, Order)),
    require(byte_size(Id) > 0 andalso byte_size(Owner) > 0, invalid_order_identity),
    crypto:hash(sha256, [<<"ecai:personality:order:v1">>, framed(Owner), framed(Id)]).

collection_key(Product) ->
    crypto:hash(sha256, [<<"ecai:personality:collection:v1">>, framed(personality_id(Product)),
                         hash32(maps:get(package_sha256, Product))]).

framed(Bin) -> <<(byte_size(Bin)):32/unsigned-big, Bin/binary>>.

%% All reads below are top-pinned dry-runs, never the decoded return value of
%% the submission transaction. contract_query is intentionally avoided: some
%% releases fall back to paid on-chain calls when dry-run is unavailable.
read(Ct, Function, Args) ->
    normalize_read(damage_ae:contract_call_dry(signer(), Ct, contract_path(), Function, Args)).

normalize_read({ok, Value}) -> normalize_read(Value);
normalize_read({error, _}) -> fail(chain_read_failed);
normalize_read(#{"return_type" := "ok", "return_value" := Value}) -> normalize_read(Value);
normalize_read(#{<<"return_type">> := <<"ok">>, <<"return_value">> := Value}) -> normalize_read(Value);
normalize_read(#{return_type := ok, return_value := Value}) -> normalize_read(Value);
normalize_read(#{"return_type" := _}) -> fail(chain_read_reverted);
normalize_read(#{<<"return_type">> := _}) -> fail(chain_read_reverted);
normalize_read(#{return_type := _}) -> fail(chain_read_reverted);
normalize_read({variant, [0, 1], 0, {}}) -> none;
normalize_read({variant, [0, 1], 1, {Value}}) -> {some, Value};
normalize_read(#{decoded_result := Value}) -> normalize_read(Value);
normalize_read(#{<<"decoded_result">> := Value}) -> normalize_read(Value);
normalize_read(#{decodedResult := Value}) -> normalize_read(Value);
normalize_read(#{<<"decodedResult">> := Value}) -> normalize_read(Value);
normalize_read({some, Value}) -> {some, Value};
normalize_read({'Some', Value}) -> {some, Value};
normalize_read(#{<<"Some">> := [Value]}) -> {some, Value};
normalize_read({none}) -> none;
normalize_read(none) -> none;
normalize_read('None') -> none;
normalize_read(#{<<"None">> := []}) -> none;
normalize_read(Value) -> Value.

tuple_value({tuple, Value}) -> tuple_value(Value);
tuple_value(Value) when is_tuple(Value) -> Value;
tuple_value(Value) when is_list(Value) -> list_to_tuple(Value);
tuple_value(_) -> fail(invalid_chain_response).

hash_value({bytes, Bin}) when is_binary(Bin), byte_size(Bin) =:= 32 -> Bin;
hash_value(<<_:256>> = Bin) -> Bin;
hash_value(<<"#", Hex/binary>>) -> hash32(Hex);
hash_value(<<"0x", Hex/binary>>) -> hash32(Hex);
hash_value(Value) -> hash32(Value).

hash32(Value) ->
    Hex = binary_value(Value),
    require(byte_size(Hex) =:= 64, invalid_hash),
    try binary:decode_hex(Hex)
    catch _:_ -> fail(invalid_hash) end.

address_value({address, <<_:256>> = Bin}) -> Bin;
address_value(<<_:256>> = Bin) -> Bin;
address_value(Value) ->
    case aeser_api_encoder:safe_decode(account_pubkey, binary_value(Value)) of
        {ok, <<_:256>> = Bin} -> Bin;
        _ -> fail(invalid_chain_address)
    end.

binary_value(Value) when is_binary(Value) -> Value;
binary_value(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
binary_value(_) -> fail(invalid_value).

submission_result(Result, Ct) ->
    {pending, merge_tx(#{contract_id => Ct, status => awaiting_chain_receipt}, Result)}.

merge_tx(Map, Result) ->
    case tx_hash(Result) of
        undefined -> Map;
        Hash -> Map#{tx_hash => Hash}
    end.

tx_hash({ok, Value}) -> tx_hash(Value);
tx_hash(Map) when is_map(Map) ->
    Value = maps:get(tx_hash, Map, maps:get(<<"tx_hash">>, Map, maps:get("tx_hash", Map, undefined))),
    case Value of
        <<"th_", _/binary>> -> Value;
        _ -> undefined
    end;
tx_hash(_) -> undefined.

require(true, _) -> ok;
require(false, Reason) -> fail(Reason).
fail(Reason) -> throw({personality_nft, Reason}).

guarded(Fun) ->
    try Fun()
    catch
        throw:{personality_nft, Reason} -> {error, Reason};
        error:undef -> {error, chain_dependency_unavailable};
        error:{badkey, _} -> {error, incomplete_order_or_product};
        _:_ -> {error, chain_unavailable}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

commitment_domain_test() ->
    A = #{id => <<"bc">>, owner => <<"a">>},
    B = #{id => <<"c">>, owner => <<"ab">>},
    ?assertNotEqual(order_commitment(A), order_commitment(B)),
    ?assertEqual(order_commitment(A), order_commitment(A)).

collection_version_test() ->
    P = #{id => <<"builder">>, package_sha256 => binary:encode_hex(<<1:256>>)},
    ?assertNotEqual(collection_key(P), collection_key(P#{package_sha256 => binary:encode_hex(<<2:256>>)})),
    ?assertEqual(collection_key(P), collection_key(P#{personality_id => <<"builder">>, id => <<"order">>})).

submission_never_confirms_test() ->
    ?assertMatch({pending, _}, submission_result({ok, #{token_id => 1, tx_hash => <<"th_test">>}}, <<"ct_test">>)),
    ?assertMatch({pending, _}, submission_result({error, timeout}, <<"ct_test">>)).

receipt_verification_test() ->
    Order = #{id => <<"order">>, owner => <<"owner">>, personality_id => <<"builder">>,
              package_sha256 => binary:encode_hex(<<1:256>>), manifest_uri => <<"ipfs://manifest">>,
              edition_limit => 10, payment_hash => binary:encode_hex(<<2:256>>),
              price_sats => 1000, recipient => <<3:256>>},
    R = {1, collection_key(Order), <<3:256>>, <<1:256>>, <<"ipfs://manifest">>, 10, <<2:256>>, 1000, 10, 10},
    ?assertMatch({pending, _}, verify_receipt(R, Order, <<"ct_test">>, #{confirmations => 3})),
    ?assertMatch({ok, _}, verify_receipt(setelement(10, R, 12), Order, <<"ct_test">>, #{confirmations => 3})),
    ?assertThrow({personality_nft, receipt_binding_conflict},
                 verify_receipt(setelement(7, R, <<4:256>>), Order, <<"ct_test">>, #{})),
    ?assertThrow({personality_nft, receipt_binding_conflict},
                 verify_receipt(setelement(3, R, <<4:256>>), Order, <<"ct_test">>, #{})),
    ?assertThrow({personality_nft, receipt_binding_conflict},
                 verify_receipt(setelement(8, R, 999), Order, <<"ct_test">>, #{})).

fate_dry_run_decode_test() ->
    ?assertEqual(none, normalize_read(#{"return_type" => "ok", "return_value" => {variant, [0, 1], 0, {}}})),
    ?assertEqual({some, {tuple, {42}}}, normalize_read(#{"return_type" => "ok", "return_value" => {variant, [0, 1], 1, {{tuple, {42}}}}})),
    ?assertEqual({42}, tuple_value({tuple, {42}})),
    ?assertThrow({personality_nft, chain_read_reverted}, normalize_read(#{"return_type" => "revert", "return_value" => <<"error">>})).

frozen_target_test() ->
    application:set_env(ecai, personality_nft, #{contract_id => <<"ct_new">>}),
    try
        ?assertEqual(#{contract_id => <<"ct_old">>},
                     frozen_config(#{nft_config => #{contract_id => <<"ct_old">>}})),
        ?assertThrow({personality_nft, missing_order_chain_snapshot}, frozen_config(#{}))
    after application:unset_env(ecai, personality_nft) end.
-endif.
