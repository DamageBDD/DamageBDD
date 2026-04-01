%%%-------------------------------------------------------------------
%%% damage_nwc_wallet.erl
%%%
%%% NWC wallet-side handler for DamageBDD.
%%%
%%% Purpose
%%%   - plugs into damage_nostr.erl
%%%   - handles incoming NIP-47 request events (kind 23194)
%%%   - decrypts request content with NIP-04
%%%   - dispatches supported wallet methods
%%%   - enforces per-client ledger policy via DamageNWCLedger
%%%   - publishes encrypted response events (kind 23195)
%%%
%%% Expected integration from damage_nostr:
%%%
%%%   1) subscribe to wallet requests:
%%%      ["REQ","nwc_wallet",#{kinds => [23194], '#p' => [WalletPubHex]}]
%%%
%%%   2) route incoming events here:
%%%      damage_nwc_wallet:handle_event(Event, State).
%%%
%%%   3) leave state as damage_nostr #state{} record; this module only reads:
%%%      - public_key
%%%      - private_key
%%%      - conn_pid
%%%      - streamref
%%%
%%% Assumptions
%%%   - wallet pubkey is the pubkey of the running damage_nostr process
%%%   - ledger entries are keyed by client pubkey hex
%%%   - resolve_owner_and_ledger_by_client_pubkey/1 currently scans known owners
%%%     via identity_server:list_accounts/0 if available, or can be replaced with
%%%     a direct reverse index later
%%%
%%% Supported methods
%%%   - get_info
%%%   - get_balance
%%%   - pay_invoice
%%%   - make_invoice
%%%
%%% Response shape
%%%   #{
%%%      result_type => Method,
%%%      error => null | #{code => ..., message => ...},
%%%      result => map() | null
%%%   }
%%%
%%%-------------------------------------------------------------------

-module(damage_nwc_wallet).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    handle_event/2,
    subscribe_request/1,

    handle_request_event/2,
    send_response/5,
    send_error/5,

    resolve_owner_and_ledger_by_client_pubkey/1,
    ledger_balance_msat/3,
    ledger_policy/3,
    authorize_amount_msat/4,
    debit_after_payment/6,
    do_get_balance/1,
    wallet_info/1
]).
-import(damage_utils, [to_bin/1]).

-define(NWC_LEDGER_SRC_PATH, "contracts/nwc_ledger.aes").
-define(NWC_REGISTRY_NAME, <<"nwc_ledger">>).
-define(NWC_REQ_KIND, 23194).
-define(NWC_RESP_KIND, 23195).

%%%===================================================================
%%% Public entrypoints
%%%===================================================================

-spec subscribe_request(binary()) -> iolist().
subscribe_request(WalletPubKey0) ->
    WalletPubKey = hex64(WalletPubKey0),
    jsx:encode([
        <<"REQ">>,
        <<"nwc_wallet">>,
        #{
            kinds => [?NWC_REQ_KIND],
            '#p' => [WalletPubKey]
        }
    ]).

-spec handle_event(map(), tuple()) -> ok.
handle_event(
    #{
        <<"id">> := EventId,
        <<"kind">> := ?NWC_REQ_KIND,
        <<"pubkey">> := ClientPubHex,
        <<"content">> := EncContent
    } = Event,
    State
) ->
    handle_request_event(
        #{
            event_id => EventId,
            client_pubkey => hex64(ClientPubHex),
            content => EncContent,
            event => Event
        },
        State
    );
handle_event(Event, _State) ->
    ?LOG_DEBUG("Ignoring non-NWC event ~p", [maps:get(<<"kind">>, Event, undefined)]),
    ok.

-spec handle_request_event(map(), tuple()) -> ok.
handle_request_event(
    #{
        event_id := RequestEventId,
        client_pubkey := ClientPubHex,
        content := EncContent
    } = _Req,
    State
) ->
    WalletPriv = state_private_key(State),
    case damage_nostr:nip04_decrypt_content(EncContent, WalletPriv, ClientPubHex) of
        {ok, Plain} ->
            ?LOG_DEBUG("NWC decrypted request ~p", [Plain]),
            case decode_json_map(Plain) of
                {ok, ReqJson} ->
                    handle_request_json(RequestEventId, ClientPubHex, ReqJson, State);
                {error, Why} ->
                    send_error(
                        RequestEventId,
                        ClientPubHex,
                        <<"PARSE_ERROR">>,
                        fmt(Why),
                        State
                    )
            end;
        {error, Why} ->
            ?LOG_WARNING("NWC decrypt failed ~p", [Why]),
            send_error(
                RequestEventId,
                ClientPubHex,
                <<"DECRYPT_FAILED">>,
                fmt(Why),
                State
            )
    end.

%%%===================================================================
%%% Request dispatch
%%%===================================================================

handle_request_json(RequestEventId, ClientPubHex, ReqJson, State) ->
    Method = maps:get(<<"method">>, ReqJson, <<>>),
    Params = maps:get(<<"params">>, ReqJson, #{}),
    case dispatch(Method, ClientPubHex, Params, State) of
        {ok, Result} ->
            send_response(RequestEventId, ClientPubHex, Method, Result, State);
        {error, Code, Message} ->
            send_error(RequestEventId, ClientPubHex, Code, Message, State)
    end.

dispatch(<<"get_info">>, _ClientPubHex, _Params, State) ->
    {ok, wallet_info(State)};
dispatch(<<"get_balance">>, ClientPubHex, _Params, _State) ->
    do_get_balance(ClientPubHex);
dispatch(<<"pay_invoice">>, ClientPubHex, Params, State) ->
    ?LOG_DEBUG("Pay invoice ~p ~p", [ClientPubHex, Params]),
    handle_pay_invoice(ClientPubHex, Params, State);
dispatch(<<"make_invoice">>, _ClientPubHex, Params, _State) ->
    handle_make_invoice(Params);
dispatch(Method, _ClientPubHex, _Params, _State) ->
    {error, <<"NOT_IMPLEMENTED">>, <<Method/binary, " not supported">>}.
do_get_balance(ClientPubHex) ->
    case resolve_owner_and_ledger_by_client_pubkey(ClientPubHex) of
        {ok, Owner, LedgerCt} ->
            case ledger_balance_msat(Owner, LedgerCt, ClientPubHex) of
                {ok, Msat} ->
                    {ok, #{
                        balance => Msat,
                        currency => <<"msat">>
                    }};
                {error, Why} ->
                    {error, <<"LEDGER_BALANCE_FAILED">>, fmt(Why)}
            end;
        {error, Why} ->
            {error, <<"UNKNOWN_CLIENT">>, fmt(Why)}
    end.
%%%===================================================================
%%% Method handlers
%%%===================================================================

handle_pay_invoice(ClientPubHex, Params, _State) ->
    Invoice = maps:get(<<"invoice">>, Params, maps:get(invoice, Params, <<>>)),
    case Invoice of
        <<>> ->
            {error, <<"INVALID_PARAMS">>, <<"missing invoice">>};
        _ ->
            case cln:decode_invoice(Invoice) of
                {ok, Decoded} ->
                    AmountMsat = invoice_amount_msat(Params, Decoded),
                    case resolve_owner_and_ledger_by_client_pubkey(ClientPubHex) of
                        {ok, Owner, LedgerCt} ->
                            case authorize_amount_msat(Owner, LedgerCt, ClientPubHex, AmountMsat) of
                                ok ->
                                    case cln:pay_invoice(Invoice) of
                                        {ok, PayRes} ->
                                            FeesPaidMsat = pay_fees_msat(PayRes),
                                            _ = debit_after_payment(
                                                Owner,
                                                LedgerCt,
                                                ClientPubHex,
                                                AmountMsat,
                                                payment_ref(PayRes),
                                                payment_meta(PayRes)
                                            ),
                                            {ok, #{
                                                preimage => pay_preimage(PayRes),
                                                fees_paid => FeesPaidMsat,
                                                payment_hash => pay_hash(PayRes)
                                            }};
                                        {error, Why} ->
                                            {error, <<"PAYMENT_FAILED">>, fmt(Why)};
                                        Other ->
                                            {error, <<"PAYMENT_FAILED">>, fmt(Other)}
                                    end;
                                {error, Code, Msg} ->
                                    {error, Code, Msg}
                            end;
                        {error, Why} ->
                            {error, <<"UNKNOWN_CLIENT">>, fmt(Why)}
                    end;
                {error, Why} ->
                    {error, <<"BAD_INVOICE">>, fmt(Why)};
                Other ->
                    {error, <<"BAD_INVOICE">>, fmt(Other)}
            end
    end.

handle_make_invoice(Params) ->
    AmountMsat = invoice_amount_msat_from_params(Params),
    Desc = invoice_desc_from_params(Params),
    Label = invoice_label_from_params(Params),
    case AmountMsat > 0 of
        true ->
            case cln:create_invoice(AmountMsat, Desc, Label) of
                #{bolt11 := _} = Invoice ->
                    _ = damage_nwc_invoice_watch_sup:start_child(Label),
                    {ok, #{
                        type => <<"incoming">>,
                        invoice => invoice_bolt11(Invoice),
                        payment_hash => invoice_payment_hash(Invoice),
                        label => Label
                    }};
                {error, Why} ->
                    {error, <<"INVOICE_CREATE_FAILED">>, fmt(Why)};
                Other ->
                    {error, <<"INVOICE_CREATE_FAILED">>, fmt(Other)}
            end;
        false ->
            {error, <<"INVALID_PARAMS">>, <<"amount must be > 0">>}
    end.

invoice_amount_msat_from_params(Params) ->
    case maps:get(<<"amount_msat">>, Params, maps:get(amount_msat, Params, undefined)) of
        undefined ->
            case maps:get(<<"amount_sats">>, Params, maps:get(amount_sats, Params, undefined)) of
                undefined ->
                    normalize_nonneg_int(
                        maps:get(<<"amount">>, Params, maps:get(amount, Params, 0))
                    );
                Sats ->
                    normalize_nonneg_int(Sats) * 1000
            end;
        Msat ->
            normalize_nonneg_int(Msat)
    end.

invoice_desc_from_params(Params) ->
    case maps:get(<<"description">>, Params, maps:get(description, Params, undefined)) of
        undefined ->
            <<"DamageBDD">>;
        Desc ->
            normalize_desc(Desc)
    end.

invoice_label_from_params(Params) ->
    case maps:get(<<"label">>, Params, maps:get(label, Params, undefined)) of
        undefined ->
            <<"DamageBDD">>;
        Label ->
            normalize_label(Label)
    end.

normalize_label(V) when is_binary(V), V =/= <<>> ->
    V;
normalize_label(V) when is_list(V), V =/= [] ->
    unicode:characters_to_binary(V).
normalize_desc(V) when is_binary(V) ->
    V;
normalize_desc(V) when is_list(V) ->
    unicode:characters_to_binary(V).
normalize_nonneg_int(I) when is_integer(I), I >= 0 ->
    I;
normalize_nonneg_int(B) when is_binary(B) ->
    try binary_to_integer(B) of
        V when V >= 0 -> V;
        _ -> 0
    catch
        _:_ -> 0
    end;
normalize_nonneg_int(L) when is_list(L) ->
    try list_to_integer(L) of
        V when V >= 0 -> V;
        _ -> 0
    catch
        _:_ -> 0
    end;
normalize_nonneg_int(_) ->
    0.

%%%===================================================================
%%% Responses
%%%===================================================================

-spec send_response(binary(), binary(), binary(), map(), tuple()) -> ok.
send_response(RequestEventId, ClientPubHex, Method, Result, State) ->
    Payload = #{
        result_type => Method,
        error => null,
        result => Result
    },
    send_payload(RequestEventId, ClientPubHex, Payload, State).

-spec send_error(binary(), binary(), binary(), binary(), tuple()) -> ok.
send_error(RequestEventId, ClientPubHex, Code, Message, State) ->
    Payload = #{
        result_type => <<"error">>,
        error => #{
            code => Code,
            message => Message
        },
        result => null
    },
    send_payload(RequestEventId, ClientPubHex, Payload, State).

send_payload(RequestEventId, ClientPubHex, Payload, State) ->
    WalletPub = hex64(state_public_key(State)),
    WalletPriv = state_private_key(State),
    Plain = jsx:encode(Payload),
    case nip04_encrypt_content(Plain, WalletPriv, ClientPubHex) of
        {ok, EncContent} ->
            TS = erlang:system_time(seconds),
            Tags = [
                [<<"p">>, ClientPubHex],
                [<<"e">>, RequestEventId]
            ],
            Event0 = damage_nostr:construct_event(
                WalletPub,
                ?NWC_RESP_KIND,
                EncContent,
                TS,
                Tags
            ),
            Event = damage_nostr:finalize_event(Event0, WalletPriv),
            EventJson = jsx:encode([<<"EVENT">>, Event]),
            ok = gun:ws_send(state_conn_pid(State), state_streamref(State), {text, EventJson}),
            gun:flush(state_conn_pid(State)),
            ok;
        {error, Why} ->
            ?LOG_WARNING("NWC response encryption failed ~p", [Why]),
            ok
    end.

nip04_encrypt_content(Plain, PrivKey32, RemoteHex) ->
    case damage_nostr:nip04_encrypt(Plain, PrivKey32, RemoteHex) of
        {ok, CipherB64, IvB64} ->
            {ok, <<CipherB64/binary, "?iv=", IvB64/binary>>};
        Error ->
            Error
    end.

%%%===================================================================
%%% Wallet metadata
%%%===================================================================

wallet_info(State) ->
    #{
        alias => <<"DamageBDD">>,
        color => <<"#1d4ed8">>,
        pubkey => hex64(state_public_key(State)),
        network => network_name(),
        methods => [<<"get_info">>, <<"get_balance">>, <<"pay_invoice">>, <<"make_invoice">>],
        notifications => []
    }.

network_name() ->
    case application:get_env(damage, ae_network_id) of
        {ok, <<"ae_mainnet">>} -> <<"mainnet">>;
        {ok, <<"mainnet">>} -> <<"mainnet">>;
        {ok, <<"testnet">>} -> <<"testnet">>;
        {ok, X} -> to_bin(X);
        _ -> <<"mainnet">>
    end.

%%%===================================================================
%%% Ledger enforcement
%%%===================================================================

-spec resolve_owner_and_ledger_by_client_pubkey(binary()) ->
    {ok, binary(), binary()} | {error, term()}.
resolve_owner_and_ledger_by_client_pubkey(ClientPubHex0) ->
    ClientPubHex = hex64(ClientPubHex0),
    case identity_accounts() of
        {ok, Owners} ->
            find_client_across_owners(ClientPubHex, Owners);
        {error, Why} ->
            {error, {identity_accounts_unavailable, Why}}
    end.

find_client_across_owners(_ClientPubHex, []) ->
    {error, not_found};
find_client_across_owners(ClientPubHex, [Owner | Rest]) ->
    OwnerBin = owner_pubkey(Owner),
    case damage_nwc_http:resolve_user_ledger_ct(OwnerBin) of
        {ok, LedgerCt} ->
            case ledger_policy(OwnerBin, LedgerCt, ClientPubHex) of
                {ok, _Policy} ->
                    {ok, OwnerBin, to_bin(LedgerCt)};
                {error, _} ->
                    find_client_across_owners(ClientPubHex, Rest)
            end;
        {error, _} ->
            find_client_across_owners(ClientPubHex, Rest)
    end.

identity_accounts() ->
    case erlang:function_exported(identity_server, list_accounts, 0) of
        true ->
            try
                {ok, identity_server:list_accounts()}
            catch
                C:R ->
                    {error, {C, R}}
            end;
        false ->
            {error, list_accounts_not_exported}
    end.

owner_pubkey(#{public_key := Pub}) -> to_bin(Pub);
owner_pubkey(#{<<"public_key">> := Pub}) -> to_bin(Pub);
owner_pubkey(Pub) when is_binary(Pub) -> Pub;
owner_pubkey(Pub) when is_list(Pub) -> to_bin(Pub).

-spec ledger_balance_msat(binary(), binary(), binary()) ->
    {ok, integer()} | {error, term()}.
ledger_balance_msat(Owner, LedgerCt, ClientPubHex) ->
    case damage_nwc_http:ledger_call_user(Owner, LedgerCt, "balance", [to_s(ClientPubHex)]) of
        #{"return_type" := "ok", "return_value" := Value} ->
            normalize_int(Value);
        Other ->
            {error, {balance_failed, Other}}
    end.

-spec ledger_policy(binary(), binary(), binary()) ->
    {ok, map()} | {error, term()}.
ledger_policy(Owner, LedgerCt, ClientPubHex) ->
    case damage_nwc_http:ledger_call_user(Owner, LedgerCt, "policy_of", [to_s(ClientPubHex)]) of
        #{"return_type" := "ok", "return_value" := Value} ->
            {ok, normalize_policy(Value)};
        Other ->
            {error, {policy_failed, Other}}
    end.

authorize_amount_msat(Owner, LedgerCt, ClientPubHex, AmountMsat) ->
    authorize_amount_msat(Owner, LedgerCt, ClientPubHex, AmountMsat, current_height()).

authorize_amount_msat(Owner, LedgerCt, ClientPubHex, AmountMsat, Height) ->
    case ledger_policy(Owner, LedgerCt, ClientPubHex) of
        {ok, Policy} ->
            MaxSingle = maps:get(max_single_msat, Policy, 0),
            MaxTotal = maps:get(max_total_msat, Policy, 0),
            Expires = maps:get(expires_height, Policy, 0),
            case MaxSingle > 0 andalso AmountMsat > MaxSingle of
                true ->
                    {error, <<"QUOTA_EXCEEDED">>, <<"amount exceeds max_single_msat">>};
                false ->
                    case Expires > 0 andalso Height > Expires of
                        true ->
                            {error, <<"EXPIRED">>, <<"policy expired">>};
                        false ->
                            case ledger_balance_msat(Owner, LedgerCt, ClientPubHex) of
                                {ok, BalanceMsat} ->
                                    case MaxTotal > 0 andalso (BalanceMsat < AmountMsat) of
                                        true ->
                                            {error, <<"INSUFFICIENT_BALANCE">>,
                                                <<"balance too low">>};
                                        false ->
                                            ok
                                    end;
                                {error, Why} ->
                                    {error, <<"LEDGER_BALANCE_FAILED">>, fmt(Why)}
                            end
                    end
            end;
        {error, Why} ->
            {error, <<"LEDGER_POLICY_FAILED">>, fmt(Why)}
    end.

debit_after_payment(Owner, LedgerCt, ClientPubHex, AmountMsat, Ref, Meta) ->
    case damage_nwc_http:ledger_mode() of
        user_signed ->
            ok;
        server_signed ->
            _ = damage_nwc_http:ledger_call_user(
                Owner,
                LedgerCt,
                "debit",
                [to_s(ClientPubHex), integer_to_list(AmountMsat), to_s(Ref), to_s(Meta)]
            ),
            ok = damage_nwc_balance_cache:invalidate(Owner),
            ok;
        operator_signed ->
            ok
    end.

%%%===================================================================
%%% Normalization helpers
%%%===================================================================

normalize_policy(#{<<"max_single_msat">> := A, <<"max_total_msat">> := B, <<"expires_height">> := C}) ->
    #{
        max_single_msat => intish(A),
        max_total_msat => intish(B),
        expires_height => intish(C)
    };
normalize_policy(#{max_single_msat := A, max_total_msat := B, expires_height := C}) ->
    #{
        max_single_msat => intish(A),
        max_total_msat => intish(B),
        expires_height => intish(C)
    };
normalize_policy({A, B, C}) ->
    #{
        max_single_msat => intish(A),
        max_total_msat => intish(B),
        expires_height => intish(C)
    };
normalize_policy(Other) ->
    #{raw => Other}.

normalize_int(I) when is_integer(I) -> {ok, I};
normalize_int(B) when is_binary(B) ->
    try
        {ok, binary_to_integer(B)}
    catch
        _:_ -> {error, {bad_integer, B}}
    end;
normalize_int(L) when is_list(L) ->
    try
        {ok, list_to_integer(L)}
    catch
        _:_ -> {error, {bad_integer, L}}
    end;
normalize_int(Other) ->
    {error, {bad_integer, Other}}.

intish(I) when is_integer(I) -> I;
intish(B) when is_binary(B) ->
    try
        binary_to_integer(B)
    catch
        _:_ -> 0
    end;
intish(L) when is_list(L) ->
    try
        list_to_integer(L)
    catch
        _:_ -> 0
    end;
intish(_) ->
    0.

current_height() ->
    case erlang:function_exported(damage_ae, top_height, 0) of
        true ->
            try
                damage_ae:top_height()
            catch
                _:_ -> 0
            end;
        false ->
            0
    end.

%%%===================================================================
%%% CLN normalization helpers
%%%===================================================================

invoice_amount_msat(Params, Decoded) ->
    case maps:get(<<"amount">>, Params, maps:get(amount, Params, undefined)) of
        undefined ->
            decode_msat_from_invoice(Decoded);
        A when is_integer(A) ->
            A;
        A when is_binary(A) ->
            binary_to_integer(A);
        A when is_list(A) ->
            list_to_integer(A)
    end.

decode_msat_from_invoice(Decoded) ->
    case maps:get(amount_msat, Decoded, maps:get(<<"amount_msat">>, Decoded, 0)) of
        #{msat := M} -> M;
        #{<<"msat">> := M} -> M;
        M when is_integer(M) -> M;
        B when is_binary(B) -> binary_to_integer(B);
        L when is_list(L) -> list_to_integer(L);
        _ -> 0
    end.

pay_preimage(#{payment_preimage := V}) -> to_bin(V);
pay_preimage(#{<<"payment_preimage">> := V}) -> to_bin(V);
pay_preimage(#{preimage := V}) -> to_bin(V);
pay_preimage(#{<<"preimage">> := V}) -> to_bin(V);
pay_preimage(_) -> <<>>.

pay_hash(#{payment_hash := V}) -> to_bin(V);
pay_hash(#{<<"payment_hash">> := V}) -> to_bin(V);
pay_hash(_) -> <<>>.

pay_fees_msat(#{amount_sent_msat := #{msat := Sent}, amount_msat := #{msat := Amt}}) when
    is_integer(Sent), is_integer(Amt), Sent >= Amt
->
    Sent - Amt;
pay_fees_msat(#{
    <<"amount_sent_msat">> := #{<<"msat">> := Sent}, <<"amount_msat">> := #{<<"msat">> := Amt}
}) when
    is_integer(Sent), is_integer(Amt), Sent >= Amt
->
    Sent - Amt;
pay_fees_msat(_) ->
    0.

payment_ref(PayRes) ->
    case pay_hash(PayRes) of
        <<>> -> <<"nwc_payment">>;
        H -> H
    end.

payment_meta(PayRes) ->
    jsx:encode(#{
        source => <<"nwc">>,
        payment_hash => pay_hash(PayRes)
    }).

invoice_bolt11(#{bolt11 := V}) -> to_bin(V);
invoice_bolt11(#{<<"bolt11">> := V}) -> to_bin(V);
invoice_bolt11(#{invoice := V}) -> to_bin(V);
invoice_bolt11(#{<<"invoice">> := V}) -> to_bin(V);
invoice_bolt11(_) -> <<>>.

invoice_payment_hash(#{payment_hash := V}) -> to_bin(V);
invoice_payment_hash(#{<<"payment_hash">> := V}) -> to_bin(V);
invoice_payment_hash(_) -> <<>>.

%%%===================================================================
%%% damage_nostr state accessors
%%%===================================================================

state_public_key(State) ->
    element(state_pos(public_key), State).

state_private_key(State) ->
    element(state_pos(private_key), State).

state_conn_pid(State) ->
    element(state_pos(conn_pid), State).

state_streamref(State) ->
    element(state_pos(streamref), State).

state_pos(conn_pid) -> 2;
state_pos(streamref) -> 3;
state_pos(public_key) -> 5;
state_pos(private_key) -> 6.

%%%===================================================================
%%% Generic helpers
%%%===================================================================

decode_json_map(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        M when is_map(M) -> {ok, M};
        Other -> {error, {not_a_map, Other}}
    catch
        C:R ->
            {error, {C, R}}
    end.

fmt(Term) ->
    to_bin(io_lib:format("~p", [Term])).

to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(L) when is_list(L) -> L.

hex64(Bin) when is_binary(Bin) ->
    case classify_key(Bin) of
        {hex, 64} ->
            lower_hex_ascii64(Bin);
        {raw, 32} ->
            lower_hex(Bin);
        _ ->
            error({invalid_hex64, Bin})
    end;
hex64(List) when is_list(List) ->
    hex64(to_bin(List)).

lower_hex(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

lower_hex_ascii64(Bin) when is_binary(Bin), byte_size(Bin) =:= 64 ->
    case re:run(Bin, <<"^[0-9a-fA-F]{64}$">>, [{capture, none}]) of
        match ->
            list_to_binary(string:lowercase(binary_to_list(Bin)));
        nomatch ->
            error({invalid_hex_ascii64, Bin})
    end.

classify_key(Bin) when is_binary(Bin) ->
    case is_hex_ascii(Bin) of
        true ->
            {hex, byte_size(Bin)};
        false ->
            case byte_size(Bin) of
                32 -> {raw, 32};
                _ -> invalid
            end
    end.

is_hex_ascii(Bin) when is_binary(Bin) ->
    (byte_size(Bin) band 1) =:= 0 andalso bin_all_hex(Bin).

bin_all_hex(<<>>) -> true;
bin_all_hex(<<C, Rest/binary>>) -> is_hex_byte(C) andalso bin_all_hex(Rest).

is_hex_byte(C) when C >= $0, C =< $9 -> true;
is_hex_byte(C) when C >= $a, C =< $f -> true;
is_hex_byte(C) when C >= $A, C =< $F -> true;
is_hex_byte(_) -> false.
