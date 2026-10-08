%% All transport, runes, TLS and pooling remain owned by DamageBDD.
%% Requires the additive damage_cln decode_invoice/1, list_pays/1, xpay_invoice/2 patch.
-module(ecai_index_rewards_cln).
-export([fund/3, funding/2, decode/2, pay/2, reconcile/2, liquidity/0]).

fund(Config, Label, Amount) ->
    safe(fun() ->
        treasury(Config),
        case invoices(Label) of
            [] ->
                %% Label is already durable. CLN rejects a second invoice with
                %% this label, so a crash here cannot create two funding invoices.
                _ = damage_cln:create_invoice(Amount, <<"ECAI indexing budget">>, 86400, Label),
                find_invoice(Label);
            [_] -> find_invoice(Label);
            _ -> fail(ambiguous_funding_invoice)
        end
    end).
funding(Config, Label) -> safe(fun() -> treasury(Config), find_invoice(Label) end).

decode(Config, Bolt11) ->
    safe(fun() ->
        treasury(Config),
        M = object(damage_cln:decode_invoice(Bolt11)),
        D = pick([type, valid, currency, created_at, expiry, payee, payment_hash,
              amount_msat, description], M),
        D#{amount_msat => msat(field(amount_msat, M))}
    end).

pay(Config, Payout) ->
    safe(fun() ->
        treasury(Config),
        Hash = maps:get(payment_hash, Payout),
        %% Never pay if CLN already knows this hash. There may be a payment
        %% from a previous coordinator incarnation still in flight.
        case payment(Hash) of
            #{status := absent} -> send(Config, Payout);
            #{status := failed} -> send(Config, Payout);
            Known -> Known
        end
    end).
send(Config, P) ->
    Options = #{maxfee => maps:get(fee_cap_msat, P), retry_for => 30, maxdelay => 144},
    Invoice = maps:get(bolt11, P),
    %% No transport fallback: an error/timeout is an UNCERTAIN side effect.
    Response = case maps:get(payment_method, Config, xpay) of
        xpay -> damage_cln:xpay_invoice(Invoice, Options);
        pay -> damage_cln:pay_invoice(Invoice, Options);
        _ -> fail(unsupported_payment_method)
    end,
    Seen = payment(maps:get(payment_hash, P)),
    case Seen of
        #{status := failed} ->
            %% A failed OLD payment is not evidence that an ambiguous NEW RPC
            %% never started. Mark retryable only after an explicit CLN error
            %% response to this invocation AND failed aggregated payment state.
            case is_map(Response) andalso is_integer(field(code, Response)) of
                true -> Seen#{definitive => true, attempt => maps:get(attempts, P)};
                false -> Seen#{status => unknown}
            end;
        _ -> Seen
    end.
reconcile(Config, P) -> safe(fun() -> treasury(Config), payment(maps:get(payment_hash, P)) end).

payment(Hash) ->
    M = object(damage_cln:list_pays(#{payment_hash => Hash})),
    Pays = required_list(field(pays, M)),
    Matches = [P || P <- Pays, is_map(P), field(payment_hash, P) =:= Hash],
    case Matches of
        [] when Pays =:= [] -> #{status => absent, payment_hash => Hash};
        [P] ->
            case field(status, P) of
                <<"complete">> ->
                    #{status => complete, payment_hash => Hash,
                      amount_msat => msat(field(amount_msat, P)),
                      amount_sent_msat => msat(field(amount_sent_msat, P)),
                      preimage => field(preimage, P)};
                <<"failed">> -> #{status => failed, payment_hash => Hash};
                _ -> #{status => pending, payment_hash => Hash}
            end;
        _ -> fail(ambiguous_payment_history)
    end.

find_invoice(Label) ->
    case invoices(Label) of
        [M] ->
            V = pick([label, bolt11, payment_hash, status, amount_msat,
                      amount_received_msat, expires_at, paid_at], M),
            V1 = V#{amount_msat => msat(maps:get(amount_msat, V))},
            case maps:get(status, V1) of
                <<"paid">> -> V1#{amount_received_msat => msat(maps:get(amount_received_msat, V1))};
                _ -> V1
            end;
        [] -> fail(funding_invoice_not_found);
        _ -> fail(ambiguous_funding_invoice)
    end.
invoices(Label) ->
    M = object(damage_cln:list_invoices_by_label(Label)),
    [I || I <- required_list(field(invoices, M)), is_map(I), field(label, I) =:= Label].

treasury(Config) ->
    Info = object(damage_cln:getinfo()),
    case field(id, Info) =:= maps:get(treasury_node, Config) andalso
         field(network, Info) =:= maps:get(network, Config, <<"regtest">>) of
        true -> ok;
        false -> fail(treasury_identity_or_network_mismatch)
    end,
    case {field(network, Info), maps:get(allow_mainnet, Config, false)} of
        {<<"bitcoin">>, true} -> ok;
        {<<"bitcoin">>, _} -> fail(mainnet_not_authorized);
        _ -> ok
    end.

%% Advisory channel capacities, NOT job budgets or a route-success guarantee.
liquidity() -> safe(fun() ->
    Raw = object(damage_cln:list_peerchannels()),
    Cs = required_list(field(channels, Raw)),
    Active = [C || C <- Cs, field(state, C) =:= <<"CHANNELD_NORMAL">>,
                           field(peer_connected, C) =:= true],
    Rows = [#{peer_id => field(peer_id, C), channel_id => field(channel_id, C),
              spendable_msat => msat(field(spendable_msat, C)),
              receivable_msat => msat(field(receivable_msat, C))} || C <- Active],
    #{source => damage_cln, cached => false, observed_at => erlang:system_time(second),
      spendable_msat => lists:sum([maps:get(spendable_msat, C) || C <- Rows]),
      receivable_msat => lists:sum([maps:get(receivable_msat, C) || C <- Rows]), channels => Rows}
end).

field(K, M) -> maps:get(K, M, maps:get(atom_to_binary(K, utf8), M, undefined)).
pick(Keys, M) -> maps:from_list([{K, field(K, M)} || K <- Keys]).
object({ok, M}) when is_map(M) -> object(M);
object(M) when is_map(M) ->
    case field(error, M) =/= undefined orelse field(code, M) =/= undefined of
        true -> fail(cln_rpc_error); false -> M
    end;
object(_) -> fail(cln_unavailable).
required_list(L) when is_list(L) -> L;
required_list(_) -> fail(invalid_cln_response).
msat(N) when is_integer(N), N >= 0 -> N;
msat(B) when is_binary(B) ->
    case re:run(B, <<"^([0-9]+)msat$">>, [{capture, [1], binary}]) of
        {match, [N]} -> binary_to_integer(N);
        _ -> fail(invalid_cln_msat)
    end;
msat(_) -> fail(invalid_cln_msat).
safe(F) -> try {ok, F()} catch throw:{cln_adapter, R} -> {error, R}; _:_ -> {error, cln_unavailable} end.
fail(R) -> throw({cln_adapter, R}).
