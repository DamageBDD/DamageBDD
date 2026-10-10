%% Same-origin guard around existing DamageBDD NWC REST operations.
%% A Nosternity session is NEVER substituted for DamageBDD authentication.
-module(nosternity_damage_http).
-export([trails/0, init/2, allowed_methods/2, content_types_accepted/2,
         content_types_provided/2, is_authorized/2, from_json/2, to_json/2]).
trails() -> [trails:trail(P, ?MODULE, #{action => A}, #{}) || {P,A} <- [
    {"/api/nwc/mint", mint}, {"/api/nwc/sessions", sessions}, {"/api/nwc/revoke", revoke},
    {"/api/nwc/ledger/balance", ledger_balance}, {"/api/nwc/topup_invoice", topup_invoice},
    {"/api/nwc/topup_status", topup_status}]].
init(Req, State) -> {cowboy_rest, nosternity_auth_http:no_store(Req), State}.
allowed_methods(R,S) -> damage_nwc_http:allowed_methods(R,S).
content_types_accepted(R,S) -> damage_nwc_http:content_types_accepted(R,S).
content_types_provided(R,S) -> damage_nwc_http:content_types_provided(R,S).
is_authorized(R,S) ->
    try nosternity_auth_http:allowed(R) of
        true ->
            %% Preflight a real browser session to avoid a payable L402 challenge
            %% or legacy authority fallback on this browser-only surface.
            case damage_browser_auth:lookup(nosternity_auth_http:cookie(<<"sessionid">>, R)) of
                {ok, #{mode := custodial}} -> damage_nwc_http:is_authorized(R,S);
                _ -> {stop, nosternity_auth_http:error_reply(damage_login_required,R), S}
            end;
        false -> {stop, nosternity_auth_http:error_reply(origin_rejected,R), S}
    catch _:_ -> {stop, nosternity_auth_http:error_reply(auth_unavailable,R), S} end.
from_json(R,S) -> damage_nwc_http:from_json(R,S).
to_json(R,S) -> damage_nwc_http:to_json(R,S).
