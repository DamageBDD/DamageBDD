-module(damage_auth).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").

-export([
    build_auth_state/2,
    is_node_admin_account/1,
    auth_success_state/3,
    with_identity_account/3,
    resolve_oauth/2,
    resolve_nostr/2,
    resolve_l402/3,
    authenticate/2,
    maybe_authenticate/2,
    require_auth/4
]).

%% ------------------------------------------------------------------
%% Base request-derived state
%% ------------------------------------------------------------------

build_auth_state(Req, State0) ->
    State0#{
        ip => damage_utils:get_ip(Req),
        useragent => cowboy_req:header(<<"user-agent">>, Req, ""),
        node_admin => false
    }.

%% ------------------------------------------------------------------
%% Admin check
%% ------------------------------------------------------------------

is_node_admin_account(AeAccount) when is_binary(AeAccount) ->
    is_node_admin_account(binary_to_list(AeAccount));
is_node_admin_account(AeAccount) ->
    case application:get_env(damage, node_admins, []) of
        Admins when is_list(Admins) ->
            lists:member(AeAccount, Admins);
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
            public_key => AeAccount,
            authenticated => true,
            node_admin => is_node_admin_account(AeAccount)
        }
    ),
        ?LOG_DEBUG("auth_success_state ~p ~p", [Resp, is_node_admin_account(AeAccount)]),
    Resp.

with_identity_account(AeAccount, State, Extra) ->
    ?LOG_DEBUG("with_identity_account 0 ~p ", [State]),
    case identity_server:get_account(AeAccount) of
        #{public_key := AeAccount, private_key := PrivateKey} ->
            damage_ae:set_private_key(AeAccount, PrivateKey),
            AuthState =auth_success_state(State, AeAccount, Extra#{private_key => PrivateKey}),
            ?LOG_DEBUG("with_identity_account 1 ~p ", [AuthState]),
            {ok, AuthState};
        Other ->
            ?LOG_DEBUG("with_identity_account 2 ~p ", [Other]),
            {ok, auth_success_state(State, AeAccount, Extra)}
    end.

%% ------------------------------------------------------------------
%% Credential resolvers
%% ------------------------------------------------------------------

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
            ?LOG_DEBUG("L402 auth ~p", [Meta]),
            case application:get_env(damage, l402_account) of
                {ok, AeAccount} ->
                    with_identity_account(AeAccount, State, #{});
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
                    {ok, AuthState};
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
        {error, no_access_token} ->
            {anonymous, BaseState};
        {error, Reason} ->
            ?LOG_DEBUG("get_access_token error ~p", [Reason]),
            {error, Reason, BaseState}
    end.

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

require_auth(Req, State0, OnAnonymousFun, OnErrorFun)
when is_function(OnAnonymousFun, 2), is_function(OnErrorFun, 3) ->
    case authenticate(Req, State0) of
        {ok, AuthState} ->
            {true, Req, AuthState};
        {anonymous, BaseState} ->
            OnAnonymousFun(Req, BaseState);
        {error, Reason, BaseState} ->
            OnErrorFun(Req, Reason, BaseState)
    end.
