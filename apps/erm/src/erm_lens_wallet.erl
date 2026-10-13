%%% Separate Nostr social identity and Aeternity settlement authority.
%%% Private keys never enter GTK widgets or configuration for this module.
-module(erm_lens_wallet).

-ifdef(TEST).
-export([validate_prepared/1, check_expiry/1]).
-endif.
-export([
    status/1,
    prepare_tip/4,
    submit_tip/2,
    link_account/1,
    verify_link/4,
    link_draft/3,
    amount/2,
    format_amount/2,
    sign_publish/2
]).

status(C) -> protect(fun() -> adapter(status, [], C) end).

-spec amount(binary(), non_neg_integer()) -> {ok, pos_integer()} | {error, invalid_amount}.
amount(Text, Decimals) when
    is_binary(Text),
    byte_size(Text) =< 80,
    is_integer(Decimals),
    Decimals >= 0,
    Decimals =< 36
->
    case
        re:run(Text, <<"\\A(0|[1-9][0-9]*)(?:\\.([0-9]+))?\\z">>, [{capture, all_but_first, binary}])
    of
        {match, [Whole]} -> amount_parts(Whole, <<>>, Decimals);
        {match, [Whole, Fraction]} -> amount_parts(Whole, Fraction, Decimals);
        _ -> {error, invalid_amount}
    end;
amount(_, _) ->
    {error, invalid_amount}.
amount_parts(W, F, D) when byte_size(F) =< D ->
    Scale = pow10(D),
    FV =
        case F of
            <<>> -> 0;
            _ -> binary_to_integer(F) * pow10(D - byte_size(F))
        end,
    N = binary_to_integer(W) * Scale + FV,
    case N > 0 andalso N < (1 bsl 256) of
        true -> {ok, N};
        false -> {error, invalid_amount}
    end;
amount_parts(_, _, _) ->
    {error, invalid_amount}.
pow10(0) -> 1;
pow10(N) -> 10 * pow10(N - 1).
format_amount(N, 0) when is_integer(N), N >= 0 -> integer_to_binary(N);
format_amount(N, D) when is_integer(N), N >= 0, is_integer(D), D > 0, D =< 36 ->
    Scale = pow10(D),
    W = integer_to_binary(N div Scale),
    F = integer_to_binary(N rem Scale),
    Pad = binary:copy(<<"0">>, D - byte_size(F)),
    <<W/binary, ".", Pad/binary, F/binary>>;
format_amount(_, _) ->
    error(invalid_amount_format).

prepare_tip(E, Contract, Text, C) ->
    protect(fun() ->
        ok = check_network(C),
        ok = erm_lens_nostr:verify(E),
        true = lists:member(Contract, maps:get(tokens, C, [])),
        {ok, #{account := From, network := Network}} = status(C),
        Network = maps:get(network, C),
        {ok, #{decimals := D, symbol := Symbol}} = adapter(token_meta, [Contract], C),
        true = valid_symbol(Symbol),
        {ok, Units} = amount(Text, D),
        Pub = maps:get(<<"pubkey">>, E),
        {ok, #{attestation := Att, claim := Claim}} = adapter(resolve_account, [Pub], C),
        {ok, To} = verify_link(Att, Claim, Pub, C),
        true = account_shape(From) andalso account_shape(To) andalso From =/= To,
        Req = #{
            sender => From,
            recipient => To,
            author => Pub,
            network => Network,
            token => Contract,
            amount_base_units => Units,
            decimals => D,
            symbol => Symbol,
            post_id => maps:get(<<"id">>, E),
            request_id => erm_lens_nostr:hex(crypto:strong_rand_bytes(32)),
            expires_at => erlang:system_time(second) + 120
        },
        {ok, Prepared = #{request := Req, fee_aettos := Fee}} = adapter(prepare_tip, [Req], C),
        ok = validate_prepared(Prepared),
        true = is_integer(Fee) andalso Fee >= 0,
        {ok, Prepared}
    end).

submit_tip(Prepared, C) ->
    protect(fun() ->
        ok = check_network(C),
        ok = validate_prepared(Prepared),
        #{request := Req} = Prepared,
        ok = check_expiry(Req),
        Network = maps:get(network, C),
        Network = maps:get(network, Req),
        true = lists:member(maps:get(token, Req), maps:get(tokens, C, [])),
        {ok, #{account := From, network := Network}} = status(C),
        From = maps:get(sender, Req),
        Pub = maps:get(author, Req),
        {ok, #{attestation := Att, claim := Claim}} = adapter(resolve_account, [Pub], C),
        {ok, To} = verify_link(Att, Claim, Pub, C),
        To = maps:get(recipient, Req),
        {ok, #{decimals := Decimals, symbol := Symbol}} =
            adapter(token_meta, [maps:get(token, Req)], C),
        Decimals = maps:get(decimals, Req),
        Symbol = maps:get(symbol, Req),
        %% Read-side wallet/chain calls can outlast the preview. Check again at
        %% the last boundary, not merely before these potentially slow calls.
        ok = check_expiry(Req),
        %% Adapter must decode/compare the actual transaction to Req and obtain
        %% external-wallet approval. It must NOT blindly sign an opaque payload.
        adapter(submit_tip, [Prepared], C)
    end).

link_draft(Pub, Account, C) ->
    Net = maps:get(network, C),
    Registry = maps:get(registry, C),
    {ok, Content} = erm_lens_codec:encode(#{
        <<"app">> => <<"erm-lens">>,
        <<"version">> => 1,
        <<"network">> => Net,
        <<"registry">> => Registry,
        <<"account">> => Account,
        <<"nonce">> => erm_lens_nostr:hex(crypto:strong_rand_bytes(32))
    }),
    D = <<"erm-lens-account:", Net/binary, ":", Registry/binary>>,
    erm_lens_nostr:draft(Pub, 30078, Content, [[<<"d">>, D]]).
link_account(C) ->
    protect(fun() ->
        ok = check_network(C),
        {ok, #{account := Account, network := Network}} = status(C),
        Network = maps:get(network, C),
        Pub = maps:get(nostr_pubkey, C),
        true = erm_lens_nostr:is_hex(Pub, 64),
        {ok, Signed} = sign(link_draft(Pub, Account, C), C),
        {ok, _} = publish(Signed, C),
        adapter(register_account, [Signed], C)
    end).

%% Claim must come from a configured trusted node / verified chain view, NOT
%% from Nostr metadata. The adapter is responsible for confirmation depth and
%% resolving the newest kind-30078 attestation at this d-tag.
verify_link(E, Claim, Pub, C) ->
    protect(fun() ->
        ok = erm_lens_nostr:verify(E),
        Pub = maps:get(<<"pubkey">>, E),
        30078 = maps:get(<<"kind">>, E),
        Network = maps:get(network, C),
        Registry = maps:get(registry, C),
        D = <<"erm-lens-account:", Network/binary, ":", Registry/binary>>,
        [D] = erm_lens_nostr:tags(E, <<"d">>),
        {ok, #{
            <<"app">> := <<"erm-lens">>,
            <<"version">> := 1,
            <<"network">> := Network,
            <<"registry">> := Registry,
            <<"account">> := Account
        }} = erm_lens_codec:decode(maps:get(<<"content">>, E)),
        true = is_binary(Account),
        true = account_shape(Account),
        true = maps:get(active, Claim),
        true = maps:get(confirmed, Claim),
        Network = maps:get(network, Claim),
        Registry = maps:get(registry, Claim),
        Account = maps:get(account, Claim),
        Pub = maps:get(nostr_pubkey, Claim),
        Id = maps:get(<<"id">>, E),
        Id = maps:get(event_id, Claim),
        {ok, Account}
    end).

sign_publish(Draft, C) ->
    protect(fun() ->
        {ok, Signed} = sign(Draft, C),
        publish(Signed, C)
    end).
sign(Draft, C) ->
    case maps:get(signer, C, undefined) of
        {M, F, Extra} when is_atom(M), is_atom(F), is_list(Extra) ->
            case apply(M, F, [Draft | Extra]) of
                {ok, Signed0} when is_map(Signed0) ->
                    Signed = erm_lens_nostr:event_fields(Signed0),
                    Keys = [<<"pubkey">>, <<"kind">>, <<"created_at">>, <<"content">>, <<"tags">>],
                    case maps:with(Keys, Signed) =:= maps:with(Keys, Draft) of
                        true ->
                            case erm_lens_nostr:verify(Signed) of
                                ok -> {ok, Signed};
                                Err -> Err
                            end;
                        false ->
                            {error, signer_changed_event}
                    end;
                Other ->
                    Other
            end;
        _ ->
            {error, nostr_signer_not_configured}
    end.
publish(E, C) ->
    %% At most four workers; deadline does not automatically retry publishing.
    Jobs = [
        {U, erm_lens_worker:start(published, fun() -> erm_lens_relay:publish(U, E) end)}
     || U <- lists:sublist(lists:usort(maps:get(relays, C, [])), 4)
    ],
    End = erlang:monotonic_time(millisecond) + 25000,
    Results = [
        begin
            Result =
                receive
                    {published, P, R} -> R;
                    {'DOWN', Mon, process, P, Why} -> {error, Why}
                after max(0, End - erlang:monotonic_time(millisecond)) ->
                    exit(P, kill),
                    {error, publish_outcome_unknown}
                end,
            erlang:demonitor(Mon, [flush]),
            {U, Result}
        end
     || {U, {P, Mon}} <- Jobs
    ],
    case
        lists:any(
            fun
                ({_, {ok, _}}) -> true;
                (_) -> false
            end,
            Results
        )
    of
        true ->
            %% A relay acknowledgment is not undone by local cache downtime.
            Local =
                try
                    erm_lens_feed:ingest(E)
                catch
                    _:_ -> {error, local_feed_unavailable}
                end,
            {ok, #{event_id => maps:get(<<"id">>, E), relays => Results, local_ingest => Local}};
        false ->
            {error, {not_acknowledged, Results}}
    end.
check_network(C) ->
    case {maps:get(network, C, <<"ae_uat">>), maps:get(allow_mainnet, C, false)} of
        {<<"ae_uat">>, _} -> ok;
        {<<"ae_mainnet">>, true} -> ok;
        _ -> {error, network_not_enabled}
    end.
adapter(F, Args, C) ->
    case maps:get(wallet_adapter, C, undefined) of
        undefined ->
            {error, aeternity_wallet_adapter_not_configured};
        M when is_atom(M) ->
            protect(fun() ->
                case apply(M, F, Args ++ [C]) of
                    {ok, _} = OK -> OK;
                    {error, _} = Error -> Error;
                    _ -> {error, invalid_wallet_adapter_result}
                end
            end);
        _ ->
            {error, invalid_wallet_adapter}
    end.
protect(Fun) ->
    try
        Fun()
    catch
        error:{badmatch, {error, Reason}} -> {error, Reason};
        error:{badmatch, _} -> {error, identity_network_or_transaction_mismatch};
        error:undef -> {error, adapter_function_unavailable};
        _:_ -> {error, operation_failed}
    end.

%% This validates the local intent, not an opaque chain transaction. The
%% adapter must additionally decode/check the actual transaction, enforce
%% durable request-ID idempotency, and reconcile unknown submission outcomes.
validate_prepared(#{request := Req, fee_aettos := Fee}) when
    is_map(Req), is_integer(Fee), Fee >= 0, Fee < (1 bsl 256)
->
    case Req of
        #{
            sender := From,
            recipient := To,
            author := Pub,
            network := Network,
            token := Token,
            amount_base_units := Units,
            decimals := Decimals,
            symbol := Symbol,
            post_id := Post,
            request_id := Id,
            expires_at := Expiry
        } when
            is_integer(Units),
            Units > 0,
            Units < (1 bsl 256),
            is_integer(Decimals),
            Decimals >= 0,
            Decimals =< 36,
            is_integer(Expiry),
            Expiry > 0
        ->
            case
                account_shape(From) andalso account_shape(To) andalso From =/= To andalso
                    contract_shape(Token) andalso is_binary(Network) andalso
                    erm_lens_nostr:is_hex(Pub, 64) andalso erm_lens_nostr:is_hex(Post, 64) andalso
                    erm_lens_nostr:is_hex(Id, 64) andalso valid_symbol(Symbol)
            of
                true -> ok;
                false -> {error, invalid_prepared_tip}
            end;
        _ ->
            {error, invalid_prepared_tip}
    end;
validate_prepared(_) ->
    {error, invalid_prepared_tip}.

check_expiry(#{expires_at := Expiry}) when is_integer(Expiry) ->
    Now = erlang:system_time(second),
    case Expiry > Now andalso Expiry =< Now + 120 of
        true -> ok;
        false -> {error, tip_preview_expired}
    end;
check_expiry(_) ->
    {error, invalid_prepared_tip}.

%% Prefix/size validation only. Checksums and chain identity remain the
%% official SDK / node adapter's responsibility; these are not chain proofs.
account_shape(<<"ak_", Rest/binary>>) -> base58_shape(Rest);
account_shape(_) -> false.
contract_shape(<<"ct_", Rest/binary>>) -> base58_shape(Rest);
contract_shape(_) -> false.
valid_symbol(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 32 ->
    lists:all(fun(C) -> C >= 33 andalso C =< 126 end, binary_to_list(B));
valid_symbol(_) ->
    false.

base58_shape(B) when byte_size(B) > 0, byte_size(B) =< 100 ->
    Alphabet = <<"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz">>,
    lists:all(fun(C) -> binary:match(Alphabet, <<C>>) =/= nomatch end, binary_to_list(B));
base58_shape(_) ->
    false.
