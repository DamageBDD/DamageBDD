%% A safe, read-only session check for ECAI browser clients. Unlike
%% damage_http:is_authorized/2 this never issues a payable L402 challenge.
-module(ecai_auth_http).

-export([
    trails/0,
    init/2,
    allowed_methods/2,
    content_types_provided/2,
    to_json/2,
    asset_routes/0,
    session_metadata/1
]).

trails() ->
    [
        trails:trail("/ecai/auth/session", ?MODULE, #{}, #{
            get => #{tags => ["ECAI Authentication"], produces => ["application/json"]}
        })
    ].

%% Explicit shared asset mounts avoid stale copies under ECAI's /static tree.
%% Relative imports stay in this prefix, including the lazily loaded wallet.
asset_routes() ->
    [
        {"/ecai/auth-assets/" ++ File, cowboy_static, {priv_file, damage, "static/" ++ File}}
     || File <- [
            "js/auth-ui.js",
            "js/auth-model.js",
            "js/auth-wallet-loader.js",
            "js/wallet-switcher.js",
            "js/wallet.js",
            "js/sidekick.js",
            "js/micromodal.min.js",
            "css/auth.css",
            "img/logo.png"
        ]
    ].

session_metadata(Auth) ->
    PublicKey = maps:get(public_key, Auth, <<>>),
    Mode = maps:get(auth_mode, Auth, legacy),
    NodeAdmin = ecai_node_admin:session_is_node_admin(Auth),
    CodeEnabled = application:get_env(ecai, code_admin_enabled, false) =:= true,
    CodeAdmin = NodeAdmin andalso CodeEnabled andalso ecai_node_admin:can_manage_code(PublicKey),
    #{
        authenticated => true,
        public_key => PublicKey,
        auth_mode => Mode,
        node_admin => NodeAdmin,
        code_admin => CodeAdmin,
        code_admin_enabled => CodeEnabled
    }.

init(Req, State) -> {cowboy_rest, Req, State}.

allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

to_json(Req0, State) ->
    Req = cowboy_req:set_resp_header(
        <<"pragma">>,
        <<"no-cache">>,
        cowboy_req:set_resp_header(<<"cache-control">>, <<"no-store">>, Req0)
    ),
    %% Never return bearer tokens, session cookies, private keys or the
    %% damage_auth internal state to the browser.
    try damage_auth:authenticate(Req, State) of
        {ok, Auth} ->
            Result = session_metadata(Auth),
            {jsx:encode(Result), Req, State};
        {anonymous, _} ->
            {jsx:encode(#{authenticated => false}), Req, State};
        {error, _Reason, _} ->
            {jsx:encode(#{authenticated => false}), Req, State}
    catch
        _:_ ->
            %% A broken account authority is not equivalent to signed out.
            Resp = cowboy_req:reply(
                503,
                #{
                    <<"content-type">> => <<"application/json">>,
                    <<"cache-control">> => <<"no-store">>
                },
                jsx:encode(#{error => <<"authentication_service_unavailable">>}),
                Req
            ),
            {stop, Resp, State}
    end.
