-module(damage_nwc_http).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2, content_types_provided/2]).
-export([from_json/2, to_json/2, allowed_methods/2, is_authorized/2]).
-export([trails/0]).
-export([resolve_user_ledger_ct/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["NWC"]).
-define(NWC_REGISTRY_NAME, <<"nwc_ledger">>).
-define(NWC_LEDGER_SRC_PATH, "contracts/DamageNWCLedger.aes").

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
        _ -> user_signed
    end.

%% -------------------------------------------------------------------
%% mint
%% -------------------------------------------------------------------
from_json(Req0, State = #{action := mint}) ->
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),

    %% owner comes from auth (same pattern used throughout Damage)
    Owner = to_bin(maps:get(public_key, State)),

    DefaultRelays = nostr_pool:default_relays(#{}),
    Relays = maps:get(<<"relays">>, Json, DefaultRelays),

    %% Ledger policy (contract uses max_total_msat + expires_height)
    MaxSingleSat = maps:get(<<"max_single_sat">>, Json, 10000),
    MaxTotalSat = maps:get(<<"max_total_sat">>, Json, 100000),
    ExpiresHeight = maps:get(<<"expires_height">>, Json, 0),

    %% Generate client secret (private key) and pubkey (NWC client keypair)
    Secret = crypto:strong_rand_bytes(32),
    SecretHex = lower_hex_hex(Secret),
    {ok, ClientPubBin} = nostrlib_schnorr:new_publickey(Secret),
    ClientPubHex = lower_hex_hex(ClientPubBin),

    %% Resolve user's ledger ct_id via AccountRegistry
    case resolve_user_ledger_ct(Owner) of
        {ok, LedgerCt0} ->
            LedgerCt = to_bin(LedgerCt0),

            MaxSingleMsat = MaxSingleSat * 1000,
            MaxTotalMsat = MaxTotalSat * 1000,

            Mode = ledger_mode(),

            %% Register client_pubkey policy in ledger (admin-only call)
            %% - user_signed: return intent
            %% - server_signed: execute now
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

            case Mode of
                user_signed ->
                    ok;
                server_signed ->
                    _ = ledger_call_user(
                        Owner,
                        LedgerCt,
                        "register",
                        [
                            to_s(ClientPubHex),
                            integer_to_list(MaxSingleMsat),
                            integer_to_list(MaxTotalMsat),
                            integer_to_list(ExpiresHeight)
                        ]
                    ),
                    ok;
                operator_signed ->
                    %% register is admin-only; do not execute as operator
                    ok
            end,

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

            Resp = #{
                status => <<"ok">>,
                owner => Owner,
                ledger_ct => LedgerCt,
                ledger_mode => atom_to_binary(Mode, utf8),

                client_pubkey => ClientPubHex,
                %% only show once
                secret_hex => SecretHex,
                nwc_uri => NwcUri,
                wallet_pubkey => WalletPubHex,
                relay => Relay,

                intents => Intents
            },
            {true, Req, State#{resp_body => Resp}};
        {error, Why} ->
            %% If no ledger is registered yet, return deploy+registry intents so wallet can set up.
            %% (We still return the freshly minted NWC secret/pubkey so the UI can continue.)
            Mode = ledger_mode(),
            {RegistryCt, DeployAndRegisterIntents} = setup_intents_for_missing_ledger(Owner),

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

            %% Also include the ledger register intent (it will reference placeholder ct until deploy completes).
            %% UI should substitute returned deploy result ct_id into registry+ledger intents.
            MaxSingleMsat = MaxSingleSat * 1000,
            MaxTotalMsat = MaxTotalSat * 1000,

            Resp = #{
                status => <<"needs_ledger_setup">>,
                reason => to_bin(io_lib:format("~p", [Why])),
                owner => Owner,
                account_registry_ct => RegistryCt,
                ledger_mode => atom_to_binary(Mode, utf8),

                client_pubkey => ClientPubHex,
                secret_hex => SecretHex,
                nwc_uri => NwcUri,
                wallet_pubkey => WalletPubHex,
                relay => Relay,

                %% Intents returned for wallet signing:
                %% - deploy ledger (admin = Owner)
                %% - update_contract("nwc_ledger", <ledger_ct>) (wallet must fill in <ledger_ct>)
                %% - register(client_pubkey, ...) on the new ledger (wallet must fill in <ledger_ct>)
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

            %% If server_signed, you MAY choose to auto-deploy+register here (custodial),
            %% but since ledger is per-user and you want future compatibility, we keep the
            %% default behavior as intent-based setup.
            {true, Req, State#{resp_body => Resp}}
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
                    ok;
                server_signed ->
                    _ = ledger_call_user(Owner, LedgerCt, "revoke", [to_s(ClientPubHex)]),
                    ok;
                operator_signed ->
                    %% revoke is admin-only
                    ok
            end,

            {true, Req, State#{
                resp_body => #{
                    status => <<"ok">>,
                    revoked => true,
                    client_pubkey => ClientPubHex,
                    ledger_ct => LedgerCt,
                    intents => Intents
                }
            }};
        {error, Why} ->
            {true, Req, State#{
                resp_body => #{
                    status => <<"error">>,
                    error => <<"NO_LEDGER">>,
                    reason => to_bin(io_lib:format("~p", [Why]))
                }
            }}
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
            Res = ledger_call_user_dry(Owner, LedgerCt, "balance", [to_s(ClientPubHex)]),
            {true, Req, State#{
                resp_body => #{
                    status => <<"ok">>,
                    owner => Owner,
                    ledger_ct => LedgerCt,
                    client_pubkey => ClientPubHex,
                    result => Res
                }
            }};
        {error, Why} ->
            {true, Req, State#{
                resp_body => #{
                    status => <<"error">>,
                    error => <<"NO_LEDGER">>,
                    reason => to_bin(io_lib:format("~p", [Why]))
                }
            }}
    end;
%% -------------------------------------------------------------------
%% ledger credit (admin-only endpoint)
%% -------------------------------------------------------------------
from_json(Req0, State = #{action := ledger_credit, role := Role}) ->
    case Role of
        <<"admin">> -> ok;
        _ -> throw({forbidden, not_admin})
    end,
    {ok, Raw, Req} = cowboy_req:read_body(Req0),
    Json = jsx:decode(Raw, [return_maps]),

    Owner = to_bin(maps:get(public_key, State)),
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
                    ok;
                server_signed ->
                    _ = ledger_call_user(
                        Owner,
                        LedgerCt,
                        "credit",
                        [to_s(ClientPubHex), integer_to_list(AmountMsat), to_s(Ref), to_s(Meta)]
                    ),
                    ok;
                operator_signed ->
                    %% credit is admin-only
                    ok
            end,

            {true, Req, State#{
                resp_body => #{
                    status => <<"ok">>,
                    owner => Owner,
                    ledger_ct => LedgerCt,
                    credited_sat => AmountSat,
                    intents => Intents
                }
            }};
        {error, Why} ->
            {true, Req, State#{
                resp_body => #{
                    status => <<"error">>,
                    error => <<"NO_LEDGER">>,
                    reason => to_bin(io_lib:format("~p", [Why]))
                }
            }}
    end.

%% ---------------- helpers ----------------

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(X) -> unicode:characters_to_binary(io_lib:format("~p", [X])).

to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(L) when is_list(L) -> L.

lower_hex_hex(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

pick_first_relay([]) ->
    <<"wss://relay.damus.io">>;
pick_first_relay([R | _]) when is_binary(R) -> R;
pick_first_relay([R | _]) ->
    unicode:characters_to_binary(R).

%% Resolve per-user ledger via AccountRegistry recorded in NodeRegistry
resolve_user_ledger_ct(OwnerAkBin) ->
    %% Ensure user has an AccountRegistry deployed + recorded in NodeRegistry
    {ok, _} = damage_node_registry:ensure_account_registry(OwnerAkBin, <<"node">>),

    %% NodeRegistry.get_registry(account) returns an AE contract_call response.
    %% We expect: #{"return_type":"ok","return_value":{address, Bin}}
    case damage_node_registry:get_registry(OwnerAkBin) of
        #{"return_type" := "ok", "return_value" := {address, RegBin}} ->
            RegistryCt = aeser_api_encoder:encode(contract_pubkey, RegBin),

            %% Now read nwc ledger ct from that AccountRegistry
            KP = user_keypair_from_owner(OwnerAkBin),
            case account_registry:get_contract(KP, RegistryCt, ?NWC_REGISTRY_NAME) of
                {ok, LedgerCt} ->
                    {ok, to_bin(LedgerCt)};
                {error, Reason} ->
                    {error, {ledger_not_found_in_account_registry, RegistryCt, Reason}}
            end;
        #{"return_type" := "revert", "return_value" := Msg} ->
            {error, {node_registry_revert, Msg}};
        Other ->
            {error, {node_registry_bad_reply, Other}}
    end.

user_keypair_from_owner(OwnerAkBin) ->
    %% Custodial path: user key is present server-side.
    %% Future noncustodial: this is the seam where you detect "no key" and return intents only.
    #{public_key := Pub0, private_key := Priv} = identity_server:get_account(OwnerAkBin),
    #{public_key => to_bin(Pub0), private_key => Priv}.

ledger_src_path() ->
    damage_ae:contract_path(?NWC_LEDGER_SRC_PATH).

ledger_call_user(OwnerAkBin, LedgerCt, Fun, Args) ->
    KP = user_keypair_from_owner(OwnerAkBin),
    AeAccount = maps:get(public_key, KP),
    damage_ae:set_private_key(AeAccount, maps:get(private_key, KP)),
    damage_ae:contract_call_payfor_user(
        AeAccount,
        to_s(LedgerCt),
        ledger_src_path(),
        Fun,
        Args
    ).

ledger_call_user_dry(_OwnerAkBin, LedgerCt, Fun, Args) ->
    damage_ae:contract_call_dry(
        to_s(LedgerCt),
        ledger_src_path(),
        Fun,
        Args,
        #{}
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

    Deploy = damage_ledger_intent:deploy_ledger_intent(OwnerAkBin, <<"DamageNWCLedger">>),
    Upsert = damage_ledger_intent:upsert_registry_intent(
        to_bin(RegistryCt), ?NWC_REGISTRY_NAME, <<"ct_TBD_FROM_DEPLOY">>
    ),
    {to_bin(RegistryCt), [Deploy, Upsert]}.

nwc_wallet_pubhex() ->
    {Pub, _Priv} = secrets:nostr_wallet_keypair(),
    Pub.
