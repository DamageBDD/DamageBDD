%% A safe, read-only session check for ECAI browser clients. Unlike
%% damage_http:is_authorized/2 this never issues a payable L402 challenge.
-module(ecai_auth_http).

-export([trails/0, init/2, allowed_methods/2, content_types_provided/2, to_json/2]).

trails() ->
    [trails:trail("/ecai/auth/session", ?MODULE, #{}, #{
        get => #{tags => ["ECAI Authentication"], produces => ["application/json"]}
    })].

init(Req, State) -> {cowboy_rest, Req, State}.

allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

to_json(Req0, State) ->
    Req = cowboy_req:set_resp_header(<<"pragma">>, <<"no-cache">>,
        cowboy_req:set_resp_header(<<"cache-control">>, <<"no-store">>, Req0)),
    %% Never return bearer tokens, session cookies, private keys or the
    %% damage_auth internal state to the browser.
    try damage_auth:authenticate(Req, State) of
        {ok, Auth} ->
            PublicKey = maps:get(public_key, Auth, <<>>),
            %% Use the same authoritative role policy as the admin API.
            %% This is UI metadata, not an authorization decision.
            NodeAdmin = ecai_node_admin:is_node_admin(PublicKey),
            CodeEnabled = application:get_env(ecai, code_admin_enabled, false) =:= true,
            CodeAdmin = CodeEnabled andalso ecai_node_admin:can_manage_code(PublicKey),
            Result = #{authenticated => true, public_key => PublicKey,
                       node_admin => NodeAdmin, code_admin => CodeAdmin,
                       code_admin_enabled => CodeEnabled},
            {jsx:encode(Result), Req, State};
        {anonymous, _} ->
            {jsx:encode(#{authenticated => false}), Req, State};
        {error, _Reason, _} ->
            {jsx:encode(#{authenticated => false}), Req, State}
    catch
        _:_ ->
            %% A broken account authority is not equivalent to signed out.
            Resp = cowboy_req:reply(503,
                #{<<"content-type">> => <<"application/json">>,
                  <<"cache-control">> => <<"no-store">>},
                jsx:encode(#{error => <<"authentication_service_unavailable">>}), Req),
            {stop, Resp, State}
    end.
