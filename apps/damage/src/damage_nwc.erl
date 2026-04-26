%% -------------------------------------------------------------------
%% damage_nwc.erl (UPDATED)
%%
%% NIP-47 (Nostr Wallet Connect) client + optional AE ledger enforcement.
%%
%% Key changes vs your pasted version:
%%   - Fix duplicate macros + exports
%%   - start_link/1 now expects Opts map: #{user_ae_account, nwc_uri, ledger_mode, server_ae_account}
%%   - init/1 accepts [Opts] (not [UserAeAccount, Uri])
%%   - Resolve ledger ct_id via account_registry for the USER (per-user registry)
%%   - Normalize state fields (use user_ae_account; remove ae_account mismatch)
%%   - Fix ledger call names to match DamageNWCLedger.aes:
%%       balance/1, policy_of/1, register/4, revoke/1, credit/4, debit/4
%%   - Add ledger helpers:
%%       ledger_contract_id/1, ledger_call/3, ledger_call_dry/3
%%   - Add deploy_nwc_contract/1 (deploy for user admin) + keep deploy_nwc_contract/0 for legacy
%%
%% Modes:
%%   user_signed      -> do not sign ledger mutations here (return intents from HTTP layer)
%%   server_signed    -> ledger mutations signed by user_ae_account (custodial keys in identity_server)
%%   operator_signed  -> debit allowed if operator is set in contract; signing key = server_ae_account
%%
%% -------------------------------------------------------------------

-module(damage_nwc).
-author("Steven Joseph <steven@damagebdd.com>").
-copyright("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([
    start_link/1,
    stop/1,

    get_info/1,
    get_balance/1,
    pay_invoice/2,
    pay_invoice/3,
    make_invoice/3,

    call/3,
    call/4,

    %% ledger utilities (read-only, safe)
    ledger_balance_msat/1,
    ledger_policy/1,

    %% deploy helper
    deploy_nwc_contract/0,
    deploy_nwc_contract/1,
    ledger_call/3,
    ledger_call_dry/3,
    ledger_balance_for_account_cached/1,
    ledger_balance_for_account_uncached/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-import(damage_utils, [to_bin/1]).

-define(NWC_CONTRACT_PATH, "contracts/nwc_ledger.aes").
-define(NWC_REGISTRY_NAME, <<"nwc_ledger">>).
-define(DEFAULT_TIMEOUT, 30000).
-define(DEFAULT_FANOUT, 3).

-record(state, {
    nwc_uri,
    %% 64 hex, lowercase
    wallet_pubkey_hex,
    %% 64 hex, lowercase
    secret_hex,
    %% 32 bytes
    client_privkey,
    %% 64 hex, lowercase
    client_pubkey_hex,
    %% [binary()]
    relays = [],
    info_cache = undefined,

    %% per-user (registry owner / ledger admin)

    %% binary() identity_server key for user OR just ak_... if noncustodial future
    user_ae_account,
    %% ct_... resolved via AccountRegistry
    nwc_contract_id,

    %% execution mode

    %% user_signed | server_signed | operator_signed
    ledger_mode = user_signed,
    %% optional signing key for operator_signed/server_signed
    server_ae_account = undefined
}).

%% -------------------------------------------------------------------
%% API
%% -------------------------------------------------------------------

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) when is_map(Opts) ->
    %% Opts required:
    %%   #{ user_ae_account := <<"ak_... or identity key">>,
    %%      nwc_uri := <<"nostr+walletconnect://...">> }
    %% Opts optional:
    %%   ledger_mode := user_signed|server_signed|operator_signed
    %%   server_ae_account := <<"identity key for service operator">>
    gen_server:start_link(?MODULE, [Opts], []).

stop(Pid) ->
    gen_server:call(Pid, stop).

get_info(Pid) ->
    gen_server:call(Pid, get_info, ?DEFAULT_TIMEOUT).

get_balance(Pid) ->
    call(Pid, <<"get_balance">>, #{}).

pay_invoice(Pid, Invoice) ->
    pay_invoice(Pid, Invoice, undefined).

pay_invoice(Pid, Invoice, AmountMsats) ->
    P0 = #{invoice => to_bin(Invoice)},
    Params =
        case AmountMsats of
            undefined ->
                P0;
            null ->
                P0;
            <<>> ->
                P0;
            A when is_integer(A) -> maps:put(amount, A, P0);
            A when is_binary(A) ->
                %% allow string digits
                maps:put(amount, binary_to_integer(A), P0);
            _ ->
                P0
        end,
    call(Pid, <<"pay_invoice">>, Params).

make_invoice(Pid, AmountMsats, Description) ->
    Params = #{amount => AmountMsats, description => to_bin(Description)},
    call(Pid, <<"make_invoice">>, Params).

call(Pid, Method, Params) ->
    call(Pid, Method, Params, ?DEFAULT_TIMEOUT).

call(Pid, Method, Params, Timeout) ->
    gen_server:call(Pid, {nwc_call, to_bin(Method), Params, Timeout}, Timeout + 2000).

%% Optional ledger reads (useful for UI/debug)
ledger_balance_msat(Pid) ->
    gen_server:call(Pid, ledger_balance_msat, ?DEFAULT_TIMEOUT).

ledger_policy(Pid) ->
    gen_server:call(Pid, ledger_policy, ?DEFAULT_TIMEOUT).

%% -------------------------------------------------------------------
%% gen_server
%% -------------------------------------------------------------------

init([Opts]) ->
    try
        UserAeAccount0 = maps:get(user_ae_account, Opts),
        NwcUri0 = maps:get(nwc_uri, Opts),
        Mode = maps:get(ledger_mode, Opts, user_signed),
        ServerAe = maps:get(server_ae_account, Opts, undefined),

        Uri = parse_nwc_uri(NwcUri0),
        WalletPub = lower_hex_ascii64(maps:get(wallet_pubkey, Uri)),
        SecretHex = lower_hex_ascii64(maps:get(secret, Uri)),
        ClientPriv = hex_to_bin(SecretHex),
        {ok, ClientPubBin} = nostrlib_schnorr:new_publickey(ClientPriv),
        ClientPubHex = lower_hex(ClientPubBin),
        Relays0 = maps:get(relays, Uri, []),
        Relays = normalize_relays(Relays0),

        %% ensure pool up (best effort)
        _ = nostr_pool:ensure_started(#{relays => Relays}),

        UserAeAccount = to_bin(UserAeAccount0),

        %% Resolve ledger ct_id via AccountRegistry owned by user.
        %% (If this fails, the HTTP layer should return intents for deploy+register;
        %%  here we treat it as init-failed because the client cannot enforce ledger.)
        {ok, CtId0} = ensure_user_nwc_contract_id(UserAeAccount),
        CtId = to_bin(CtId0),

        {ok, #state{
            nwc_uri = to_bin(NwcUri0),
            wallet_pubkey_hex = WalletPub,
            secret_hex = SecretHex,
            client_privkey = ClientPriv,
            client_pubkey_hex = ClientPubHex,
            relays = Relays,
            info_cache = undefined,
            user_ae_account = UserAeAccount,
            nwc_contract_id = CtId,
            ledger_mode = Mode,
            server_ae_account = ServerAe
        }}
    catch
        C:R:S ->
            ?LOG_ERROR("damage_nwc init failed ~p:~p ~p", [C, R, S]),
            {stop, {init_failed, R}}
    end.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(get_info, _From, #state{info_cache = Info} = State) when is_map(Info) ->
    {reply, Info, State};
handle_call(get_info, _From, State = #state{wallet_pubkey_hex = WalletPub, relays = Relays}) ->
    %% NWC info is kind 13194 (replaceable) by wallet service pubkey
    Filter = #{kinds => [13194], authors => [WalletPub], limit => 1},
    Res = nostr_pool:req_one(Filter, Relays, 8000, ?DEFAULT_FANOUT),
    Reply =
        case Res of
            {ok, Event} ->
                Content = to_bin(maps:get(<<"content">>, Event, <<>>)),
                Caps = [C || C <- binary:split(Content, <<" ">>, [global]), C =/= <<>>],
                #{event => Event, capabilities => Caps};
            {error, Why} ->
                #{error => Why}
        end,
    {reply, Reply, State#state{info_cache = Reply}};
handle_call(ledger_balance_msat, _From, State = #state{client_pubkey_hex = ClientPub}) ->
    %% ledger uses "balance(client_pubkey)" returning msat int
    Reply = ledger_call_dry(State, "balance", [to_s(ClientPub)]),
    {reply, Reply, State};
handle_call(ledger_policy, _From, State = #state{client_pubkey_hex = ClientPub}) ->
    Reply = ledger_call_dry(State, "policy_of", [to_s(ClientPub)]),
    {reply, Reply, State};
handle_call(
    {nwc_call, Method, Params, Timeout},
    _From,
    State = #state{
        wallet_pubkey_hex = WalletPub,
        client_privkey = Priv,
        client_pubkey_hex = ClientPub,
        relays = Relays
    }
) ->
    TS = erlang:system_time(seconds),

    %% NWC request JSON: {"method":"...","params":{...}}
    Plain = jsx:encode(#{
        method => Method,
        params => Params
    }),

    case damage_nostr:nip04_encrypt(Plain, Priv, WalletPub) of
        {ok, CipherB64, IvB64} ->
            %% NIP-04 content format: "<ciphertext_b64>?iv=<iv_b64>"
            Content = <<CipherB64/binary, "?iv=", IvB64/binary>>,
            Tags = [[<<"p">>, WalletPub]],

            Event0 = damage_nostr:construct_event(ClientPub, 23194, Content, TS, Tags),
            Event = damage_nostr:finalize_event(Event0, Priv),
            ReqId = maps:get(<<"id">>, Event),

            ok = nostr_pool:publish(Event, Relays, 2000),

            %% Wait for response kind 23195 addressed to us and referencing our request in an 'e' tag
            RespFilter = #{
                kinds => [23195],
                authors => [WalletPub],
                '#p' => [ClientPub],
                '#e' => [ReqId],
                since => TS - 10,
                limit => 1
            },

            RespRes = nostr_pool:req_one(RespFilter, Relays, Timeout, ?DEFAULT_FANOUT),

            Reply =
                case RespRes of
                    {ok, RespEvent} ->
                        handle_response_event(RespEvent, Priv, WalletPub);
                    {error, Why} ->
                        {error, #{
                            code => <<"TIMEOUT_OR_RELAY_ERROR">>,
                            message => to_bin(io_lib:format("~p", [Why]))
                        }}
                end,
            {reply, Reply, State};
        {error, Why} ->
            {reply,
                {error, #{
                    code => <<"ENCRYPT_FAILED">>,
                    message => to_bin(io_lib:format("~p", [Why]))
                }},
                State}
    end;
handle_call(Any, _From, State) ->
    {reply, {error, {unknown_call, Any}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% -------------------------------------------------------------------
%% Response decoding
%% -------------------------------------------------------------------

handle_response_event(RespEvent, Priv, WalletPub) ->
    Content = maps:get(<<"content">>, RespEvent, <<>>),
    case damage_nostr:nip04_decrypt_content(Content, Priv, WalletPub) of
        {ok, PlainJson} ->
            try jsx:decode(PlainJson, [return_maps]) of
                #{<<"error">> := null, <<"result">> := Result} ->
                    {ok, Result};
                #{<<"error">> := Err} when Err =/= null ->
                    {error, Err};
                Other ->
                    {ok, Other}
            catch
                _:E ->
                    {error, #{
                        code => <<"BAD_RESPONSE_JSON">>,
                        message => to_bin(io_lib:format("~p", [E]))
                    }}
            end;
        {error, Why} ->
            {error, #{
                code => <<"DECRYPT_FAILED">>,
                message => to_bin(io_lib:format("~p", [Why]))
            }}
    end.

%% -------------------------------------------------------------------
%% URI parsing
%% -------------------------------------------------------------------

parse_nwc_uri(Uri0) ->
    Uri = to_bin(Uri0),
    <<"nostr+walletconnect://", Rest/binary>> = Uri,
    [WalletPubKeyBin, QueryBin] = binary:split(Rest, <<"?">>),

    Params = damage_nostr:parse_kv_query(QueryBin),
    Relays0 = maps:get(<<"relay">>, Params, []),
    Relays =
        case Relays0 of
            R when is_binary(R) -> [R];
            Rs when is_list(Rs) -> lists:reverse(Rs);
            _ -> []
        end,
    #{
        wallet_pubkey => WalletPubKeyBin,
        secret => maps:get(<<"secret">>, Params),
        relays => damage_nostr:normalize_relays(Relays)
    }.
%% -------------------------------------------------------------------
%% Ledger resolution + calls
%% -------------------------------------------------------------------

user_keypair(UserAeAccount0) ->
    UserAeAccount = to_bin(UserAeAccount0),
    #{public_key := Pub0, private_key := Priv} = identity_server:get_account(UserAeAccount),
    #{public_key => to_bin(Pub0), private_key => Priv}.

resolve_user_nwc_contract_id(UserAeAccount) ->
    KP = user_keypair(UserAeAccount),
    account_registry:get_contract(KP, ?NWC_REGISTRY_NAME).

ensure_user_nwc_contract_id(UserAeAccount0) ->
    UserAeAccount = to_bin(UserAeAccount0),
    case resolve_user_nwc_contract_id(UserAeAccount) of
        {ok, CtId} ->
            {ok, to_bin(CtId)};
        {error, not_found} ->
            deploy_and_register_user_nwc_contract(UserAeAccount);
        {error, {unexpected_return_type, "revert", #{"return_value" := <<"Contract not found">>}}} ->
            deploy_and_register_user_nwc_contract(UserAeAccount);
        {error,
            {unexpected_return_type, <<"revert">>, #{"return_value" := <<"Contract not found">>}}} ->
            deploy_and_register_user_nwc_contract(UserAeAccount);
        {error, {ledger_not_found_in_account_registry, _RegistryCt, _Reason}} ->
            deploy_and_register_user_nwc_contract(UserAeAccount);
        {error, Why} ->
            {error, Why}
    end.

deploy_and_register_user_nwc_contract(UserAeAccount0) ->
    ?LOG_WARNING("nwc_ledger missing for ~p, deploying and registering a new contract", [
        UserAeAccount0
    ]),
    UserAeAccount = to_bin(UserAeAccount0),
    KP = user_keypair(UserAeAccount),

    case ensure_user_registry_ct(UserAeAccount) of
        {ok, RegistryCt0} ->
            RegistryCt = to_bin(RegistryCt0),
            case deploy_nwc_contract(UserAeAccount) of
                #{"contract_id" := CtId0} ->
                    CtId = to_bin(CtId0),
                    case
                        damage_nwc_http:upsert_registry_contract(
                            KP,
                            RegistryCt,
                            ?NWC_REGISTRY_NAME,
                            CtId
                        )
                    of
                        {ok, true} ->
                            {ok, CtId};
                        {error, Why} ->
                            {error, {registry_upsert_failed, Why}};
                        Other ->
                            {error, {registry_upsert_bad_reply, Other}}
                    end;
                #{"return_type" := "revert"} = Info ->
                    {error, {deploy_revert, Info}};
                Other ->
                    {error, {deploy_failed, Other}}
            end;
        {error, Why} ->
            {error, {ensure_registry_failed, Why}}
    end.

ensure_user_registry_ct(UserAeAccount0) ->
    UserAeAccount = to_bin(UserAeAccount0),
    case damage_node_registry:ensure_account_registry(UserAeAccount, <<"node">>) of
        {ok, RegistryCt} when is_binary(RegistryCt); is_list(RegistryCt) ->
            {ok, to_bin(RegistryCt)};
        {ok, _} ->
            case damage_node_registry:get_registry(UserAeAccount) of
                #{"return_type" := "ok", "return_value" := {address, RegBin}} ->
                    {ok, aeser_api_encoder:encode(contract_pubkey, RegBin)};
                Other ->
                    {error, {get_registry_failed, Other}}
            end;
        {error, Why} ->
            {error, Why}
    end.
%% Determine which AE identity is used to sign ledger mutations.
%% - user_signed: no signing should happen here (HTTP layer returns intents)
%% - server_signed: sign as user_ae_account (custodial user keys held server-side)
%% - operator_signed: sign as server_ae_account (service operator key); contract must have operator set
ledger_signer_account(#state{ledger_mode = user_signed}) ->
    undefined;
ledger_signer_account(#state{ledger_mode = server_signed, user_ae_account = A}) ->
    A;
ledger_signer_account(#state{ledger_mode = operator_signed, server_ae_account = A}) ->
    A;
ledger_signer_account(_) ->
    undefined.

ledger_call(State = #state{nwc_contract_id = CtId}, Fun, Args) ->
    case ledger_signer_account(State) of
        undefined ->
            {error, not_signing_in_user_signed_mode};
        SignerAe ->
            #{public_key := _PubKey, private_key := PrivateKey} =
                identity_server:get_account(SignerAe),
            damage_ae:set_private_key(SignerAe, PrivateKey),
            damage_ae:contract_call_payfor_user(
                SignerAe,
                CtId,
                damage_ae:contract_path(?NWC_CONTRACT_PATH),
                Fun,
                Args
            )
    end.

ledger_call_dry(#state{nwc_contract_id = CtId}, Fun, Args) ->
    damage_ae:contract_call_dry(
        CtId,
        damage_ae:contract_path(?NWC_CONTRACT_PATH),
        Fun,
        Args,
        #{}
    ).

%% -------------------------------------------------------------------
%% Deploy helpers
%% -------------------------------------------------------------------

%% Legacy: deploy using whatever default key is configured inside damage_ae (kept for compatibility).
deploy_nwc_contract() ->
    damage_ae:contract_deploy(damage_ae:contract_path(damage, ?NWC_CONTRACT_PATH), []).

%% Deploy FOR USER: admin = user's AE address; requires custodial access to user keypair in identity_server.
deploy_nwc_contract(UserAeAccount0) ->
    UserAeAccount = to_bin(UserAeAccount0),
    KP = user_keypair(UserAeAccount),
    %% init(admin' : address) expects an address string; use the public_key as admin
    damage_ae:contract_deploy_for(KP, damage_ae:contract_path(damage, ?NWC_CONTRACT_PATH), [
        to_s(maps:get(public_key, KP))
    ]).

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

hex_to_bin(Hex) ->
    binary:decode_hex(to_bin(Hex)).

lower_hex(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bin)))).

lower_hex_ascii64(Bin) when is_binary(Bin) ->
    list_to_binary(string:lowercase(binary_to_list(Bin))).

normalize_relays(Relays0) ->
    [to_bin(R) || R <- Relays0, R =/= <<>>].

to_s(B) when is_binary(B) -> binary_to_list(B);
to_s(L) when is_list(L) -> L.

ledger_balance_for_account_cached(AeAccount) ->
    AeAccountBin = damage_utils:to_bin(AeAccount),
    case damage_nwc_balance_cache:get(AeAccountBin) of
        {ok, Ledger} ->
            Ledger;
        miss ->
            Ledger = ledger_balance_for_account_uncached(AeAccountBin),
            ok = damage_nwc_balance_cache:put(AeAccountBin, Ledger),
            Ledger
    end.

ledger_balance_for_account_uncached(AeAccountBin) ->
    case damage_nwc_http:resolve_user_ledger_ct(AeAccountBin) of
        {ok, LedgerCt} ->
            LedgerCtBin = damage_utils:to_bin(LedgerCt),
            ?LOG_DEBUG("damage_nwc ledger_balance_for_account_uncached ~p ~p", [
                AeAccountBin, LedgerCtBin
            ]),
            case damage_nwc_wallet:ledger_balance_msat(AeAccountBin, LedgerCtBin, AeAccountBin) of
                {ok, LedgerMsat} ->
                    #{
                        account => AeAccountBin,
                        ledger_ct => LedgerCtBin,
                        balance_msat => LedgerMsat,
                        balance_sat => LedgerMsat div 1000
                    };
                {error, Why} ->
                    #{
                        account => AeAccountBin,
                        status => <<"error">>,
                        message => damage_utils:to_bin(io_lib:format("~p", [Why]))
                    }
            end;
        {error, not_found} ->
            #{
                account => AeAccountBin,
                status => <<"not_found">>,
                balance_msat => 0,
                balance_sat => 0
            };
        {error, Why} ->
            #{
                account => AeAccountBin,
                status => <<"error">>,
                message => damage_utils:to_bin(io_lib:format("~p", [Why]))
            }
    end.
