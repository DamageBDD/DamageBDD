%% -------------------------------------------------------------------
%% damage_nwc_wallet.erl
%%
%% Server-side NIP-47 (Nostr Wallet Connect) wallet service for Damage.
%%
%% - Listens on Nostr relays for NWC request events (kind 23194) addressed
%%   to this wallet pubkey via ["p", WalletPub].
%% - Decrypts request content via NIP-04 (wallet_priv + client_pub)
%% - Enforces spendable sats via an Aeternity smart contract ledger
%% - Executes allowed methods through Core Lightning (cln.erl)
%% - Records transactions on-chain and updates spendable balance
%% - Responds with kind 23195 with tags ["p", ClientPub], ["e", ReqId]
%%
%% Dependencies in your tree:
%%   - damage_nostr.erl: construct_event/5, finalize_event/2,
%%                      nip04_encrypt/3, nip04_decrypt_content/3
%%   - damage_ae.erl: contract_call_dry/5, contract_call/5
%%   - cln.erl: pay_invoice/2, create_invoice/3
%%
%% Smart contract expectations (configurable function names):
%%   balance(pubkey_hex) -> int (msats or sats; choose one and be consistent)
%%   debit(pubkey_hex, amount_msat, ref, meta) -> ok/bool
%%   credit(pubkey_hex, amount_msat, ref, meta) -> ok/bool  (optional)
%%   record(pubkey_hex, type, amount_msat, ref, meta) -> ok/bool (optional)
%%
%% -------------------------------------------------------------------

-module(damage_nwc_wallet).
-author("Steven Joseph <steven@damagebdd.com>").

-copyright("Steven Joseph <steven@damagebdd.com>").

-license("Apache-2.0").
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    stop/1,
    connection_uri/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-import(damage_utils, [to_bin/1]).

-record(conn, {relay_url, conn_pid, streamref}).

-record(state, {
    %% Nostr wallet service keys

    %% 32 bytes
    wallet_privkey,
    %% 64 hex lower
    wallet_pub_hex,

    %% Relays

    %% [binary()]
    relays = [],
    %% StreamRef => #conn{}
    conns = #{},

    %% Subscription id
    subid = <<>>,

    %% NWC ledger contract

    %% <<"ct_...">>
    ledger_contract_id = undefined,
    %% "contracts/ledger.aes" or similar
    ledger_contract_source = undefined,
    %% msat | sat
    ledger_unit = msat,
    func_balance = <<"balance">>,
    func_debit = <<"debit">>,
    %% optional
    func_credit = <<"credit">>,
    %% optional
    func_record = <<"record">>,

    %% Policy
    allow_methods = [<<"get_info">>, <<"get_balance">>, <<"make_invoice">>, <<"pay_invoice">>],
    %% 50k sats default
    max_single_pay_msat = 50_000_000,
    %% unused (we subscribe)
    min_poll_ms = 0,

    %% Cache
    info_content = <<"get_info get_balance make_invoice pay_invoice">>
}).

%% -------------------------------------------------------------------
%% Public API
%% -------------------------------------------------------------------

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, [Opts], []).

stop(Pid) ->
    gen_server:call(Pid, stop).

%% If you want to show a connection URI to an authenticated user:
%% secret is a *client* key (private key) that you mint per user/session.
%% This function just formats; you still must persist secret->user mapping
%% in your Damage auth layer (DB/contract/etc).
connection_uri(#{wallet_pub_hex := WalletPub, relays := [Relay | _], secret_hex := SecretHex}) ->
    <<
        "nostr+walletconnect://",
        (to_bin(WalletPub))/binary,
        "?relay=",
        (to_bin(Relay))/binary,
        "&secret=",
        (to_bin(SecretHex))/binary
    >>.

%% -------------------------------------------------------------------
%% gen_server
%% -------------------------------------------------------------------

init([Opts0]) ->
    try
        Opts = normalize_opts(Opts0),

        WalletPriv = maps:get(wallet_privkey, Opts),
        {ok, WalletPubBin} = nostrlib_schnorr:new_publickey(WalletPriv),
        WalletPubHex = lower_hex(WalletPubBin),

        Relays = maps:get(relays, Opts),
        SubId = rand_subid(<<"nwc_srv">>),

        State0 =
            #state{
                wallet_privkey = WalletPriv,
                wallet_pub_hex = WalletPubHex,
                relays = Relays,
                subid = SubId,

                ledger_contract_id = maps:get(ledger_contract_id, Opts, undefined),
                ledger_contract_source = maps:get(ledger_contract_source, Opts, undefined),
                ledger_unit = maps:get(ledger_unit, Opts, msat),

                func_balance = maps:get(func_balance, Opts, <<"balance">>),
                func_debit = maps:get(func_debit, Opts, <<"debit">>),
                func_credit = maps:get(func_credit, Opts, <<"credit">>),
                func_record = maps:get(func_record, Opts, <<"record">>),

                allow_methods = maps:get(
                    allow_methods,
                    Opts,
                    [<<"get_info">>, <<"get_balance">>, <<"make_invoice">>, <<"pay_invoice">>]
                ),
                max_single_pay_msat = maps:get(max_single_pay_msat, Opts, 50_000_000),
                info_content = maps:get(
                    info_content,
                    Opts,
                    <<"get_info get_balance make_invoice pay_invoice">>
                )
            },

        %% Connect all relays (subscribe in upgrade handler)
        State1 = lists:foldl(fun connect_relay/2, State0, Relays),

        {ok, State1}
    catch
        C:R:S ->
            ?LOG_ERROR("damage_nwc_wallet init failed ~p:~p ~p", [C, R, S]),
            {stop, {init_failed, R}}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Any, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Any, State) ->
    {noreply, State}.

handle_info({gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _}, State = #state{}) ->
    %% Subscribe to NWC requests addressed to our wallet pubkey.
    %% Filter: kind 23194 and #p includes WalletPubHex
    Filter = #{kinds => [23194], '#p' => [State#state.wallet_pub_hex], limit => 0},
    Req = jsx:encode([<<"REQ">>, State#state.subid, Filter]),
    ok = gun:ws_send(ConnPid, StreamRef, {text, Req}),
    gun:flush(ConnPid),
    ?LOG_INFO("damage_nwc_wallet subscribed relay ~p", [StreamRef]),
    {noreply, State};
handle_info({gun_ws, _ConnPid, _StreamRef, {text, MsgBin}}, State) ->
    {noreply, handle_relay_message(MsgBin, State)};
handle_info({gun_down, _ConnPid, _Proto, Reason, _Killed, _Unproc}, State) ->
    ?LOG_WARNING("damage_nwc_wallet relay down: ~p", [Reason]),
    {noreply, State};
handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #state{conns = Conns}) ->
    maps:foreach(
        fun(_Ref, #conn{conn_pid = ConnPid}) ->
            catch gun:shutdown(ConnPid)
        end,
        Conns
    ),
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.

%% -------------------------------------------------------------------
%% Relay message handling
%% -------------------------------------------------------------------

handle_relay_message(MsgBin0, State) ->
    MsgBin = to_bin(MsgBin0),
    try jsx:decode(MsgBin, [{labels, atom}]) of
        [<<"EVENT">>, _SubId, Event] when is_map(Event) ->
            handle_event(Event, State);
        [<<"NOTICE">>, Notice] ->
            ?LOG_WARNING("damage_nwc_wallet relay NOTICE: ~p", [Notice]),
            State;
        _ ->
            State
    catch
        _:Reason ->
            ?LOG_WARNING("damage_nwc_wallet bad relay msg ~p (~p)", [MsgBin, Reason]),
            State
    end.

handle_event(#{kind := 23194} = Event, State) ->
    %% NWC request event
    spawn(fun() -> process_request(Event, State) end),
    State;
handle_event(_Other, State) ->
    State.

%% -------------------------------------------------------------------
%% NWC request processing
%% -------------------------------------------------------------------

process_request(Event, State = #state{wallet_privkey = WalletPriv, wallet_pub_hex = WalletPub}) ->
    try
        ClientPub = lower_hex_ascii64(to_bin(maps:get(pubkey, Event))),
        ReqId = to_bin(maps:get(id, Event)),
        Content = to_bin(maps:get(content, Event, <<>>)),

        %% Ensure it is actually addressed to us
        ok = ensure_p_tag(Event, WalletPub),

        %% Decrypt request JSON (method + params)
        {ok, Plain} = damage_nostr:nip04_decrypt_content(Content, WalletPriv, ClientPub),
        Req = jsx:decode(Plain, [return_maps]),

        Method = maps:get(<<"method">>, Req, <<"">>),
        Params = maps:get(<<"params">>, Req, #{}),

        case method_allowed(Method, State#state.allow_methods) of
            false ->
                reply_error(
                    ClientPub,
                    ReqId,
                    Method,
                    #{code => <<"METHOD_NOT_ALLOWED">>, message => <<"not allowed">>},
                    State
                );
            true ->
                dispatch_method(ClientPub, ReqId, Method, Params, State)
        end
    catch
        C:R ->
            %% Best effort error response if we can
            ?LOG_WARNING("damage_nwc_wallet request failed ~p:~p", [C, R]),
            ok
    end.

dispatch_method(ClientPub, ReqId, <<"get_info">>, _Params, State) ->
    %% Per NIP-47 wallet service publishes info event kind 13194 (replaceable).
    %% But clients also call method get_info. Return capabilities.
    Res = #{
        alias => <<"Damage NWC">>,
        color => <<"#f7931a">>,
        pubkey => State#state.wallet_pub_hex,
        methods => binary:split(State#state.info_content, <<" ">>, [global])
    },
    reply_ok(ClientPub, ReqId, <<"get_info">>, Res, State);
dispatch_method(ClientPub, ReqId, <<"get_balance">>, _Params, State) ->
    case ledger_balance_msat(ClientPub, State) of
        {ok, BalMsat} ->
            reply_ok(ClientPub, ReqId, <<"get_balance">>, #{balance_msat => BalMsat}, State);
        {error, Why} ->
            reply_error(
                ClientPub,
                ReqId,
                <<"get_balance">>,
                #{code => <<"LEDGER_ERROR">>, message => to_bin(io_lib:format("~p", [Why]))},
                State
            )
    end;
dispatch_method(ClientPub, ReqId, <<"make_invoice">>, Params, State) ->
    %% Params: amount (msat or sat depending on your contract/unit), description
    Amount0 = maps:get(<<"amount">>, Params, 0),
    Desc = maps:get(<<"description">>, Params, <<"">>),

    AmountMsat = normalize_amount_to_msat(Amount0, State),
    %% This mints an incoming invoice; you may want to CREDIT ledger on settle (not here).
    %% For now, just create invoice and record "invoice_created".
    Label = <<"nwc_", ReqId/binary>>,

    CLNRes = cln:create_invoice(AmountMsat, Label, Desc),
    case CLNRes of
        #{bolt11 := Bolt11} = M ->
            _ = ledger_record(
                ClientPub, <<"invoice_created">>, AmountMsat, ReqId, #{bolt11 => Bolt11}, State
            ),
            reply_ok(ClientPub, ReqId, <<"make_invoice">>, M, State);
        {error, Why} ->
            reply_error(
                ClientPub,
                ReqId,
                <<"make_invoice">>,
                #{code => <<"CLN_ERROR">>, message => to_bin(io_lib:format("~p", [Why]))},
                State
            );
        Other ->
            reply_error(
                ClientPub,
                ReqId,
                <<"make_invoice">>,
                #{code => <<"CLN_ERROR">>, message => to_bin(io_lib:format("~p", [Other]))},
                State
            )
    end;
dispatch_method(ClientPub, ReqId, <<"pay_invoice">>, Params, State) ->
    Bolt11 = maps:get(<<"invoice">>, Params, <<>>),
    AmountParam = maps:get(<<"amount">>, Params, undefined),

    %% Policy: optional explicit amount for zero-amount invoices
    Opts =
        case AmountParam of
            undefined -> #{};
            null -> #{};
            _ -> #{amount_msat => normalize_amount_to_msat(AmountParam, State)}
        end,

    %% Pre-check spendable (best effort). We debit based on actual paid msat after success.
    MaxMsat = State#state.max_single_pay_msat,
    case maybe_estimate_intended_msat(AmountParam, MaxMsat, State) of
        {error, Err} ->
            reply_error(ClientPub, ReqId, <<"pay_invoice">>, Err, State);
        ok ->
            case ledger_balance_msat(ClientPub, State) of
                {ok, BalMsat} when BalMsat =< 0 ->
                    reply_error(
                        ClientPub,
                        ReqId,
                        <<"pay_invoice">>,
                        #{code => <<"INSUFFICIENT_FUNDS">>, message => <<"no spendable balance">>},
                        State
                    );
                {ok, _BalMsat} ->
                    %% Pay using CLN
                    PayRes = cln:pay_invoice(to_bin(Bolt11), Opts),
                    case PayRes of
                        #{amount_msat := PaidMsat0} = PR ->
                            PaidMsat = normalize_msat_value(PaidMsat0),
                            case PaidMsat > MaxMsat of
                                true ->
                                    reply_error(
                                        ClientPub,
                                        ReqId,
                                        <<"pay_invoice">>,
                                        #{
                                            code => <<"LIMIT_EXCEEDED">>,
                                            message => <<"payment exceeds limit">>
                                        },
                                        State
                                    );
                                false ->
                                    %% Debit ledger on-chain
                                    case
                                        ledger_debit(
                                            ClientPub, PaidMsat, ReqId, #{bolt11 => Bolt11}, State
                                        )
                                    of
                                        ok ->
                                            _ = ledger_record(
                                                ClientPub,
                                                <<"paid_invoice">>,
                                                PaidMsat,
                                                ReqId,
                                                #{bolt11 => Bolt11},
                                                State
                                            ),
                                            reply_ok(
                                                ClientPub, ReqId, <<"pay_invoice">>, PR, State
                                            );
                                        {error, Why2} ->
                                            %% At this point payment succeeded but ledger failed.
                                            %% You likely want a reconciliation job; we return an error that indicates partial failure.
                                            reply_error(
                                                ClientPub,
                                                ReqId,
                                                <<"pay_invoice">>,
                                                #{
                                                    code => <<"LEDGER_DEBIT_FAILED">>,
                                                    message => to_bin(io_lib:format("~p", [Why2]))
                                                },
                                                State
                                            )
                                    end
                            end;
                        {error, Why} ->
                            reply_error(
                                ClientPub,
                                ReqId,
                                <<"pay_invoice">>,
                                #{
                                    code => <<"PAY_FAILED">>,
                                    message => to_bin(io_lib:format("~p", [Why]))
                                },
                                State
                            );
                        Other ->
                            reply_error(
                                ClientPub,
                                ReqId,
                                <<"pay_invoice">>,
                                #{
                                    code => <<"PAY_FAILED">>,
                                    message => to_bin(io_lib:format("~p", [Other]))
                                },
                                State
                            )
                    end;
                {error, Why} ->
                    reply_error(
                        ClientPub,
                        ReqId,
                        <<"pay_invoice">>,
                        #{
                            code => <<"LEDGER_ERROR">>,
                            message => to_bin(io_lib:format("~p", [Why]))
                        },
                        State
                    )
            end
    end;
dispatch_method(ClientPub, ReqId, Method, _Params, State) ->
    reply_error(
        ClientPub, ReqId, Method, #{code => <<"UNKNOWN_METHOD">>, message => <<"unknown">>}, State
    ).

%% -------------------------------------------------------------------
%% Responding
%% -------------------------------------------------------------------

reply_ok(ClientPub, ReqId, Method, Result, State) ->
    Payload = #{result_type => Method, error => null, result => Result},
    send_response(ClientPub, ReqId, Payload, State).

reply_error(ClientPub, ReqId, Method, ErrMap, State) ->
    Payload = #{result_type => Method, error => ErrMap, result => null},
    send_response(ClientPub, ReqId, Payload, State).

send_response(
    ClientPub,
    ReqId,
    Payload,
    State = #state{wallet_privkey = WalletPriv, wallet_pub_hex = WalletPub}
) ->
    TS = erlang:system_time(seconds),
    Plain = jsx:encode(Payload),

    case damage_nostr:nip04_encrypt(Plain, WalletPriv, ClientPub) of
        {ok, CipherB64, IvB64} ->
            Content = <<CipherB64/binary, "?iv=", IvB64/binary>>,
            Tags = [
                [<<"p">>, ClientPub],
                [<<"e">>, ReqId]
            ],
            Ev0 = damage_nostr:construct_event(WalletPub, 23195, Content, TS, Tags),
            Ev = damage_nostr:finalize_event(Ev0, WalletPriv),
            publish_event(Ev, State),
            ok;
        Other ->
            ?LOG_WARNING("damage_nwc_wallet cannot encrypt response: ~p", [Other]),
            ok
    end.

publish_event(Event, #state{conns = Conns}) ->
    Msg = jsx:encode([<<"EVENT">>, Event]),
    maps:foreach(
        fun(_Ref, #conn{conn_pid = ConnPid, streamref = StreamRef}) ->
            catch gun:ws_send(ConnPid, StreamRef, {text, Msg})
        end,
        Conns
    ),
    ok.

%% -------------------------------------------------------------------
%% Ledger (smart contract)
%% -------------------------------------------------------------------

ledger_balance_msat(ClientPubHex, State) ->
    case {State#state.ledger_contract_id, State#state.ledger_contract_source} of
        {undefined, _} ->
            {error, no_ledger_config};
        {_, undefined} ->
            {error, no_ledger_config};
        {Cid, Src} ->
            %% Contract arg format depends on your Sophia contract ABI.
            %% We pass pubkey as string.
            Args = [binary_to_list(ClientPubHex)],
            case damage_ae:contract_call_dry(Cid, Src, State#state.func_balance, Args, #{}) of
                #{<<"result">> := R} ->
                    %% Your dry-call result shape may differ. Adjust extraction here.
                    %% Expect integer in msat (preferred).
                    {ok, normalize_contract_int(R, State#state.ledger_unit)};
                Other ->
                    {error, Other}
            end
    end.

ledger_debit(ClientPubHex, AmountMsat, Ref, Meta, State) ->
    case {State#state.ledger_contract_id, State#state.ledger_contract_source} of
        {undefined, _} ->
            {error, no_ledger_config};
        {_, undefined} ->
            {error, no_ledger_config};
        {Cid, Src} ->
            MetaJson = jsx:encode(Meta),
            AmountForContract = amount_for_contract_unit(AmountMsat, State#state.ledger_unit),
            Args = [
                binary_to_list(ClientPubHex),
                AmountForContract,
                binary_to_list(to_bin(Ref)),
                binary_to_list(MetaJson)
            ],
            %% On-chain mutation
            case damage_ae:contract_call(Cid, Src, State#state.func_debit, Args, #{}) of
                #{<<"call_tx_hash">> := _Tx} -> ok;
                #{<<"result">> := _} -> ok;
                Other -> {error, Other}
            end
    end.

ledger_record(ClientPubHex, Type, AmountMsat, Ref, Meta, State) ->
    case
        {
            State#state.ledger_contract_id,
            State#state.ledger_contract_source,
            State#state.func_record
        }
    of
        {undefined, _, _} ->
            {error, no_ledger_config};
        {_, undefined, _} ->
            {error, no_ledger_config};
        %% optional
        {_, _, undefined} ->
            ok;
        {Cid, Src, Func} ->
            MetaJson = jsx:encode(Meta),
            AmountForContract = amount_for_contract_unit(AmountMsat, State#state.ledger_unit),
            Args = [
                binary_to_list(ClientPubHex),
                binary_to_list(Type),
                AmountForContract,
                binary_to_list(to_bin(Ref)),
                binary_to_list(MetaJson)
            ],
            catch damage_ae:contract_call(Cid, Src, Func, Args, #{}),
            ok
    end.

%% -------------------------------------------------------------------
%% Connection management
%% -------------------------------------------------------------------

connect_relay(RelayUrl0, State) ->
    RelayUrl = to_bin(RelayUrl0),
    case open_relay(RelayUrl) of
        {ok, ConnPid, StreamRef} ->
            Conn = #conn{relay_url = RelayUrl, conn_pid = ConnPid, streamref = StreamRef},
            Conns2 = maps:put(StreamRef, Conn, State#state.conns),
            State#state{conns = Conns2};
        {error, Why} ->
            ?LOG_WARNING("damage_nwc_wallet cannot connect relay ~p: ~p", [RelayUrl, Why]),
            State
    end.

open_relay(RelayUrl) ->
    Parsed = uri_string:parse(RelayUrl),
    Scheme = maps:get(scheme, Parsed, <<"wss">>),
    Host0 = maps:get(host, Parsed, <<>>),
    Host = binary_to_list(to_bin(Host0)),
    Port = maps:get(port, Parsed, undefined),
    Path0 = maps:get(path, Parsed, <<"/">>),
    Query0 = maps:get(query, Parsed, <<>>),

    Path =
        case Query0 of
            <<>> -> binary_to_list(to_bin(Path0));
            _ -> binary_to_list(<<(to_bin(Path0))/binary, "?", (to_bin(Query0))/binary>>)
        end,

    P =
        case Port of
            undefined when Scheme =:= "ws"; Scheme =:= <<"ws">> -> 80;
            undefined -> 443;
            _ -> Port
        end,

    TransportOpts =
        case Scheme of
            "ws" -> #{};
            <<"ws">> -> #{};
            _ -> #{transport => tls, tls_opts => [{verify, verify_peer}]}
        end,

    case gun:open(Host, P, TransportOpts) of
        {ok, ConnPid} ->
            StreamRef = gun:ws_upgrade(ConnPid, Path, []),
            {ok, ConnPid, StreamRef};
        Error ->
            Error
    end.

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

normalize_opts(Opts0) ->
    Opts = Opts0,
    Relays0 = maps:get(relays, Opts, nostr_pool:default_relays(#{})),
    Relays = [to_bin(R) || R <- Relays0, R =/= <<>>],
    WalletPriv =
        case maps:get(wallet_privkey, Opts, undefined) of
            Bin when is_binary(Bin), byte_size(Bin) =:= 32 -> Bin;
            Hex when is_binary(Hex), byte_size(Hex) >= 64 -> binary:decode_hex(Hex);
            _ -> error({missing_or_bad_wallet_privkey, Opts})
        end,
    Opts#{relays => Relays, wallet_privkey => WalletPriv}.

ensure_p_tag(Event, WalletPub) ->
    Tags = maps:get(tags, Event, []),
    case
        lists:any(
            fun(Tag) ->
                is_list(Tag) andalso length(Tag) >= 2 andalso hd(Tag) =:= <<"p">> andalso
                    lists:nth(2, Tag) =:= WalletPub
            end,
            Tags
        )
    of
        true -> ok;
        false -> error(not_addressed_to_wallet)
    end.

method_allowed(Method, Allow) ->
    lists:member(to_bin(Method), Allow).

normalize_amount_to_msat(Amount0, #state{ledger_unit = msat}) ->
    normalize_msat_value(Amount0);
normalize_amount_to_msat(Amount0, #state{ledger_unit = sat}) ->
    %% amount given in sats -> msat
    Sats = normalize_int(Amount0),
    Sats * 1000.

normalize_msat_value(Val) ->
    %% CLN sometimes returns {"amount_msat":"1234msat"} or integer-ish.
    case Val of
        I when is_integer(I) -> I;
        B when is_binary(B) ->
            case binary:split(B, <<"msat">>) of
                [NumBin | _] -> normalize_int(NumBin);
                _ -> normalize_int(B)
            end;
        _ ->
            normalize_int(Val)
    end.

normalize_int(V) when is_integer(V) -> V;
normalize_int(V) when is_binary(V) ->
    case catch binary_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> 0
    end;
normalize_int(V) when is_list(V) ->
    normalize_int(to_bin(V));
normalize_int(_) ->
    0.

maybe_estimate_intended_msat(undefined, _Max, _State) ->
    ok;
maybe_estimate_intended_msat(null, _Max, _State) ->
    ok;
maybe_estimate_intended_msat(Amount0, Max, State) ->
    Msat = normalize_amount_to_msat(Amount0, State),
    case Msat > Max of
        true -> {error, #{code => <<"LIMIT_EXCEEDED">>, message => <<"payment exceeds limit">>}};
        false -> ok
    end.

amount_for_contract_unit(AmountMsat, msat) -> AmountMsat;
amount_for_contract_unit(AmountMsat, sat) -> AmountMsat div 1000.

normalize_contract_int(R, msat) ->
    %% R extraction depends on your middleware response; adjust if needed.
    normalize_int(to_bin(io_lib:format("~p", [R])));
normalize_contract_int(R, sat) ->
    normalize_int(to_bin(io_lib:format("~p", [R]))) * 1000.

lower_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

lower_hex_ascii64(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(Bin))).

rand_subid(Prefix) ->
    R = crypto:strong_rand_bytes(4),
    <<Prefix/binary, "_", (binary:encode_hex(R))/binary>>.
