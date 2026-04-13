-module(damage_nwc_http).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2, content_types_provided/2]).
-export([from_json/2, to_json/2, allowed_methods/2, is_authorized/2]).
-export([trails/0]).
-export([resolve_user_ledger_ct/1]).
-export([ledger_src_path/0]).
-export([ledger_call_user_dry/4]).
-export([ledger_call_user/4]).
-export([
    migrate_user_ledger/1,
    migrate_user_ledger/2,
    upsert_registry_contract/4
]).

-export([test/0]).
-import(damage_utils, [to_bin/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["NWC"]).
-define(NWC_REGISTRY_NAME, <<"nwc_ledger">>).
-define(NWC_LEDGER_SRC_PATH, "contracts/nwc_ledger.aes").
-define(NWC_NOSTR_NSEC, damage_nostr_nsec).

trails() ->
    [
        trails:trail(
            "/api/nwc/mint",
            damage_nwc_http,
            #{action => mint},
            #{
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description =>
                            "Mint a Nostr Wallet Connect connection for authenticated user.",
                        produces => ["application/json"]
                    }
            }
        ),
        trails:trail(
            "/api/nwc/revoke",
            damage_nwc_http,
            #{action => revoke},
            #{
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Revoke an NWC connection.",
                        produces => ["application/json"]
                    }
            }
        ),
        trails:trail(
            "/api/nwc/ledger/balance",
            damage_nwc_http,
            #{action => ledger_balance},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/nwc/ledger/credit",
            damage_nwc_http,
            #{action => ledger_credit},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/nwc/topup_invoice",
            damage_nwc_http,
            #{action => topup_invoice},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/api/nwc/topup_status",
            damage_nwc_http,
            #{action => topup_status},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) -> {[<<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

%% --- Auth: reuse Damage token style (Bearer / cookie) similar to damage_http.erl ---

is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

to_json(Req, State) ->
    Body = maps:get(resp_body, State, #{}),
    {jsx:encode(Body), Req, State}.

%% -------------------------------------------------------------------
%% Execution mode
%%
%% user_signed:
%%   - server does NOT sign user ledger mutations (register/revoke/credit)
%%   - handler returns "intents" for a wallet to sign + broadcast
%%
%% server_signed:
%%   - server has custodial access to user's AE key in identity_server
%%   - handler executes ledger mutations immediately (no intents)
%%
%% operator_signed:
%%   - reserved for future: service key signs debits once operator is set.
%%   - mint/revoke/register/credit are admin-only; keep as intents unless server_signed.
%% -------------------------------------------------------------------

ledger_mode() ->
    %% default: user_signed
    case application:get_env(damage, nwc_ledger_mode) of
        {ok, <<"server_signed">>} -> server_signed;
        {ok, <<"operator_signed">>} -> operator_signed;
        {ok, server_signed} -> server_signed;
        {ok, operator_signed} -> operator_signed;
        _ -> server_signed
        %_ -> user_signed
    end.

from_json(Req0, State = #{action := mint}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),

    Owner = to_bin(maps:get(public_key, State)),
    DefaultRelays = nostr_pool:default_relays(#{}),
    Relays = maps:get(<<"relays">>, Json, DefaultRelays),
    MaxSingleSat = maps:get(<<"max_single_sat">>, Json, 10000),
    MaxTotalSat = maps:get(<<"max_total_sat">>, Json, 100000),
    ExpiresHeight = maps:get(<<"expires_height">>, Json, 0),

    Secret = crypto:strong_rand_bytes(32),
    SecretHex = lower_hex_hex(Secret),
    {ok, ClientPubBin} = nostrlib_schnorr:new_publickey(Secret),
    ClientPubHex = lower_hex_hex(ClientPubBin),

    case resolve_user_ledger_ct(Owner) of
        {ok, LedgerCt0} ->
            LedgerCt = to_bin(LedgerCt0),
            MaxSingleMsat = MaxSingleSat * 1000,
            MaxTotalMsat = MaxTotalSat * 1000,
            Mode = ledger_mode(),

            Intents =
                case Mode of
                    user_signed ->
                        [
                            damage_ledger_intent:ledger_register_intent(
                                LedgerCt,
                                ClientPubHex,
                                <<"">>,
                                MaxSingleMsat,
                                MaxTotalMsat,
                                ExpiresHeight
                            )
                        ];
                    _ ->
                        []
                end,

            WalletPubHex = ensure_hex_pubkey(nwc_wallet_pubhex()),
            Relay = pick_first_relay(Relays),
            NwcUri = iolist_to_binary([
                <<"nostr+walletconnect://">>,
                WalletPubHex,
                <<"?relay=">>,
                Relay,
                <<"&secret=">>,
                SecretHex
            ]),

            case Mode of
                user_signed ->
                    reply_json_stop(
                        200,
                        #{
                            status => <<"ok">>,
                            owner => Owner,
                            ledger_ct => LedgerCt,
                            ledger_mode => atom_to_binary(Mode, utf8),
                            client_pubkey => ClientPubHex,
                            secret_hex => SecretHex,
                            nwc_uri => NwcUri,
                            wallet_pubkey => WalletPubHex,
                            relay => Relay,
                            intents => Intents
                        },
                        Req,
                        State
                    );
                server_signed ->
                    RegisterResult = ledger_call_admin(
                        LedgerCt,
                        "register",
                        [
                            to_s(ClientPubHex),
                            integer_to_list(MaxSingleMsat),
                            integer_to_list(MaxTotalMsat),
                            integer_to_list(ExpiresHeight)
                        ]
                    ),
                    case ledger_call_ok(RegisterResult) of
                        true ->
                            reply_json_stop(
                                200,
                                #{
                                    status => <<"ok">>,
                                    owner => Owner,
                                    ledger_ct => LedgerCt,
                                    ledger_mode => atom_to_binary(Mode, utf8),
                                    client_pubkey => ClientPubHex,
                                    secret_hex => SecretHex,
                                    nwc_uri => NwcUri,
                                    wallet_pubkey => WalletPubHex,
                                    relay => Relay,
                                    intents => []
                                },
                                Req,
                                State
                            );
                        false ->
                            reply_json_stop(
                                400,
                                #{
                                    status => <<"error">>,
                                    error => <<"LEDGER_REGISTER_FAILED">>,
                                    owner => Owner,
                                    ledger_ct => LedgerCt,
                                    client_pubkey => ClientPubHex,
                                    result => normalize_json(RegisterResult)
                                },
                                Req,
                                State
                            )
                    end;
                operator_signed ->
                    reply_json_stop(
                        400,
                        #{
                            status => <<"error">>,
                            error => <<"REGISTER_NOT_ALLOWED_IN_OPERATOR_MODE">>,
                            owner => Owner,
                            ledger_ct => LedgerCt,
                            client_pubkey => ClientPubHex
                        },
                        Req,
                        State
                    )
            end;
        {error, Why} ->
            Mode = ledger_mode(),
            MaxSingleMsat = MaxSingleSat * 1000,
            MaxTotalMsat = MaxTotalSat * 1000,
            WalletPubHex = nwc_wallet_pubhex(),
            Relay = pick_first_relay(Relays),
            NwcUri =
                <<
                    "nostr+walletconnect://",
                    WalletPubHex/binary,
                    "?relay=",
                    Relay/binary,
                    "&secret=",
                    SecretHex/binary
                >>,
            case
                maybe_setup_missing_ledger(
                    Owner,
                    ClientPubHex,
                    MaxSingleMsat,
                    MaxTotalMsat,
                    ExpiresHeight
                )
            of
                {ok, RegistryCt, LedgerCt} ->
                    reply_json_stop(
                        200,
                        #{
                            status => <<"ok">>,
                            setup_executed => true,
                            owner => Owner,
                            account_registry_ct => RegistryCt,
                            ledger_ct => LedgerCt,
                            ledger_mode => atom_to_binary(Mode, utf8),
                            client_pubkey => ClientPubHex,
                            secret_hex => SecretHex,
                            nwc_uri => NwcUri,
                            wallet_pubkey => WalletPubHex,
                            relay => Relay,
                            intents => []
                        },
                        Req,
                        State
                    );
                {fallback_to_intents, SetupWhy} ->
                    {RegistryCt, DeployAndRegisterIntents} = setup_intents_for_missing_ledger(
                        Owner
                    ),
                    {stop,
                        reply_json(
                            200,
                            #{
                                status => <<"needs_ledger_setup">>,
                                reason => to_bin(io_lib:format("~p", [{Why, SetupWhy}])),
                                owner => Owner,
                                account_registry_ct => RegistryCt,
                                ledger_mode => atom_to_binary(Mode, utf8),
                                client_pubkey => ClientPubHex,
                                secret_hex => SecretHex,
                                nwc_uri => NwcUri,
                                wallet_pubkey => WalletPubHex,
                                relay => Relay,
                                intents => DeployAndRegisterIntents ++
                                    [
                                        damage_ledger_intent:ledger_register_intent(
                                            <<"ct_TBD_FROM_DEPLOY">>,
                                            ClientPubHex,
                                            <<"">>,
                                            MaxSingleMsat,
                                            MaxTotalMsat,
                                            ExpiresHeight
                                        )
                                    ]
                            },
                            Req
                        ),
                        State}
            end
    end;
%% -------------------------------------------------------------------
%% revoke
%% -------------------------------------------------------------------
from_json(Req0, State = #{action := revoke}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),

    Owner = to_bin(maps:get(public_key, State)),
    ClientPubHex = maps:get(<<"client_pubkey">>, Json),

    case resolve_user_ledger_ct(Owner) of
        {ok, LedgerCt0} ->
            LedgerCt = to_bin(LedgerCt0),
            Mode = ledger_mode(),

            Intents =
                case Mode of
                    user_signed ->
                        [damage_ledger_intent:ledger_revoke_intent(LedgerCt, ClientPubHex, <<"">>)];
                    _ ->
                        []
                end,

            case Mode of
                user_signed ->
                    reply_json_stop(
                        200,
                        #{
                            status => <<"ok">>,
                            revoked => false,
                            client_pubkey => ClientPubHex,
                            ledger_ct => LedgerCt,
                            intents => Intents
                        },
                        Req,
                        State
                    );
                server_signed ->
                    CallResult = ledger_call_admin(LedgerCt, "revoke", [to_s(ClientPubHex)]),
                    case ledger_call_ok(CallResult) of
                        true ->
                            reply_json_stop(
                                200,
                                #{
                                    status => <<"ok">>,
                                    revoked => true,
                                    client_pubkey => ClientPubHex,
                                    ledger_ct => LedgerCt,
                                    intents => []
                                },
                                Req,
                                State
                            );
                        false ->
                            reply_json_stop(
                                400,
                                #{
                                    status => <<"error">>,
                                    error => <<"LEDGER_REVOKE_FAILED">>,
                                    client_pubkey => ClientPubHex,
                                    ledger_ct => LedgerCt,
                                    result => normalize_json(CallResult)
                                },
                                Req,
                                State
                            )
                    end;
                operator_signed ->
                    reply_json_stop(
                        400,
                        #{
                            status => <<"error">>,
                            error => <<"REVOKE_NOT_ALLOWED_IN_OPERATOR_MODE">>,
                            client_pubkey => ClientPubHex,
                            ledger_ct => LedgerCt
                        },
                        Req,
                        State
                    )
            end;
        {error, Why} ->
            reply_json_stop(
                404,
                #{
                    status => <<"error">>,
                    error => <<"NO_LEDGER">>,
                    reason => to_bin(io_lib:format("~p", [Why]))
                },
                Req,
                State
            )
    end;
%% -------------------------------------------------------------------
%% ledger balance
%% -------------------------------------------------------------------
from_json(Req0, State = #{action := ledger_balance}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),

    Owner = to_bin(maps:get(public_key, State)),
    ClientPubHex = maps:get(<<"client_pubkey">>, Json),

    case resolve_user_ledger_ct(Owner) of
        {ok, LedgerCt0} ->
            LedgerCt = to_bin(LedgerCt0),
            CallResult = ledger_call_user(Owner, LedgerCt, "balance", [to_s(ClientPubHex)]),
            case ledger_call_ok(CallResult) of
                true ->
                    BalanceMsat = ledger_balance_msat_from_result(CallResult),
                    reply_json_stop(
                        200,
                        #{
                            status => <<"ok">>,
                            owner => Owner,
                            ledger_ct => LedgerCt,
                            client_pubkey => ClientPubHex,
                            balance_msat => BalanceMsat,
                            balance_sat => BalanceMsat div 1000
                        },
                        Req,
                        State
                    );
                false ->
                    reply_json_stop(
                        400,
                        #{
                            status => <<"error">>,
                            error => <<"LEDGER_BALANCE_FAILED">>,
                            owner => Owner,
                            ledger_ct => LedgerCt,
                            client_pubkey => ClientPubHex,
                            result => normalize_json(CallResult)
                        },
                        Req,
                        State
                    )
            end;
        {error, Why} ->
            reply_json_stop(
                404,
                #{
                    status => <<"error">>,
                    error => <<"NO_LEDGER">>,
                    reason => to_bin(io_lib:format("~p", [Why]))
                },
                Req,
                State
            )
    end;
%% -------------------------------------------------------------------
%% ledger credit (admin-only endpoint)
%% -------------------------------------------------------------------
from_json(Req0, State = #{action := ledger_credit}) ->
    from_json_ledger_credit(Req0, State);
from_json(Req0, State = #{action := topup_invoice}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),

    Owner = to_bin(maps:get(public_key, State)),
    ClientPubHex = maps:get(<<"client_pubkey">>, Json),
    AmountSat = maps:get(<<"amount_sat">>, Json, 0),
    AmountMsat = AmountSat * 1000,

    case resolve_user_ledger_ct(Owner) of
        {ok, LedgerCt0} ->
            LedgerCt = to_bin(LedgerCt0),
            case damage_nwc_wallet:ledger_policy(Owner, LedgerCt, ClientPubHex) of
                {ok, _Policy} ->
                    Label = make_topup_label(Owner, ClientPubHex, AmountSat),
                    Desc = <<"Damage NWC top-up">>,
                    case cln:create_invoice(AmountMsat, Desc, Label) of
                        #{bolt11 := Bolt11, payment_hash := PaymentHash} ->
                            ok = damage_nwc_topup_store:put(#{
                                payment_hash => to_bin(PaymentHash),
                                owner => Owner,
                                ledger_ct => LedgerCt,
                                client_pubkey => ClientPubHex,
                                amount_msat => AmountMsat,
                                amount_sat => AmountSat,
                                label => Label,
                                status => pending,
                                created_at => erlang:system_time(second)
                            }),
                            _ = damage_nwc_invoice_watch_sup:start_child(Label),
                            reply_json_stop(
                                200,
                                #{
                                    status => <<"ok">>,
                                    topup => #{
                                        invoice => to_bin(Bolt11),
                                        payment_hash => to_bin(PaymentHash),
                                        amount_sat => AmountSat,
                                        amount_msat => AmountMsat,
                                        client_pubkey => ClientPubHex
                                    }
                                },
                                Req,
                                State
                            );
                        {error, Why} ->
                            reply_json_stop(
                                400,
                                #{
                                    status => <<"error">>,
                                    error => <<"INVOICE_CREATE_FAILED">>,
                                    reason => to_bin(io_lib:format("~p", [Why]))
                                },
                                Req,
                                State
                            )
                    end;
                {error, Why} ->
                    reply_json_stop(
                        404,
                        #{
                            status => <<"error">>,
                            error => <<"UNKNOWN_CLIENT">>,
                            reason => to_bin(io_lib:format("~p", [Why]))
                        },
                        Req,
                        State
                    )
            end;
        {error, Why} ->
            reply_json_stop(
                404,
                #{
                    status => <<"error">>,
                    error => <<"NO_LEDGER">>,
                    reason => to_bin(io_lib:format("~p", [Why]))
                },
                Req,
                State
            )
    end;
from_json(Req0, State = #{action := topup_status}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),
    PaymentHash = maps:get(<<"payment_hash">>, Json),
    case damage_nwc_topup_store:get(PaymentHash) of
        {ok, Topup} ->
            reply_json_stop(
                200,
                #{
                    status => <<"ok">>,
                    topup => Topup
                },
                Req,
                State
            );
        {error, not_found} ->
            reply_json_stop(
                404,
                #{
                    status => <<"error">>,
                    error => <<"NOT_FOUND">>
                },
                Req,
                State
            )
    end.

from_json_ledger_credit(Req0, State) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),

    Owner = to_bin(maps:get(public_key, State)),

    case steps_utils:is_admin(Owner) of
        false ->
            reply_json_stop(
                403,
                #{
                    status => <<"error">>,
                    error => <<"FORBIDDEN">>,
                    reason => <<"not_admin">>
                },
                Req,
                State
            );
        true ->
            ClientPubHex = maps:get(<<"client_pubkey">>, Json),
            AmountSat = maps:get(<<"amount_sat">>, Json, 0),
            Ref = maps:get(<<"ref">>, Json, <<"">>),
            Meta = maps:get(<<"meta">>, Json, <<"{}">>),

            AmountMsat = AmountSat * 1000,

            case resolve_user_ledger_ct(Owner) of
                {ok, LedgerCt0} ->
                    LedgerCt = to_bin(LedgerCt0),
                    Mode = ledger_mode(),

                    Intents =
                        case Mode of
                            user_signed ->
                                [
                                    damage_ledger_intent:ledger_credit_intent(
                                        LedgerCt, ClientPubHex, AmountMsat, Ref, Meta, <<"">>
                                    )
                                ];
                            _ ->
                                []
                        end,

                    case Mode of
                        user_signed ->
                            reply_json_stop(
                                200,
                                #{
                                    status => <<"ok">>,
                                    owner => Owner,
                                    ledger_ct => LedgerCt,
                                    client_pubkey => ClientPubHex,
                                    credited_sat => AmountSat,
                                    credited_msat => AmountMsat,
                                    intents => Intents
                                },
                                Req,
                                State
                            );
                        server_signed ->
                            CallResult = ledger_call_admin(
                                LedgerCt,
                                "credit",
                                [
                                    to_s(ClientPubHex),
                                    integer_to_list(AmountMsat),
                                    to_s(Ref),
                                    to_s(Meta)
                                ]
                            ),
                            case ledger_call_ok(CallResult) of
                                true ->
                                    reply_json_stop(
                                        200,
                                        #{
                                            status => <<"ok">>,
                                            owner => Owner,
                                            ledger_ct => LedgerCt,
                                            client_pubkey => ClientPubHex,
                                            credited_sat => AmountSat,
                                            credited_msat => AmountMsat,
                                            intents => []
                                        },
                                        Req,
                                        State
                                    );
                                false ->
                                    reply_json_stop(
                                        400,
                                        #{
                                            status => <<"error">>,
                                            error => <<"LEDGER_CREDIT_FAILED">>,
                                            owner => Owner,
                                            ledger_ct => LedgerCt,
                                            client_pubkey => ClientPubHex,
                                            requested_sat => AmountSat,
                                            requested_msat => AmountMsat,
                                            result => normalize_json(CallResult)
                                        },
                                        Req,
                                        State
                                    )
                            end;
                        operator_signed ->
                            reply_json_stop(
                                400,
                                #{
                                    status => <<"error">>,
                                    error => <<"CREDIT_NOT_ALLOWED_IN_OPERATOR_MODE">>,
                                    owner => Owner,
                                    ledger_ct => LedgerCt,
                                    client_pubkey => ClientPubHex
                                },
                                Req,
                                State
                            )
                    end;
                {error, Why} ->
                    reply_json_stop(
                        404,
                        #{
                            status => <<"error">>,
                            error => <<"NO_LEDGER">>,
                            reason => to_bin(io_lib:format("~p", [Why]))
                        },
                        Req,
                        State
                    )
            end
    end.
%% ---------------- helpers ----------------
reply_json(Status, Body, Req) ->
    cowboy_req:reply(
        Status,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(normalize_json(Body)),
        Req
    ).

reply_json_stop(Status, Body, Req, State) ->
    {stop, reply_json(Status, Body, Req), State}.

normalize_json(Map) when is_map(Map) ->
    maps:from_list([{to_bin(K), normalize_json(V)} || {K, V} <- maps:to_list(Map)]);
normalize_json(List) when is_list(List) ->
    [normalize_json(V) || V <- List];
normalize_json(V) ->
    V.

ledger_balance_msat_from_result(#{<<"return_value">> := V}) ->
    ledger_balance_msat_from_result(V);
ledger_balance_msat_from_result(#{"return_value" := V}) ->
    ledger_balance_msat_from_result(V);
ledger_balance_msat_from_result(V) when is_integer(V) ->
    V;
ledger_balance_msat_from_result({Balance}) when is_integer(Balance) ->
    Balance;
ledger_balance_msat_from_result({variant, [0, 1], 1, {Balance}}) when is_integer(Balance) ->
    Balance;
ledger_balance_msat_from_result({variant, [0, 1], 0, {}}) ->
    0;
ledger_balance_msat_from_result(Other) ->
    ?LOG_WARNING("Unexpected ledger balance result shape ~p", [Other]),
    0.

-spec make_topup_label(binary(), binary(), integer()) -> binary().
make_topup_label(Owner, ClientPubHex, AmountSat) ->
    Ts = integer_to_binary(erlang:system_time(millisecond)),
    Rand = base64:encode(crypto:strong_rand_bytes(6)),
    <<
        "nwc_topup:",
        (short(Owner))/binary,
        ":",
        (short(ClientPubHex))/binary,
        ":",
        (integer_to_binary(AmountSat))/binary,
        ":",
        Ts/binary,
        ":",
        Rand/binary
    >>.
short(Bin) when is_binary(Bin) ->
    case byte_size(Bin) of
        N when N > 12 ->
            <<Prefix:6/binary, "...", Suffix:6/binary>> = Bin,
            <<Prefix/binary, Suffix/binary>>;
        _ ->
            Bin
    end.

to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(L) when is_list(L) -> L.

lower_hex_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

pick_first_relay([R | _]) when is_binary(R) ->
    R;
pick_first_relay([R | _]) when is_list(R) ->
    unicode:characters_to_binary(R);
pick_first_relay(R) when is_binary(R) ->
    R;
pick_first_relay(R) when is_list(R) ->
    unicode:characters_to_binary(R);
pick_first_relay(_) ->
    {ok, Host} = application:get_env(damage, nostr_relay),
    HostBin = list_to_binary(Host),
    <<"wss://", HostBin/binary>>.

resolve_user_ledger_ct(OwnerAkBin0) ->
    OwnerAkBin = to_bin(OwnerAkBin0),
    case secret_user_ledger_ct(OwnerAkBin) of
        {ok, CtId} ->
            {ok, CtId};
        error ->
            case damage_node_registry:ensure_account_registry(OwnerAkBin, <<"node">>) of
                {ok, _} ->
                    resolve_user_ledger_ct_from_registry(OwnerAkBin);
                {error, Why} ->
                    {error, {ensure_account_registry_failed, Why}}
            end
    end.

resolve_user_ledger_ct_from_registry(OwnerAkBin) ->
    case damage_node_registry:get_registry(OwnerAkBin) of
        #{"return_type" := "ok", "return_value" := {address, RegBin}} ->
            RegistryCt = aeser_api_encoder:encode(contract_pubkey, RegBin),
            case account_registry_reader_keypair(OwnerAkBin) of
                {ok, KP} ->
                    case account_registry:get_contract(KP, RegistryCt, ?NWC_REGISTRY_NAME) of
                        {ok, LedgerCt0} ->
                            LedgerCt = to_bin(LedgerCt0),
                            ok = persist_user_ledger_ct(OwnerAkBin, LedgerCt),
                            {ok, LedgerCt};
                        {error, Reason} ->
                            {error, {ledger_not_found_in_account_registry, RegistryCt, Reason}}
                    end;
                {error, Why} ->
                    {error, {account_registry_reader_keypair_failed, Why}}
            end;
        #{"return_type" := "revert", "return_value" := Msg} ->
            {error, {node_registry_revert, Msg}};
        Other ->
            {error, {node_registry_bad_reply, Other}}
    end.
%% Select how we read from AccountRegistry based on execution mode.
%% - server_signed: prefer user's custodial keypair
%% - user_signed/operator_signed: use service keypair for read-only lookups
-spec account_registry_reader_keypair(binary()) -> {ok, map()} | {error, term()}.
account_registry_reader_keypair(OwnerAkBin) ->
    case maybe_user_keypair_from_owner(OwnerAkBin) of
        {ok, KP} ->
            {ok, KP};
        {error, Why} ->
            case ledger_mode() of
                user_signed ->
                    {error, {no_user_registry_reader_key, Why}};
                server_signed ->
                    {error, {no_user_registry_reader_key, Why}};
                operator_signed ->
                    {error, {no_user_registry_reader_key, Why}}
            end
    end.

-spec maybe_user_keypair_from_owner(binary()) -> {ok, map()} | {error, term()}.
maybe_user_keypair_from_owner(OwnerAkBin) ->
    case catch identity_server:get_account(OwnerAkBin) of
        #{public_key := Pub0, private_key := Priv} when Priv =/= undefined ->
            {ok, #{public_key => to_bin(Pub0), private_key => Priv}};
        notfound ->
            {error, notfound};
        {'EXIT', Why} ->
            {error, Why};
        Other ->
            {error, {unexpected_identity_result, Other}}
    end.
user_keypair_from_owner(OwnerAkBin) ->
    %% Custodial path: user key is present server-side.
    %% Future noncustodial: this is the seam where you detect "no key" and return intents only.
    #{public_key := Pub0, private_key := Priv} = identity_server:get_account(OwnerAkBin),
    #{public_key => to_bin(Pub0), private_key => Priv}.

ledger_src_path() ->
    damage_ae:contract_path(?NWC_LEDGER_SRC_PATH).

ledger_call_admin(LedgerCt, Fun, Args) ->
    damage_ae:contract_call(
        secrets:node_keypair(),
        to_s(LedgerCt),
        ledger_src_path(),
        Fun,
        Args
    ).

ledger_call_ok(#{<<"return_type">> := <<"ok">>}) ->
    true;
ledger_call_ok(#{"return_type" := "ok"}) ->
    true;
ledger_call_ok(_) ->
    false.
ledger_call_user(OwnerAkBin, LedgerCt, Fun, Args) ->
    KP = user_keypair_from_owner(OwnerAkBin),
    AeAccount = maps:get(public_key, KP),
    PrivateKey = maps:get(private_key, KP),
    damage_ae:set_private_key(to_s(AeAccount), PrivateKey),
    ?LOG_DEBUG("ledger_call_user ~p, ~p ~p ~p ~p", [
        AeAccount,
        to_s(LedgerCt),
        ledger_src_path(),
        Fun,
        Args
    ]),
    damage_ae:contract_call_payfor_user(
        AeAccount,
        to_s(LedgerCt),
        ledger_src_path(),
        Fun,
        Args
    ).

ledger_call_user_dry(OwnerAkBin, LedgerCt, Fun, Args) ->
    KP = user_keypair_from_owner(OwnerAkBin),
    damage_ae:contract_call_dry(
        KP,
        to_s(LedgerCt),
        ledger_src_path(),
        Fun,
        Args
    ).

%% When a user has no ledger registered yet:
%% Return (account_registry_ct, [deploy_intent, upsert_registry_intent])
setup_intents_for_missing_ledger(OwnerAkBin) ->
    %% Ensure registry exists and fetch per-user registry ct
    case damage_node_registry:ensure_account_registry(OwnerAkBin, <<"node">>) of
        {ok, _} -> ok;
        {error, E1} -> throw({cannot_ensure_account_registry, E1})
    end,

    RegistryCt =
        case damage_node_registry:get_registry(OwnerAkBin) of
            #{"return_type" := "ok", "return_value" := {address, RegBin}} ->
                aeser_api_encoder:encode(contract_pubkey, RegBin);
            Other ->
                throw({cannot_get_registry_ct, Other})
        end,
    ?LOG_DEBUG("get registry ~p", [RegistryCt]),

    Deploy = damage_ledger_intent:deploy_ledger_intent(OwnerAkBin, <<"DamageNWCLedger">>),
    Upsert = damage_ledger_intent:upsert_registry_intent(
        to_bin(RegistryCt), ?NWC_REGISTRY_NAME, ?NWC_REGISTRY_NAME
    ),
    {to_bin(RegistryCt), [Deploy, Upsert]}.

nwc_wallet_pubhex() ->
    Nsec =
        case secrets:retrieve_decrypt(?NWC_NOSTR_NSEC) of
            {ok, Existing} ->
                Existing;
            _ ->
                %% Generate + persist new nsec
                NewNsec = damage_nostr:generate_nsec(),
                ok = secrets:encrypt_store(?NWC_NOSTR_NSEC, NewNsec),
                ?LOG_WARNING("Generated new NWC wallet nsec - first time setup"),
                NewNsec
        end,
    {PublicKey, _PrivateKey} = damage_nostr:nsec_to_npub(Nsec),
    ensure_hex_pubkey(PublicKey).

ensure_hex_pubkey(Bin) when is_binary(Bin) ->
    case is_hex_64(Bin) of
        true -> Bin;
        false -> lower_hex_hex(Bin)
    end;
ensure_hex_pubkey(List) when is_list(List) ->
    ensure_hex_pubkey(unicode:characters_to_binary(List)).

is_hex_64(B) when is_binary(B), byte_size(B) =:= 64 ->
    re:run(B, <<"^[0-9a-fA-F]{64}$">>, [{capture, none}]) =:= match;
is_hex_64(_) ->
    false.
%% Try to fully set up missing ledger if custodial private key is available.
%% On success:
%%   - ensures AccountRegistry exists
%%   - deploys ledger
%%   - upserts nwc_ledger -> LedgerCt
%%   - registers client policy in ledger
%%
%% Falls back to intents if any custodial prerequisite is missing.
-spec maybe_setup_missing_ledger(binary(), binary(), integer(), integer(), integer()) ->
    {ok, binary(), binary()} | {fallback_to_intents, term()}.
maybe_setup_missing_ledger(OwnerAkBin, ClientPubHex, MaxSingleMsat, MaxTotalMsat, ExpiresHeight) ->
    case maybe_user_keypair_from_owner(OwnerAkBin) of
        {ok, KP} ->
            case ensure_registry_ct(OwnerAkBin) of
                {ok, RegistryCt} ->
                    case
                        deploy_and_register_user_ledger(
                            OwnerAkBin,
                            KP,
                            RegistryCt,
                            ClientPubHex,
                            MaxSingleMsat,
                            MaxTotalMsat,
                            ExpiresHeight
                        )
                    of
                        {ok, LedgerCt} ->
                            {ok, RegistryCt, LedgerCt};
                        {error, Why} ->
                            {fallback_to_intents, {deploy_and_register_user_ledger_failed, Why}}
                    end;
                {error, Why} ->
                    {fallback_to_intents, {ensure_registry_ct_failed, Why}}
            end;
        {error, Why} ->
            {fallback_to_intents, {no_custodial_key, Why}}
    end.

-spec ensure_registry_ct(binary()) -> {ok, binary()} | {error, term()}.
ensure_registry_ct(OwnerAkBin) ->
    case damage_node_registry:ensure_account_registry(OwnerAkBin, <<"node">>) of
        {ok, RegistryCt} ->
            {ok, to_bin(RegistryCt)};
        {error, Why} ->
            {error, Why}
    end.

-spec deploy_and_register_user_ledger(
    binary(), map(), binary(), binary(), integer(), integer(), integer()
) ->
    {ok, binary()} | {error, term()}.
deploy_and_register_user_ledger(
    OwnerAkBin, KP, RegistryCt0, ClientPubHex, MaxSingleMsat, MaxTotalMsat, ExpiresHeight
) ->
    RegistryCt = to_bin(RegistryCt0),

    #{public_key := NodePublicKey, private_key := _PrivateKey} = secrets:node_keypair(),
    case damage_ae:contract_deploy_for(KP, ledger_src_path(), [NodePublicKey]) of
        #{"contract_id" := LedgerCt0} ->
            LedgerCt = to_bin(LedgerCt0),
            case upsert_registry_contract(KP, RegistryCt, ?NWC_REGISTRY_NAME, LedgerCt) of
                {ok, true} ->
                    ok = persist_user_ledger_ct(OwnerAkBin, LedgerCt),
                    case
                        ledger_call_admin(
                            LedgerCt,
                            "register",
                            [
                                to_s(ClientPubHex),
                                integer_to_list(MaxSingleMsat),
                                integer_to_list(MaxTotalMsat),
                                integer_to_list(ExpiresHeight)
                            ]
                        )
                    of
                        Result when is_map(Result) ->
                            case ledger_call_ok(Result) of
                                true ->
                                    {ok, LedgerCt};
                                false ->
                                    {error, {ledger_register_failed, Result}}
                            end;
                        Other ->
                            {error, {ledger_register_failed, Other}}
                    end;
                {error, Why} ->
                    {error, {registry_upsert_failed, Why}}
            end;
        #{"return_type" := "revert"} = Info ->
            {error, {ledger_deploy_revert, Info}};
        Other ->
            {error, {ledger_deploy_failed, Other}}
    end.

-spec upsert_registry_contract(map(), binary(), binary(), binary()) ->
    {ok, true} | {error, term()}.
upsert_registry_contract(KP, RegistryCt, Name, ContractCt) ->
    case account_registry:update_contract(KP, RegistryCt, Name, ContractCt) of
        {ok, true} ->
            {ok, true};
        {error,
            {unexpected_return_type, "revert", #{"return_value" := <<"Contract name not found">>}}} ->
            account_registry:register_contract(KP, RegistryCt, Name, ContractCt);
        {error,
            {unexpected_return_type, <<"revert">>, #{
                "return_value" := <<"Contract name not found">>
            }}} ->
            account_registry:register_contract(KP, RegistryCt, Name, ContractCt);
        Other ->
            Other
    end.

%% -------------------------------------------------------------------
%% Shell helper: deploy a new ledger and update AccountRegistry
%%
%% migrate_user_ledger(OwnerAkBin) ->
%%   - ensures the user's AccountRegistry exists
%%   - resolves current nwc_ledger (best effort)
%%   - deploys a fresh DamageNWCLedger with the user's custodial key
%%   - updates AccountRegistry: nwc_ledger -> NewLedgerCt
%%
%% Returns:
%%   {ok, #{
%%      owner => OwnerAk,
%%      registry_ct => RegistryCt,
%%      old_ledger_ct => OldLedgerCt | undefined,
%%      new_ledger_ct => NewLedgerCt
%%   }}
%%
%% Note:
%%   This migrates the registry pointer to a fresh contract.
%%   It does NOT copy old per-client balances/policies, because the ledger
%%   contract is keyed by client pubkey and not enumerable on-chain.
%% -------------------------------------------------------------------

-spec migrate_user_ledger(binary()) -> {ok, map()} | {error, term()}.
migrate_user_ledger(OwnerAkBin) ->
    migrate_user_ledger(OwnerAkBin, #{}).

-spec migrate_user_ledger(binary(), map()) -> {ok, map()} | {error, term()}.
migrate_user_ledger(OwnerAkBin0, Opts) ->
    OwnerAkBin = to_bin(OwnerAkBin0),

    case maybe_user_keypair_from_owner(OwnerAkBin) of
        {ok, KP} ->
            case ensure_registry_ct(OwnerAkBin) of
                {ok, RegistryCt0} ->
                    RegistryCt = to_bin(RegistryCt0),

                    OldLedgerCt =
                        case resolve_user_ledger_ct(OwnerAkBin) of
                            {ok, Ct0} -> to_bin(Ct0);
                            {error, _} -> undefined
                        end,

                    InitAdmin =
                        case maps:get(admin_ak, Opts, undefined) of
                            undefined ->
                                maps:get(public_key, KP);
                            V ->
                                to_bin(V)
                        end,

                    case damage_ae:contract_deploy_for(KP, ledger_src_path(), [InitAdmin]) of
                        #{"contract_id" := NewLedgerCt0} ->
                            NewLedgerCt = to_bin(NewLedgerCt0),

                            case
                                upsert_registry_contract(
                                    KP,
                                    RegistryCt,
                                    ?NWC_REGISTRY_NAME,
                                    NewLedgerCt
                                )
                            of
                                {ok, true} ->
                                    maybe_set_operator_after_migration(
                                        OwnerAkBin,
                                        NewLedgerCt,
                                        Opts
                                    ),
                                    {ok, #{
                                        owner => OwnerAkBin,
                                        registry_ct => RegistryCt,
                                        old_ledger_ct => OldLedgerCt,
                                        new_ledger_ct => NewLedgerCt
                                    }};
                                {error, Why} ->
                                    {error, {registry_upsert_failed, Why}};
                                Other ->
                                    {error, {registry_upsert_bad_reply, Other}}
                            end;
                        #{"return_type" := "revert"} = Info ->
                            {error, {ledger_deploy_revert, Info}};
                        Other ->
                            {error, {ledger_deploy_failed, Other}}
                    end;
                {error, Why} ->
                    {error, {ensure_registry_ct_failed, Why}}
            end;
        {error, Why} ->
            {error, {no_custodial_key, Why}}
    end.

-spec maybe_set_operator_after_migration(binary(), binary(), map()) -> ok | {error, term()}.
maybe_set_operator_after_migration(OwnerAkBin, NewLedgerCt, Opts) ->
    case maps:get(operator_ak, Opts, undefined) of
        undefined ->
            ok;
        OperatorAk0 ->
            OperatorAk = to_bin(OperatorAk0),
            case
                ledger_call_user(
                    OwnerAkBin,
                    NewLedgerCt,
                    "set_operator",
                    [#{<<"Some">> => binary_to_list(OperatorAk)}]
                )
            of
                #{"return_type" := "ok"} ->
                    ok;
                Other ->
                    {error, {set_operator_failed, Other}}
            end
    end.

user_registry_contract_secret_key(OwnerAkBin) ->
    binary_to_list(
      <<"nwc_ledger_ct__", (base64:encode(crypto:hash(sha256, OwnerAkBin)))/binary>>
     ).

secret_user_ledger_ct(OwnerAkBin) ->
    Key = user_registry_contract_secret_key(OwnerAkBin),
    case secrets:retrieve_decrypt(Key) of
        {ok, <<"ct_", _/binary>> = CtId} ->
            {ok, CtId};
        {ok, CtId} when is_list(CtId) ->
            {ok, list_to_binary(CtId)};
        _ ->
            error
    end.

persist_user_ledger_ct(OwnerAkBin, <<"ct_", _/binary>> = CtId) ->
    Key = user_registry_contract_secret_key(OwnerAkBin),
    ok = secrets:encrypt_store(Key, CtId).
test() ->
    Owner = "ct_4SUjjufRpMD6KmhZwX3sAdih2FTV1Qry11TJpEGdmrdPh8bdy",
    LedgerCt =
        "/home/steven/DamageInc/DamageBDD/_build/default/lib/damage/priv/contracts/nwc_ledger.aes",
    ClientPubHex = "e9c3305715c9fabdbab6c2fcbe027bd78e056a97cbab5c85e106b9eaa80b2f2a",
    MaxSingleMsat =
        10000,
    MaxTotalMsat = 50000,
    ExpiresHeight = 0,
    _Results = ledger_call_user(
        Owner,
        LedgerCt,
        "register",
        [
            to_s(ClientPubHex),
            integer_to_list(MaxSingleMsat),
            integer_to_list(MaxTotalMsat),
            integer_to_list(ExpiresHeight)
        ]
    ).
