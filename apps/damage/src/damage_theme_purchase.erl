%%% Theme purchase orchestration. CLN is the sole source of Lightning payment
%%% truth; only confirmed AEX-141 ownership is a successful purchase.
-module(damage_theme_purchase).
-export([new_sats/2, order_status/2, settle_order/2, buy_damage/2, verify_invoice/2]).

new_sats(Account, Key) when is_binary(Account), is_binary(Key) ->
    case priced(Key, <<"price_sats">>) of
        {ok, Theme, Sats} ->
            case damage_theme_store:active_order_count(Account) of
                Count when is_integer(Count), Count < 5 ->
                    create_sats_invoice(Account, Key, Theme, Sats);
                _ -> {error, too_many_pending_invoices}
            end;
        Error -> Error
    end;
new_sats(_, _) -> {error, invalid_purchase}.

create_sats_invoice(Account, Key, Theme, Sats) ->
            Id = hex(crypto:strong_rand_bytes(16)),
            Label = <<"theme:", Id/binary>>,
            Description = <<"DamageBDD theme ", Key/binary>>,
            case safely(fun() -> damage_cln:create_invoice(Sats * 1000, Description, 3600, Label) end) of
                #{bolt11 := Bolt11, payment_hash := Hash} ->
                    %% Store immutable purchase facts, including the expected
                    %% hash: never accept client-provided paid flags or preimages.
                    Order = #{<<"order_id">> => Id, <<"account">> => Account,
                        <<"theme_key">> => Key, <<"amount_msat">> => Sats * 1000,
                        <<"label">> => Label, <<"payment_hash">> => Hash,
                        <<"invoice">> => Bolt11, <<"status">> => <<"unpaid">>,
                        <<"expires_at">> => erlang:system_time(second) + 3600,
                        <<"theme_cid">> => maps:get(<<"cid">>, Theme)},
                    case damage_theme_store:put_order(Order) of
                        ok -> {ok, public_order(Order)};
                        Error -> Error
                    end;
                _ -> {error, lightning_invoice_unavailable}
            end.

%% Safe GET: read an order without triggering payment settlement or minting.
order_status(Account, Id) ->
    case damage_theme_store:order(Id) of
        {ok, #{<<"account">> := Account} = Order} ->
            case maps:get(<<"status">>, Order) of
                <<"minted">> ->
                    %% NFT transfers revoke installation rights; don't imply
                    %% the buyer remains an owner just because they paid.
                    Token = maps:get(<<"token_id">>, Order),
                    Key = maps:get(<<"theme_key">>, Order),
                    case damage_theme_nft:owns(Token, Key, Account) of
                        true -> {ok, public_order(Order)};
                        _ -> {ok, public_order(Order#{<<"status">> => <<"transferred_or_unavailable">>})}
                    end;
                _ -> {ok, public_order(Order)}
            end;
        {ok, _} -> {error, forbidden};
        not_found -> {error, order_not_found}
    end.

%% Deliberate CSRF-checked POST. Only a customer explicitly checking their
%% order may drive settlement. The chain is still the source of ownership.
settle_order(Account, Id) ->
    case damage_theme_store:order(Id) of
        {ok, #{<<"account">> := Account} = Order} ->
            case maps:get(<<"status">>, Order) of
                <<"unpaid">> -> check_payment(Order);
                <<"minting">> -> check_pending_mint(Order);
                _ -> order_status(Account, Id)
            end;
        {ok, _} -> {error, forbidden};
        not_found -> {error, order_not_found}
    end.

check_payment(Order) ->
    Id = maps:get(<<"order_id">>, Order),
    Label = maps:get(<<"label">>, Order),
    Response = safely(fun() -> damage_cln:list_invoices_by_label(Label) end),
    case verify_invoice(Order, Response) of
        paid ->
            %% Write a durable 'minting' marker BEFORE the write boundary.
            %% After a crash, status only reconciles the immutable on-chain
            %% payment ID; it does not automatically resubmit unknown writes.
            case damage_theme_store:begin_mint(Id) of
                {ok, _} ->
                    Key = maps:get(<<"theme_key">>, Order),
                    Account = maps:get(<<"account">>, Order),
                    case damage_theme_nft:mint_sats(Account, Key, Id) of
                        {ok, Token} ->
                            ok = damage_theme_store:update_order(Id,
                                #{<<"status">> => <<"minted">>, <<"token_id">> => Token}),
                            {ok, public_order(Order#{<<"status">> => <<"minted">>, <<"token_id">> => Token})};
                        _ -> {ok, public_order(Order#{<<"status">> => <<"minting">>})}
                    end;
                {error, order_already_processing} ->
                    %% Another request performed the compare-and-swap first.
                    {ok, Latest} = damage_theme_store:order(Id),
                    {ok, public_order(Latest)};
                Error -> Error
            end;
        unpaid -> {ok, public_order(Order)};
        expired -> {ok, public_order(Order#{<<"status">> => <<"expired">>})};
        {error, _} -> {error, lightning_verification_unavailable}
    end.

check_pending_mint(Order) ->
    Id = maps:get(<<"order_id">>, Order),
    case damage_theme_nft:sats_token(Id) of
        {ok, Token} ->
            Key = maps:get(<<"theme_key">>, Order),
            Account = maps:get(<<"account">>, Order),
            case damage_theme_nft:owns(Token, Key, Account) of
                true ->
                    ok = damage_theme_store:update_order(Id,
                        #{<<"status">> => <<"minted">>, <<"token_id">> => Token}),
                    {ok, public_order(Order#{<<"status">> => <<"minted">>, <<"token_id">> => Token})};
                _ -> {error, nft_entitlement_mismatch}
            end;
        _ -> {ok, public_order(Order)}
    end.

%% Pure verifier for testing; always match label, payment hash and amount.
verify_invoice(Order, #{invoices := [Invoice]}) when is_map(Invoice) ->
    expected_invoice(Order, Invoice);
verify_invoice(Order, #{<<"invoices">> := [Invoice]}) when is_map(Invoice) ->
    expected_invoice(Order, Invoice);
verify_invoice(Order, #{invoices := []}) ->
    case maps:get(<<"expires_at">>, Order, 0) < erlang:system_time(second) of
        true -> expired;
        false -> unpaid
    end;
verify_invoice(_Order, _) -> {error, invalid_invoice_response}.
expected_invoice(Order, Invoice) ->
    Label = get(Invoice, label),
    Hash = get(Invoice, payment_hash),
    Amount = msat(get(Invoice, amount_received_msat)),
    InvoiceAmount = msat(get(Invoice, amount_msat)),
    Bolt11 = get(Invoice, bolt11),
    Status = get(Invoice, status),
    Required = maps:get(<<"amount_msat">>, Order),
    case {Label =:= maps:get(<<"label">>, Order),
          Hash =:= maps:get(<<"payment_hash">>, Order),
          InvoiceAmount =:= Required,
          Bolt11 =:= maps:get(<<"invoice">>, Order)} of
        {true, true, true, true} ->
            case Status of
                paid when Amount >= Required -> paid;
                <<"paid">> when Amount >= Required -> paid;
                expired -> expired;
                <<"expired">> -> expired;
                _ -> unpaid
            end;
        _ -> {error, mismatched_invoice}
    end.

msat(I) when is_integer(I), I >= 0 -> I;
msat(B) when is_binary(B) ->
    try
        Digits = binary:replace(B, <<"msat">>, <<>>),
        I = binary_to_integer(Digits),
        case I >= 0 of true -> I; false -> -1 end
    catch _:_ -> -1 end;
msat(_) -> -1.
get(Map, Key) -> maps:get(Key, Map, maps:get(atom_to_binary(Key, utf8), Map, undefined)).

buy_damage(Actor, Key) ->
    case priced(Key, <<"price_damage">>) of
        {ok, Theme, Amount} ->
            case Actor of
                #{auth_mode := wallet} ->
                    {ok, purchase_intent(Theme, Amount)};
                #{public_key := _, private_key := _} ->
                    damage_theme_nft:purchase_damage(Actor, Key);
                _ -> {error, wallet_signature_required}
            end;
        Error -> Error
    end.

purchase_intent(Theme, Amount) ->
    #{status => <<"wallet_signature_required">>,
      message => <<"In your wallet, approve the NFT contract to spend the exact DAMAGE amount via AEX-9 create_allowance/change_allowance, then sign buy_damage(theme_key). Wallet login does not authorize custodial signing.">>,
      allowance_spender => maps:get(contract, damage_theme_nft:status()),
      damage_token => maps:get(damage_token, damage_theme_nft:status()),
      contract => maps:get(contract, damage_theme_nft:status()),
      entrypoint => <<"buy_damage">>, theme_key => maps:get(<<"key">>, Theme),
      amount_damage_units => Amount}.

priced(Key, Field) ->
    case damage_theme:find(Key) of
        {ok, #{<<"status">> := <<"available">>} = T} ->
            Price = maps:get(Field, T, 0),
            case Price > 0 of
                true -> {ok, T, Price};
                false -> {error, currency_not_supported}
            end;
        _ -> {error, theme_unavailable}
    end.
public_order(Order) -> maps:without([<<"payment_hash">>, <<"account">>, <<"label">>], Order).
hex(Bytes) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bytes)))).
safely(Fun) -> try Fun() catch _:_ -> {error, service_unavailable} end.
