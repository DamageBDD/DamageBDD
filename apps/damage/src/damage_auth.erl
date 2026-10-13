-module(damage_auth).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    build_auth_state/2,
    is_node_admin_account/1,
    is_tax_admin_account/1,
    auth_success_state/3,
    with_identity_account/3,
    resolve_oauth/2,
    resolve_nostr/2,
    resolve_l402/3,
    authenticate/2,
    maybe_authenticate/2,
    require_auth/4,
    authenticated_account/1
]).
-import(damage_utils, [to_bin/1]).

%% ------------------------------------------------------------------
%% Base request-derived state
%% ------------------------------------------------------------------

build_auth_state(Req, State0) ->
    State0#{
        ip => damage_utils:get_ip(Req),
        useragent => cowboy_req:header(<<"user-agent">>, Req, ""),
        node_admin => false,
        tax_admin => false
    }.

%% ------------------------------------------------------------------
%% Admin check
%% ------------------------------------------------------------------

is_node_admin_account(AeAccount0) ->
    AeAccount = to_bin(AeAccount0),
    case application:get_env(damage, node_admins, []) of
        Admins when is_list(Admins) ->
            lists:member(AeAccount, [to_bin(A) || A <- Admins]);
        _ ->
            false
    end.

%% Tax administrators are a separate operator-controlled allowlist. Node
%% administrators are always tax administrators, but not the other way around.
%% This list is never editable through the dashboard or public settings API.
is_tax_admin_account(undefined) ->
    false;
is_tax_admin_account(AeAccount0) ->
    AeAccount = to_bin(AeAccount0),
    is_node_admin_account(AeAccount) orelse
        case application:get_env(damage, tax_admins, []) of
            Admins when is_list(Admins) ->
                lists:member(AeAccount, [to_bin(A) || A <- Admins]);
            _ ->
                false
        end.

%% ------------------------------------------------------------------
%% Authenticated state enrichment
%% ------------------------------------------------------------------

auth_success_state(State, AeAccount, Extra) ->
    Resp = maps:merge(
        State,
        Extra#{
            public_key => to_bin(AeAccount),
            authenticated => true,
            node_admin => is_node_admin_account(AeAccount),
            tax_admin => is_tax_admin_account(AeAccount)
        }
    ),
    %?LOG_DEBUG("auth_success_state ~p ~p", [Resp, is_node_admin_account(AeAccount)]),
    Resp.

with_identity_account(AeAccount, State, Extra) ->
    case identity_server:get_account(AeAccount) of
        #{public_key := AeAccount, private_key := PrivateKey} ->
            damage_ae:set_private_key(AeAccount, PrivateKey),
            AuthState = auth_success_state(State, AeAccount, Extra#{private_key => PrivateKey}),
            {ok, AuthState};
        _Other ->
            {ok, auth_success_state(State, AeAccount, Extra)}
    end.

%% ------------------------------------------------------------------
%% Credential resolvers
%% ------------------------------------------------------------------

resolve_oauth(<<"ds1.", _/binary>> = Token, State) ->
    case damage_browser_auth:lookup(Token) of
        {ok, #{address := Account, mode := wallet}} ->
            %% Never call identity_server or hydrate a signing key for this path.
            WalletState = auth_success_state(
                maps:without([private_key, username], State),
                Account,
                #{access_token => Token, auth_type => browser_session, auth_mode => wallet}
            ),
            {ok, WalletState#{node_admin => false, tax_admin => false}};
        {ok, #{address := Account, mode := custodial, email := Email}} ->
            with_identity_account(
                Account,
                State,
                #{
                    access_token => Token,
                    username => Email,
                    auth_type => browser_session,
                    auth_mode => custodial
                }
            );
        _ ->
            {error, invalid_oauth}
    end;
resolve_oauth(Token, State) ->
    case damage_access_token:verify_token(Token) of
        {error, _} ->
            {error, invalid_oauth};
        {ok, AeAccount, _} ->
            with_identity_account(AeAccount, State, #{access_token => Token});
        Other ->
            ?LOG_ERROR("Unexpected oauth auth ~p", [Other]),
            {error, invalid_oauth}
    end.

resolve_nostr(Token, State) ->
    try jsx:decode(base64:decode(Token), [{labels, atom}, return_maps]) of
        #{pubkey := Npub} = NostrEvent ->
            ?LOG_INFO("Got Nostr auth ~p", [NostrEvent]),
            case nostrlib:verify(NostrEvent) of
                true ->
                    case damage_ae:contract_call_admin_account("resolve_npub", [Npub]) of
                        {ok, AeAccount} ->
                            with_identity_account(AeAccount, State, #{nostr_pubkey => Npub});
                        {ok, AeAccount, _Meta} ->
                            with_identity_account(AeAccount, State, #{nostr_pubkey => Npub});
                        {error, Reason} ->
                            ?LOG_INFO("Failed to resolve npub ~p reason ~p", [Npub, Reason]),
                            {error, invalid_nostr};
                        Other ->
                            ?LOG_INFO("Unexpected npub resolve result ~p for ~p", [Other, Npub]),
                            {error, invalid_nostr}
                    end;
                false ->
                    {error, invalid_nostr}
            end;
        Other ->
            ?LOG_INFO("Invalid nostr token payload ~p", [Other]),
            {error, invalid_nostr}
    catch
        C:R:S ->
            ?LOG_INFO("Failed to decode nostr token class=~p reason=~p stack=~p", [C, R, S]),
            {error, invalid_nostr}
    end.

resolve_l402(AuthHeader, Req, State) ->
    case damage_l402:verify_authorization(AuthHeader, Req) of
        {ok, Meta} ->
            case application:get_env(damage, l402_account) of
                {ok, AeAccount0} ->
                    AeAccount = to_bin(AeAccount0),
                    case {is_node_admin_account(AeAccount), is_tax_admin_account(AeAccount)} of
                        {true, _} ->
                            ?LOG_ERROR("Refusing L402 auth for node admin account ~p", [AeAccount]),
                            {error, l402_account_cannot_be_node_admin};
                        {false, true} ->
                            ?LOG_ERROR("Refusing L402 auth for tax admin account ~p", [AeAccount]),
                            {error, l402_account_cannot_be_tax_admin};
                        {false, false} ->
                            with_identity_account(
                                AeAccount,
                                State,
                                #{
                                    auth_type => l402,
                                    l402 => Meta,
                                    l402_macaroon => maps:get(macaroon, Meta, <<>>),
                                    l402_payment_hash_hex => maps:get(payment_hash_hex, Meta, <<>>)
                                }
                            )
                    end;
                Other ->
                    ?LOG_INFO("L402 not enabled ~p", [Other]),
                    {error, l402_not_enabled}
            end;
        {error, _} ->
            {error, invalid_l402}
    end.

%% ------------------------------------------------------------------
%% Core reusable request authentication
%% ------------------------------------------------------------------

authenticate(Req, State0) ->
    BaseState = build_auth_state(Req, State0),
    case damage_access_token:get_access_token(Req) of
        {access_token, Token} ->
            case resolve_oauth(Token, BaseState) of
                {ok, AuthState} ->
                    case
                        damage_wallet_policy:allowed(
                            cowboy_req:method(Req),
                            cowboy_req:path(Req),
                            maps:get(auth_mode, AuthState, legacy)
                        )
                    of
                        true -> {ok, AuthState};
                        false -> {error, wallet_operation_unavailable, BaseState}
                    end;
                {error, Reason} ->
                    {error, Reason, BaseState}
            end;
        {nostr, Token} ->
            case resolve_nostr(Token, BaseState) of
                {ok, AuthState} ->
                    {ok, AuthState};
                {error, Reason} ->
                    {error, Reason, BaseState}
            end;
        {l402, AuthHeader} ->
            case resolve_l402(AuthHeader, Req, BaseState) of
                {ok, AuthState} ->
                    {ok, AuthState};
                {error, Reason} ->
                    {error, Reason, BaseState}
            end;
        {error, missing} ->
            {anonymous, BaseState};
        {error, no_access_token} ->
            {anonymous, BaseState};
        {error, Reason} ->
            {error, Reason, BaseState}
    end.

%% ------------------------------------------------------------------
%% Authenticated identity accessor
%% ------------------------------------------------------------------

-spec authenticated_account(map()) -> {ok, binary()} | {error, unauthenticated}.
authenticated_account(State) when is_map(State) ->
    case
        first_identity_value(State, [
            public_key,
            <<"public_key">>,
            ae_account,
            <<"ae_account">>,
            owner,
            <<"owner">>
        ])
    of
        undefined -> {error, unauthenticated};
        Value -> normalize_authenticated_account(Value)
    end;
authenticated_account(_) ->
    {error, unauthenticated}.

first_identity_value(_State, []) ->
    undefined;
first_identity_value(State, [Key | Rest]) ->
    case maps:get(Key, State, undefined) of
        undefined -> first_identity_value(State, Rest);
        null -> first_identity_value(State, Rest);
        <<>> -> first_identity_value(State, Rest);
        "" -> first_identity_value(State, Rest);
        Value -> Value
    end.

normalize_authenticated_account(Value) when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_authenticated_account(Value) when is_list(Value), Value =/= [] ->
    try unicode:characters_to_binary(Value) of
        Bin when is_binary(Bin), byte_size(Bin) > 0 -> {ok, Bin};
        _ -> {error, unauthenticated}
    catch
        _:_ -> {error, unauthenticated}
    end;
normalize_authenticated_account(_) ->
    {error, unauthenticated}.

%% ------------------------------------------------------------------
%% Cowboy adapters
%% ------------------------------------------------------------------

maybe_authenticate(Req, State0) ->
    case authenticate(Req, State0) of
        {ok, AuthState} ->
            {true, Req, AuthState};
        {anonymous, BaseState} ->
            {true, Req, BaseState};
        {error, _Reason, BaseState} ->
            {true, Req, BaseState}
    end.

require_auth(Req, State0, OnAnonymousFun, OnErrorFun) when
    is_function(OnAnonymousFun, 2), is_function(OnErrorFun, 3)
->
    case authenticate(Req, State0) of
        {ok, AuthState} ->
            {true, Req, AuthState};
        {anonymous, BaseState} ->
            OnAnonymousFun(Req, BaseState);
        {error, wallet_operation_unavailable, BaseState} ->
            {stop,
                cowboy_req:reply(
                    403,
                    #{
                        <<"content-type">> => <<"application/json">>,
                        <<"cache-control">> => <<"no-store">>
                    },
                    jsx:encode(damage_wallet_policy:rejection()),
                    Req
                ),
                BaseState};
        {error, Reason, BaseState} ->
            OnErrorFun(Req, Reason, BaseState)
    end.
