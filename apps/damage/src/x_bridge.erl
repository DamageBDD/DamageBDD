-module(x_bridge).

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-export([
    %% Nostr → X
    post_to_twitter_from_event/2,

    %% OAuth2 helpers (PKCE user-context)
    auth_url/0,
    auth_url_open/0,
    exchange_code/2,
    refresh_access_token/1
]).

-export([
    %% tests
    test_post_to_twitter/0,
    test_truncate_long_post/0,
    test_gun_connection/0,
    get_user_access_token/0,
    get_app_bearer_token/0,
    get_public_tweets/1,
    handle_oauth_redirect/2
]).

-import(damage_utils, [to_bin/1]).

%% ============================================================
%% Nostr → X posting (uses OAuth2 Bearer *user* token)
%% ============================================================

-define(X_API_HOST, <<"api.x.com">>).
-define(X_TWEETS_PATH, <<"/2/tweets">>).
-define(X_OAUTH2_TOKEN_PATH, <<"/2/oauth2/token">>).
-define(X_REDIRECT_URL, <<"http://localhost:8080/x/redirect">>).

%% Nostr → X post
post_to_twitter_from_event(#{id := IdBin, content := ContentBin}, _State) ->
    case get_user_access_token() of
        {error, _} = E ->
            E;
        {ok, AccessToken} ->
            %% Build Nostr URL + truncated tweet text
            ViewerBase = application:get_env(
                damage,
                nostr_viewer,
                "https://nostr.ae/e/"
            ),
            NostrURL = iolist_to_binary([ViewerBase, IdBin]),
            TextBin = build_tweet(ContentBin, NostrURL),

            %% Minimal TweetCreateRequest body: { "text": "..." }
            BodyJson = jsx:encode(#{<<"text">> => TextBin}),

            Headers = [
                %% OAuth2 user-context token in Authorization header
                {<<"authorization">>, <<"Bearer ", AccessToken/binary>>},
                {<<"content-type">>, <<"application/json">>}
            ],

            do_gun_post(?X_API_HOST, 443, ?X_TWEETS_PATH, Headers, BodyJson)
    end.

%% ============================================================
%% OAuth2 (Authorization Code + PKCE) helpers
%%  - These do not store anything; you stash tokens via `secrets`.
%% ============================================================

%% Generate:
%%  - URL to open in browser
%%  - PKCE verifier
%%  - CSRF state
%% secrets:
%%   x_client_id
%%   x_redirect_uri
auth_url() ->
    {ok, ClientId} = secrets:retrieve_decrypt(x_client_id),

    Scopes = <<"tweet.read tweet.write users.read offline.access">>,
    {Verifier, Challenge} = pkce_pair(),
    State = base64url(crypto:strong_rand_bytes(16)),

    Qs = io_lib:format(
        "response_type=code&client_id=~s&redirect_uri=~s"
        "&scope=~s&state=~s&code_challenge=~s"
        "&code_challenge_method=S256",
        [
            urlenc(ClientId),
            urlenc(?X_REDIRECT_URL),
            urlenc(Scopes),
            urlenc(State),
            urlenc(Challenge)
        ]
    ),
    %% Auth URL still goes via twitter.com/i/oauth2/authorize per docs
    Url = "https://twitter.com/i/oauth2/authorize?" ++ lists:flatten(Qs),
    {Url, Verifier, State}.

%% Exchange authorization code + PKCE verifier for tokens.
%% Args:
%%  - CodeBin:   <<"code-from-callback">>
%%  - Verifier:  PKCE verifier returned from auth_url/0
%% secrets:
%%   x_client_id
%%   x_client_secret
%%   x_redirect_uri
exchange_code(CodeBin, VerifierBin) ->
    {ok, ClientId} = secrets:retrieve_decrypt(x_client_id),
    {ok, ClientSecret} = secrets:retrieve_decrypt(x_client_secret),

    HostBin = ?X_API_HOST,
    PathBin = ?X_OAUTH2_TOKEN_PATH,

    BodyStr = io_lib:format(
        "grant_type=authorization_code&code=~s&redirect_uri=~s&code_verifier=~s",
        [
            urlenc(CodeBin),
            urlenc(?X_REDIRECT_URL),
            urlenc(VerifierBin)
        ]
    ),
    BodyBin = list_to_binary(BodyStr),

    BasicCreds = base64:encode(
        <<ClientId/binary, ":", ClientSecret/binary>>
    ),

    Headers = [
        {<<"authorization">>, <<"Basic ", BasicCreds/binary>>},
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>}
    ],

    do_gun_post(HostBin, 443, PathBin, Headers, BodyBin).

%% Refresh token flow
%%  - RefreshTokenBin: <<"refresh_token">> from previous response
refresh_access_token(RefreshTokenBin) ->
    {ok, ClientId} = secrets:retrieve_decrypt(x_client_id),
    {ok, ClientSecret} = secrets:retrieve_decrypt(x_client_secret),

    HostBin = ?X_API_HOST,
    PathBin = ?X_OAUTH2_TOKEN_PATH,

    BodyStr = io_lib:format(
        "grant_type=refresh_token&refresh_token=~s",
        [urlenc(RefreshTokenBin)]
    ),
    BodyBin = list_to_binary(BodyStr),

    BasicCreds = base64:encode(
        <<ClientId/binary, ":", ClientSecret/binary>>
    ),

    Headers = [
        {<<"authorization">>, <<"Basic ", BasicCreds/binary>>},
        {<<"content-type">>, <<"application/x-www-form-urlencoded">>}
    ],

    do_gun_post(HostBin, 443, PathBin, Headers, BodyBin).

%% ============================================================
%% Helpers
%% ============================================================

%% User-context OAuth2 access token (PKCE), with tweet.write scope.
%% This must *not* be the app-only Bearer Token from the portal.
%% User-context OAuth2 access token (PKCE), with tweet.write scope.
%% Must be set via secrets:store_encrypt(x_user_access_token, AccessTokenBin).
get_user_access_token() ->
    case secrets:retrieve_decrypt(x_user_access_token) of
        {ok, T} when is_binary(T) ->
            {ok, T};
        {ok, T} when is_list(T) ->
            {ok, list_to_binary(T)};
        {error, Reason} ->
            ?LOG_WARNING("x_user_access_token not available: ~p", [Reason]),
            {error, no_user_access_token};
        Other ->
            ?LOG_WARNING("x_user_access_token unexpected: ~p", [Other]),
            {error, no_user_access_token}
    end.

%% PKCE verifier/challenge pair
pkce_pair() ->
    Verifier = base64url(crypto:strong_rand_bytes(32)),
    Challenge = base64url(crypto:hash(sha256, Verifier)),
    {Verifier, Challenge}.

base64url(Bin) ->
    B1 = base64:encode(Bin),
    B2 = binary:replace(B1, <<"+">>, <<"-">>, [global]),
    B3 = binary:replace(B2, <<"/">>, <<"_">>, [global]),
    list_to_binary([C || C <- binary:bin_to_list(B3), C =/= $=]).

%% RFC3986-style URL encoding using same rules as OAuth
urlenc(Bin) when is_binary(Bin) ->
    urlenc(binary:bin_to_list(Bin));
urlenc(Str) when is_list(Str) ->
    lists:flatten([enc_char(C) || C <- Str]).

enc_char(C) when
    (C >= $A andalso C =< $Z);
    (C >= $a andalso C =< $z);
    (C >= $0 andalso C =< $9);
    C =:= $-;
    C =:= $_;
    C =:= $.;
    C =:= $~
->
    [C];
enc_char(C) ->
    ["%", io_lib:format("~2.16.0B", [C])].

%% Max 280 characters, UTF-8 safe, with nostr link
build_tweet(ContentBin, NostrUrlBin) when
    is_binary(ContentBin), is_binary(NostrUrlBin)
->
    MaxChars = 280,
    ?LOG_DEBUG("content bin ~p", [ContentBin]),
    ContentChars = binary_to_list(ContentBin),
    ?LOG_DEBUG("content char ~p", [ContentChars]),
    LenContent = length(ContentChars),
    case LenContent =< MaxChars of
        true ->
            ContentBin;
        false ->
            SepChars = " ",
            LinkChars = unicode:characters_to_list(NostrUrlBin),
            %% “…”
            EllipsisChars = [16#2026],
            Reserve =
                length(EllipsisChars) +
                    length(SepChars) +
                    length(LinkChars),
            AllowedContentLen0 = MaxChars - Reserve,
            AllowedContentLen =
                case AllowedContentLen0 < 0 of
                    true -> 0;
                    false -> AllowedContentLen0
                end,
            {PrefixChars, _} =
                lists:split(AllowedContentLen, ContentChars),
            unicode:characters_to_binary(
                PrefixChars ++ EllipsisChars ++ SepChars ++ LinkChars
            )
    end.

%% Generic gun POST helper (TLS) – binary host & path
do_gun_post(HostBin, Port, PathBin, Headers, BodyBin) when
    is_binary(HostBin), is_binary(PathBin)
->
    Host = binary_to_list(HostBin),
    case gun:open(Host, Port, #{transport => tls}) of
        {ok, Conn} ->
            try
                {ok, _} = gun:await_up(Conn),
                ?LOG_DEBUG(
                    "POST https://~s~s ~p ~p",
                    [Host, binary_to_list(PathBin), Headers, BodyBin]
                ),
                Ref = gun:request(Conn, <<"POST">>, PathBin, Headers, BodyBin),
                case gun:await(Conn, Ref) of
                    {response, fin, Status, RespHeaders} ->
                        handle_status(Status, RespHeaders, <<>>);
                    {response, nofin, Status, _RespHeaders} ->
                        {ok, RespBody} = gun:await_body(Conn, Ref),
                        handle_status(Status, [], RespBody);
                    Other ->
                        {error, {unexpected, Other}}
                end
            after
                catch gun:shutdown(Conn)
            end;
        {error, Reason} ->
            ?LOG_WARNING("gun open failed: ~p", [Reason]),
            {error, {connect_failed, Reason}}
    end.

%% Generic gun GET helper (TLS) – host as string
do_gun_get(Host, Port, Path, Headers) ->
    case gun:open(Host, Port, #{transport => tls}) of
        {ok, Conn} ->
            try
                {ok, _} = gun:await_up(Conn),
                Ref = gun:request(
                    Conn,
                    <<"GET">>,
                    to_bin(Path),
                    Headers
                ),
                case gun:await(Conn, Ref) of
                    {response, fin, Status, RespHeaders} ->
                        handle_status(Status, RespHeaders, <<>>);
                    {response, nofin, Status, _RespHeaders} ->
                        {ok, RespBody} = gun:await_body(Conn, Ref),
                        handle_status(Status, [], RespBody);
                    Other ->
                        {error, {unexpected, Other}}
                end
            after
                catch gun:shutdown(Conn)
            end;
        {error, Reason} ->
            ?LOG_WARNING("gun open failed: ~p", [Reason]),
            {error, {connect_failed, Reason}}
    end.

handle_status(Code, _Hdrs, Body) when Code =:= 200; Code =:= 201 ->
    ?LOG_INFO("X request success (~p)", [Code]),
    safe_decode_json(Body);
handle_status(Code, _Hdrs, Body) ->
    ?LOG_WARNING("X request failed: ~p ~p", [Code, Body]),
    {error, {http_error, Code, Body}}.

safe_decode_json(<<>>) ->
    %% nothing interesting
    {ok, #{}};
safe_decode_json(Bin) ->
    try
        {ok, jsx:decode(Bin, [return_maps])}
    catch
        _:Err -> {error, Err}
    end.

%% ============================================================
%% Tests
%% ============================================================

test_post_to_twitter() ->
    Event = #{
        id => <<"123fakeidabcdef">>,
        content => <<"Hello world from Nostr → X bridge test!">>
    },
    ?LOG_DEBUG("Posting test tweet..."),
    case post_to_twitter_from_event(Event, undefined) of
        {ok, Resp} ->
            io:format("✅ Success: ~p~n", [Resp]);
        {error, Reason} ->
            io:format("❌ Error: ~p~n", [Reason])
    end.

test_truncate_long_post() ->
    LongText = <<
        "This is a very long test string "
        "to simulate a Nostr event that exceeds the Twitter limit. "
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
        "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. "
        "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. "
        "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. "
        "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
    >>,
    Event = #{id => <<"longfakeid">>, content => LongText},
    Res = post_to_twitter_from_event(Event, undefined),
    io:format("Truncation test result: ~p~n", [Res]).

test_gun_connection() ->
    io:format("Connecting to api.x.com:443 via gun...~n"),
    case gun:open("api.x.com", 443, #{transport => tls}) of
        {ok, ConnPid} ->
            io:format("✅ Gun TLS connection established (~p)~n", [ConnPid]),
            gun:shutdown(ConnPid),
            ok;
        {error, Reason} ->
            io:format("❌ Gun connection failed: ~p~n", [Reason]),
            {error, Reason}
    end.

%% App-only Bearer Token from “Keys and tokens” or POST oauth2/token
get_app_bearer_token() ->
    case secrets:retrieve_decrypt(x_app_bearer_token) of
        {ok, T} when is_binary(T) -> {ok, T};
        {ok, T} when is_list(T) -> {ok, list_to_binary(T)};
        _ ->
            ?LOG_WARNING("x_app_bearer_token (app-only) not configured"),
            {error, no_app_bearer_token}
    end.

get_public_tweets(IdsBin) ->
    {ok, Bearer} = get_app_bearer_token(),
    Host = "api.x.com",
    Path = "/2/tweets?ids=" ++ binary_to_list(IdsBin),
    Headers = [
        {<<"authorization">>, <<"Bearer ", Bearer/binary>>}
    ],
    do_gun_get(Host, 443, Path, Headers).

%%--------------------------------------------------------------------
%% Generate OAuth2 PKCE authorization URL AND open it in the browser.
%%
%% Returns:
%%   {ok, Url, Verifier, State}
%%
%% Url      = Authorization URL user must visit
%% Verifier = PKCE code_verifier (save this!!)
%% State    = random CSRF token (must match after redirect)
%%--------------------------------------------------------------------
auth_url_open() ->
    case build_auth_url() of
        {ok, Url, Verifier, State} ->
            Command = lists:flatten(["xdg-open \"", binary_to_list(Url), "\""]),
            spawn(fun() -> os:cmd(Command) end),
            ?LOG_INFO("Opened browser for X OAuth2 login: ~s", [Url]),
            {ok, Url, Verifier, State};
        Error ->
            Error
    end.
%%--------------------------------------------------------------------
%% Build the OAuth2 PKCE auth URL only (no browser opening).
%%--------------------------------------------------------------------
build_auth_url() ->
    %% Load secrets
    case secrets:retrieve_decrypt(x_client_id) of
        {ok, ClientId0} ->
            ClientId = to_bin(ClientId0),

            %% PKCE (code_verifier + code_challenge)
            {Verifier, Challenge} = pkce_generate(),

            %% anti-CSRF
            State = base64url(crypto:strong_rand_bytes(16)),

            %% Build the authorization URL
            Url = iolist_to_binary([
                "https://x.com/i/oauth2/authorize?",
                "response_type=code",
                "&client_id=",
                ClientId,
                "&redirect_uri=",
                uri_string:quote(?X_REDIRECT_URL),
                "&code_challenge=",
                Challenge,
                "&code_challenge_method=S256",
                "&scope=tweet.read%20tweet.write%20users.read%20offline.access",
                "&state=",
                State
            ]),

            {ok, Url, Verifier, State};
        _ ->
            ?LOG_ERROR("Missing secrets for OAuth2 PKCE (x_client_id or x_redirect_uri)"),
            {error, missing_config}
    end.
%%--------------------------------------------------------------------
%% pkce_generate/0
%% Returns {CodeVerifier, CodeChallenge}
%%
%% CodeVerifier  = high-entropy random string (43–128 chars)
%% CodeChallenge = base64url(sha256(CodeVerifier))
%%--------------------------------------------------------------------
pkce_generate() ->
    %% 32 bytes → 43 chars when base64url-encoded — perfect for PKCE
    Verifier = base64url(crypto:strong_rand_bytes(32)),
    Challenge = pkce_challenge(Verifier),
    {Verifier, Challenge}.

%%--------------------------------------------------------------------
%% Derive the PKCE SHA256 challenge string
%%--------------------------------------------------------------------
pkce_challenge(Verifier) ->
    SHA256 = crypto:hash(sha256, Verifier),
    base64url(SHA256).

%remove_padding(Bin) ->
%    case binary:last(Bin) of
%        $= -> remove_padding(binary:part(Bin, 0, byte_size(Bin)-1));
%        _  -> Bin
%    end.
%%--------------------------------------------------------------------
%% Handle OAuth redirect from X:
%%   - Validates state
%%   - Exchanges code for tokens
%%   - Stores x_user_access_token / x_user_refresh_token
%%--------------------------------------------------------------------
handle_oauth_redirect(StateIn, CodeIn) ->
    case persistent_term:get({x_oauth, state}, undefined) of
        undefined ->
            ?LOG_WARNING("No stored OAuth state; cannot validate redirect"),
            {error, no_stored_state};
        #{state := ExpectedState, verifier := Verifier} ->
            case StateIn =:= ExpectedState of
                false ->
                    ?LOG_WARNING(
                        "State mismatch in X OAuth redirect (~p /= ~p)",
                        [StateIn, ExpectedState]
                    ),
                    {error, state_mismatch};
                true ->
                    %% Exchange code for tokens
                    case exchange_code(CodeIn, Verifier) of
                        {ok, Map} ->
                            case Map of
                                #{
                                    <<"access_token">> := Access,
                                    <<"refresh_token">> := Refresh
                                } ->
                                    ok = secrets:store_encrypt(
                                        x_user_access_token, Access
                                    ),
                                    ok = secrets:store_encrypt(
                                        x_user_refresh_token, Refresh
                                    ),
                                    ?LOG_INFO("Stored X OAuth2 access + refresh tokens"),
                                    ok;
                                _ ->
                                    ?LOG_WARNING("Unexpected token response: ~p", [Map]),
                                    {error, bad_token_response}
                            end;
                        {error, Reason} ->
                            ?LOG_WARNING("Token exchange failed: ~p", [Reason]),
                            {error, Reason}
                    end
            end
    end.
