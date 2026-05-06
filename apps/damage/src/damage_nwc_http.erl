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
-export([ledger_call_admin/3]).
-export([ledger_events/2, ledger_events/3]).
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
            "/api/nwc/sessions",
            damage_nwc_http,
            #{action => sessions},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
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
relay_query(Relays0) ->
    Relays =
        case damage_nostr:normalize_relays(Relays0) of
            [] -> damage_nostr:configured_relays();
            Rs -> Rs
        end,
    string:join(
        [
            "relay=" ++ uri_string:quote(binary_to_list(maps:get(url, R)))
         || R <- Relays
        ],
        "&"
    ).
from_json_mint(Req0, State = #{action := mint}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),

    Owner = to_bin(maps:get(public_key, State)),
    Relays = mint_relays(Json),
    MaxSingleSat = mint_int(Json, [<<"max_single_sat">>, <<"max_single_sats">>], 10000),
    MaxTotalSat = mint_int(Json, [<<"max_total_sat">>, <<"max_total_sats">>], 100000),
    ExpiresHeight = mint_int(Json, [<<"expires_height">>, <<"expires_at_height">>], 0),

    Secret = crypto:strong_rand_bytes(32),
    SecretHex = lower_hex_hex(Secret),
    {ok, ClientPubBin} = nostrlib_schnorr:new_publickey(Secret),
    ClientPubHex = lower_hex_hex(ClientPubBin),

    Mode = ledger_mode(),
    MaxSingleMsat = MaxSingleSat * 1000,
    MaxTotalMsat = MaxTotalSat * 1000,
    WalletPubHex = ensure_hex_pubkey(nwc_wallet_pubhex()),
    NormalizedRelays = sanitize_nwc_relays(Relays),
    RelayQuery = relay_query(NormalizedRelays),
    NwcUri = build_nwc_uri(WalletPubHex, RelayQuery, SecretHex),

    ?LOG_INFO(
        "NWC mint auth owner=~p mode=~p client_pubkey=~p relays=~p",
        [Owner, Mode, ClientPubHex, NormalizedRelays]
    ),

    case resolve_user_ledger_ct(Owner) of
        {ok, LedgerCt0} ->
            LedgerCt = to_bin(LedgerCt0),
            case Mode of
                user_signed ->
                    %% Do not return a scannable URI for an unsigned registration
                    %% intent. A client/probe would treat it as usable while the
                    %% ledger policy may still reject it.
                    Intents = [
                        damage_ledger_intent:ledger_register_intent(
                            LedgerCt,
                            ClientPubHex,
                            <<"">>,
                            MaxSingleMsat,
                            MaxTotalMsat,
                            ExpiresHeight
                        )
                    ],
                    log_mint_not_usable(
                        Owner, ClientPubHex, Mode, {registration_requires_user_signature, LedgerCt}
                    ),
                    reply_json_stop(
                        409,
                        mint_not_usable_body(#{
                            status => <<"registration_required">>,
                            error => <<"NWC_REGISTRATION_REQUIRES_SIGNATURE">>,
                            owner => Owner,
                            ledger_ct => LedgerCt,
                            ledger_mode => atom_to_binary(Mode, utf8),
                            client_pubkey => ClientPubHex,
                            wallet_pubkey => WalletPubHex,
                            relays => NormalizedRelays,
                            intents => Intents
                        }),
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
                            ok = persist_nwc_session_index(
                                ClientPubHex,
                                Owner,
                                LedgerCt,
                                WalletPubHex,
                                NormalizedRelays,
                                #{
                                    max_single_msat => MaxSingleMsat,
                                    max_total_msat => MaxTotalMsat,
                                    expires_height => ExpiresHeight,
                                    revoked => false
                                }
                            ),
                            ok = notify_nwc_listener_relays(NormalizedRelays),
                            log_mint_usable(Owner, ClientPubHex, LedgerCt, Mode, NormalizedRelays),
                            reply_json_stop(
                                200,
                                mint_usable_body(#{
                                    owner => Owner,
                                    ledger_ct => LedgerCt,
                                    ledger_mode => atom_to_binary(Mode, utf8),
                                    client_pubkey => ClientPubHex,
                                    secret_hex => SecretHex,
                                    nwc_uri => NwcUri,
                                    wallet_pubkey => WalletPubHex,
                                    relays => NormalizedRelays,
                                    intents => []
                                }),
                                Req,
                                State
                            );
                        false ->
                            log_mint_not_usable(
                                Owner, ClientPubHex, Mode, {ledger_register_failed, RegisterResult}
                            ),
                            reply_json_stop(
                                400,
                                mint_not_usable_body(#{
                                    status => <<"error">>,
                                    error => <<"LEDGER_REGISTER_FAILED">>,
                                    owner => Owner,
                                    ledger_ct => LedgerCt,
                                    client_pubkey => ClientPubHex,
                                    wallet_pubkey => WalletPubHex,
                                    relays => NormalizedRelays,
                                    result => normalize_json(RegisterResult)
                                }),
                                Req,
                                State
                            )
                    end;
                operator_signed ->
                    log_mint_not_usable(
                        Owner, ClientPubHex, Mode, operator_mode_register_not_allowed
                    ),
                    reply_json_stop(
                        400,
                        mint_not_usable_body(#{
                            status => <<"error">>,
                            error => <<"REGISTER_NOT_ALLOWED_IN_OPERATOR_MODE">>,
                            owner => Owner,
                            ledger_ct => LedgerCt,
                            client_pubkey => ClientPubHex,
                            wallet_pubkey => WalletPubHex,
                            relays => NormalizedRelays
                        }),
                        Req,
                        State
                    )
            end;
        {error, Why} ->
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
                    ok = persist_nwc_session_index(
                        ClientPubHex,
                        Owner,
                        LedgerCt,
                        WalletPubHex,
                        NormalizedRelays,
                        #{
                            max_single_msat => MaxSingleMsat,
                            max_total_msat => MaxTotalMsat,
                            expires_height => ExpiresHeight,
                            revoked => false
                        }
                    ),
                    ok = notify_nwc_listener_relays(NormalizedRelays),
                    log_mint_usable(Owner, ClientPubHex, LedgerCt, Mode, NormalizedRelays),
                    reply_json_stop(
                        200,
                        mint_usable_body(#{
                            setup_executed => true,
                            owner => Owner,
                            account_registry_ct => RegistryCt,
                            ledger_ct => LedgerCt,
                            ledger_mode => atom_to_binary(Mode, utf8),
                            client_pubkey => ClientPubHex,
                            secret_hex => SecretHex,
                            nwc_uri => NwcUri,
                            wallet_pubkey => WalletPubHex,
                            relays => NormalizedRelays,
                            intents => []
                        }),
                        Req,
                        State
                    );
                {fallback_to_intents, SetupWhy} ->
                    case setup_intents_for_missing_ledger(Owner) of
                        {ok, RegistryCt, DeployAndRegisterIntents} ->
                            Intents =
                                DeployAndRegisterIntents ++
                                    [
                                        damage_ledger_intent:ledger_register_intent(
                                            <<"ct_TBD_FROM_DEPLOY">>,
                                            ClientPubHex,
                                            <<"">>,
                                            MaxSingleMsat,
                                            MaxTotalMsat,
                                            ExpiresHeight
                                        )
                                    ],
                            log_mint_not_usable(Owner, ClientPubHex, Mode, {Why, SetupWhy}),
                            reply_json_stop(
                                409,
                                mint_not_usable_body(#{
                                    status => <<"needs_ledger_setup">>,
                                    error => <<"NWC_LEDGER_SETUP_REQUIRED">>,
                                    reason => to_bin(io_lib:format("~p", [{Why, SetupWhy}])),
                                    owner => Owner,
                                    account_registry_ct => RegistryCt,
                                    ledger_mode => atom_to_binary(Mode, utf8),
                                    client_pubkey => ClientPubHex,
                                    wallet_pubkey => WalletPubHex,
                                    relays => NormalizedRelays,
                                    intents => Intents
                                }),
                                Req,
                                State
                            );
                        {error, SetupIntentWhy} ->
                            log_mint_not_usable(
                                Owner, ClientPubHex, Mode, {Why, SetupWhy, SetupIntentWhy}
                            ),
                            reply_json_stop(
                                400,
                                mint_not_usable_body(#{
                                    status => <<"error">>,
                                    error => <<"LEDGER_SETUP_INTENTS_FAILED">>,
                                    reason => to_bin(
                                        io_lib:format("~p", [{Why, SetupWhy, SetupIntentWhy}])
                                    ),
                                    owner => Owner,
                                    ledger_mode => atom_to_binary(Mode, utf8),
                                    client_pubkey => ClientPubHex,
                                    wallet_pubkey => WalletPubHex,
                                    relays => NormalizedRelays
                                }),
                                Req,
                                State
                            )
                    end
            end
    end.

build_nwc_uri(WalletPubHex, RelayQuery, SecretHex) ->
    iolist_to_binary([
        <<"nostr+walletconnect://">>,
        WalletPubHex,
        <<"?">>,
        RelayQuery,
        <<"&secret=">>,
        SecretHex
    ]).

mint_usable_body(Body0) ->
    Body0#{status => <<"ok">>, usable => true}.

mint_not_usable_body(Body0) ->
    Body0#{usable => false}.

log_mint_usable(Owner, ClientPubHex, LedgerCt, Mode, Relays) ->
    ?LOG_INFO(
        "NWC mint usable owner=~p client_pubkey=~p ledger_ct=~p mode=~p relays=~p",
        [Owner, ClientPubHex, LedgerCt, Mode, Relays]
    ).

log_mint_not_usable(Owner, ClientPubHex, Mode, Reason) ->
    ?LOG_WARNING(
        "NWC mint not usable yet owner=~p client_pubkey=~p mode=~p reason=~p",
        [Owner, ClientPubHex, Mode, Reason]
    ).

mint_relays(Json) ->
    DefaultRelays = nostr_pool:default_relays(#{}),
    case maps:get(<<"relays">>, Json, undefined) of
        Rs when is_list(Rs), Rs =/= [] -> Rs;
        _ ->
            case maps:get(<<"relay">>, Json, undefined) of
                R when is_binary(R); is_list(R) -> [R];
                _ -> DefaultRelays
            end
    end.

mint_int(Json, Keys, Default) ->
    case [maps:get(K, Json, undefined) || K <- Keys, maps:is_key(K, Json)] of
        [V | _] -> to_nonneg_int(V, Default);
        [] -> Default
    end.

to_nonneg_int(V, _Default) when is_integer(V), V >= 0 ->
    V;
to_nonneg_int(V, Default) when is_integer(V) ->
    Default;
to_nonneg_int(V, Default) when is_binary(V) ->
    try
        I = binary_to_integer(V),
        case I >= 0 of
            true -> I;
            false -> Default
        end
    catch
        _:_ -> Default
    end;
to_nonneg_int(V, Default) when is_list(V) ->
    try
        I = list_to_integer(V),
        case I >= 0 of
            true -> I;
            false -> Default
        end
    catch
        _:_ -> Default
    end;
to_nonneg_int(_, Default) ->
    Default.

sanitize_nwc_relays(Relays0) ->
    Relays1 = damage_nostr:normalize_relays(Relays0),
    Allowed = maps:from_list([{canonical_url(U), true} || U <- nwc_relay_allowlist()]),
    Relays2 =
        [
            R#{url => canonical_url(maps:get(url, R)), proxy => direct}
         || R <- Relays1,
            maps:is_key(canonical_url(maps:get(url, R)), Allowed)
        ],
    Relays3 =
        case Relays2 of
            [] -> [#{url => canonical_url(U), proxy => direct} || U <- nwc_relay_allowlist()];
            _ -> Relays2
        end,
    take_unique_relays(5, Relays3).

nwc_relay_allowlist() ->
    [
        <<"wss://nos.lol">>,
        <<"wss://offchain.pub">>,
        <<"wss://relay.primal.net">>,
        <<"wss://relay.damus.io">>,
        <<"wss://nostr-01.yakihonne.com">>
    ].

canonical_url(Url0) ->
    Url1 = to_bin(Url0),
    Url2 =
        case byte_size(Url1) of
            0 ->
                Url1;
            N ->
                case binary:at(Url1, N - 1) of
                    $/ -> binary:part(Url1, 0, N - 1);
                    _ -> Url1
                end
        end,
    list_to_binary(string:lowercase(binary_to_list(Url2))).

take_unique_relays(Max, Relays) ->
    take_unique_relays(Max, Relays, #{}, []).

take_unique_relays(0, _Relays, _Seen, Acc) ->
    lists:reverse(Acc);
take_unique_relays(_Max, [], _Seen, Acc) ->
    lists:reverse(Acc);
take_unique_relays(Max, [#{url := Url} = R | Rest], Seen, Acc) ->
    case maps:is_key(Url, Seen) of
        true -> take_unique_relays(Max, Rest, Seen, Acc);
        false -> take_unique_relays(Max - 1, Rest, Seen#{Url => true}, [R | Acc])
    end.
from_json(Req0, State = #{action := mint}) ->
    try
        from_json_mint(Req0, State)
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR(
                "NWC mint crashed class=~p reason=~p stack=~p state_keys=~p",
                [Class, Reason, Stack, maps:keys(State)]
            ),
            reply_json_stop(
                500,
                #{
                    status => <<"error">>,
                    error => <<"NWC_MINT_CRASH">>,
                    reason => to_bin(io_lib:format("~p:~p", [Class, Reason]))
                },
                Req0,
                State
            )
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
                    ok = mark_nwc_session_revoked(ClientPubHex),
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
                            ok = mark_nwc_session_revoked(ClientPubHex),
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
            case damage_nwc_wallet:ledger_balance_msat(Owner, LedgerCt, ClientPubHex) of
                {ok, BalanceMsat} ->
                    reply_json_stop(
                        200,
                        #{
                            status => <<"ok">>,
                            owner => Owner,
                            ledger_ct => LedgerCt,
                            client_pubkey => ClientPubHex,
                            source => <<"aeternity_middleware_contract_logs">>,
                            balance_msat => BalanceMsat,
                            balance_sat => BalanceMsat div 1000
                        },
                        Req,
                        State
                    );
                {error, WhyBalance} ->
                    reply_json_stop(
                        400,
                        #{
                            status => <<"error">>,
                            error => <<"LEDGER_BALANCE_FAILED">>,
                            owner => Owner,
                            ledger_ct => LedgerCt,
                            client_pubkey => ClientPubHex,
                            reason => to_bin(io_lib:format("~p", [WhyBalance]))
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
%% session history: reconstructed from public ledger events
%% -------------------------------------------------------------------
from_json(Req0, State = #{action := sessions}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = decode_json_body(Raw),
    Owner = to_bin(maps:get(public_key, State)),
    Limit = clamp_int(json_int(Json, [<<"limit">>], 200), 1, 1000),
    case resolve_user_ledger_ct(Owner) of
        {ok, LedgerCt0} ->
            LedgerCt = to_bin(LedgerCt0),
            case damage_nwc_ledger_events:sessions(LedgerCt, Limit) of
                {ok, Sessions} ->
                    AccountBalanceMsat = lists:sum([maps:get(balance_msat, S, 0) || S <- Sessions]),
                    reply_json_stop(
                        200,
                        #{
                            status => <<"ok">>,
                            owner => Owner,
                            ledger_ct => LedgerCt,
                            source => <<"aeternity_middleware_contract_logs">>,
                            account_balance_msat => AccountBalanceMsat,
                            account_balance_sat => AccountBalanceMsat div 1000,
                            sessions => Sessions
                        },
                        Req,
                        State
                    );
                {error, WhyEvents} ->
                    reply_json_stop(
                        502,
                        #{
                            status => <<"error">>,
                            error => <<"LEDGER_EVENTS_FAILED">>,
                            reason => to_bin(io_lib:format("~p", [WhyEvents])),
                            sessions => []
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
                    reason => to_bin(io_lib:format("~p", [Why])),
                    sessions => []
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
%% ---------------- JSON / event helpers ----------------
decode_json_body(<<>>) ->
    #{};
decode_json_body(Raw) ->
    case catch jsx:decode(Raw, [return_maps]) of
        {'EXIT', _} -> #{};
        Map when is_map(Map) -> Map;
        _ -> #{}
    end.

json_int(Map, Keys, Default) ->
    int_value(get_any(Map, Keys, Default), Default).

get_any(_Map, [], Default) ->
    Default;
get_any(Map, [K | Rest], Default) when is_map(Map) ->
    case maps:find(K, Map) of
        {ok, V} -> V;
        error -> get_any(Map, Rest, Default)
    end;
get_any(_Other, _Keys, Default) ->
    Default.

int_value(V, _Default) when is_integer(V) -> V;
int_value(V, _Default) when is_float(V) -> trunc(V);
int_value(V, Default) when is_binary(V) ->
    case catch binary_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> Default
    end;
int_value(V, Default) when is_list(V) ->
    case catch list_to_integer(V) of
        I when is_integer(I) -> I;
        _ -> Default
    end;
int_value(_, Default) ->
    Default.

clamp_int(I, Min, _Max) when is_integer(I), I < Min -> Min;
clamp_int(I, _Min, Max) when is_integer(I), I > Max -> Max;
clamp_int(I, _Min, _Max) when is_integer(I) -> I;
clamp_int(_, Min, _Max) -> Min.

ledger_events(LedgerCt, Limit) ->
    damage_nwc_ledger_events:ledger_events(LedgerCt, Limit).

ledger_events(LedgerCt, Limit, Direction) ->
    damage_nwc_ledger_events:ledger_events(LedgerCt, Limit, Direction).

mark_nwc_session_revoked(ClientPubHex) ->
    case erlang:function_exported(damage_nwc_session_index, mark_revoked, 1) of
        true -> damage_nwc_session_index:mark_revoked(ClientPubHex);
        false -> damage_nwc_session_index:delete(ClientPubHex)
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
    N = byte_size(Bin),
    case N of
        Size when Size > 12 ->
            Middle = Size - 12,
            <<Prefix:6/binary, _Skip:Middle/binary, Suffix:6/binary>> = Bin,
            <<Prefix/binary, "...", Suffix/binary>>;
        _ ->
            Bin
    end.

to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(L) when is_list(L) -> L.

lower_hex_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

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
    damage_ae:contract_path(damage, ?NWC_LEDGER_SRC_PATH).

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
%% When a user has no ledger registered yet:
%% Return {ok, RegistryCt, [deploy_intent, upsert_registry_intent]}
%%    or {error, Reason}
setup_intents_for_missing_ledger(OwnerAkBin) ->
    case damage_node_registry:ensure_account_registry(OwnerAkBin, <<"node">>) of
        {ok, _} ->
            case damage_node_registry:get_registry(OwnerAkBin) of
                #{"return_type" := "ok", "return_value" := {address, RegBin}} ->
                    RegistryCt = aeser_api_encoder:encode(contract_pubkey, RegBin),
                    ?LOG_DEBUG("get registry ~p", [RegistryCt]),

                    Deploy = damage_ledger_intent:deploy_ledger_intent(
                        OwnerAkBin,
                        <<"DamageNWCLedger">>
                    ),
                    Upsert = damage_ledger_intent:upsert_registry_intent(
                        to_bin(RegistryCt),
                        ?NWC_REGISTRY_NAME,
                        ?NWC_REGISTRY_NAME
                    ),

                    {ok, to_bin(RegistryCt), [Deploy, Upsert]};
                Other ->
                    {error, {cannot_get_registry_ct, Other}}
            end;
        {error, E1} ->
            {error, {cannot_ensure_account_registry, E1}}
    end.
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

persist_nwc_session_index(ClientPubHex, Owner, LedgerCt, WalletPubHex, Relays) ->
    persist_nwc_session_index(ClientPubHex, Owner, LedgerCt, WalletPubHex, Relays, #{}).

persist_nwc_session_index(ClientPubHex, Owner, LedgerCt, WalletPubHex, Relays, PolicyMeta0) ->
    PolicyMeta = maps:merge(
        #{revoked => false, max_single_msat => 0, max_total_msat => 0, expires_height => 0},
        PolicyMeta0
    ),
    damage_nwc_session_index:put(
        ClientPubHex,
        Owner,
        LedgerCt,
        #{
            wallet_pubkey => WalletPubHex,
            relays => Relays,
            created_at => erlang:system_time(second),
            policy => PolicyMeta,
            max_single_msat => maps:get(max_single_msat, PolicyMeta, 0),
            max_total_msat => maps:get(max_total_msat, PolicyMeta, 0),
            expires_height => maps:get(expires_height, PolicyMeta, 0)
        }
    ).
notify_nwc_listener_relays(Relays0) ->
    Relays = damage_nostr:normalize_relays(Relays0),
    case whereis(damage_nwc_listener) of
        undefined ->
            ?LOG_WARNING("damage_nwc_listener not running; relays persisted only: ~p", [Relays]),
            ok;
        _Pid ->
            damage_nwc_listener:add_relays(Relays),
            ok
    end.
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
