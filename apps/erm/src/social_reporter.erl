%%%-------------------------------------------------------------------
%%% social_reporter.erl — Discord & Instagram reporting with keyword filters
%%%-------------------------------------------------------------------
-module(social_reporter).
-behaviour(gen_server).
-export([ensure_started/0, now_playing/1]).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").
-include_lib("erm.hrl").

-record(cfg, {
    %% env DISCORD_WEBHOOK_URL
    discord_webhook,
    %% env INSTAGRAM_IG_USER_ID
    ig_user_id,
    %% env INSTAGRAM_ACCESS_TOKEN
    ig_access_token,
    %% env INSTAGRAM_IMAGE_URL_DEFAULT
    ig_image_url_default,
    %% env REPORT_INCLUDE (comma list)
    include_kw = [],
    %% env REPORT_EXCLUDE (comma list)
    exclude_kw = []
}).

ensure_started() ->
    case whereis(?MODULE) of
        undefined -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []);
        _ -> ok
    end.

now_playing(Track) -> gen_server:cast(?MODULE, {now_playing, Track}).

init([]) ->
    application:ensure_all_started(inets),
    Inc = split_env("REPORT_INCLUDE"),
    Exc = split_env("REPORT_EXCLUDE"),
    Cfg = #cfg{
        discord_webhook = os:getenv("DISCORD_WEBHOOK_URL"),
        ig_user_id = os:getenv("INSTAGRAM_IG_USER_ID"),
        ig_access_token = os:getenv("INSTAGRAM_ACCESS_TOKEN"),
        ig_image_url_default = os:getenv(
            "INSTAGRAM_IMAGE_URL_DEFAULT",
            "https://upload.wikimedia.org/wikipedia/commons/3/3f/Placeholder_view_vector.svg"
        ),
        include_kw = Inc,
        exclude_kw = Exc
    },
    put(cfg, Cfg),
    {ok, Cfg}.

handle_cast({now_playing, T}, Cfg = #cfg{}) ->
    Title = filename:basename(T#track.path),
    Text = io_lib:format("Now Playing: ~s", [Title]),
    case allowed(Title, Cfg) of
        true ->
            maybe_discord(Text, T, Cfg),
            maybe_instagram(Text, T, Cfg),
            {noreply, Cfg};
        false ->
            {noreply, Cfg}
    end;
handle_cast(_, S) ->
    {noreply, S}.

handle_call(_Req, _From, S) -> {reply, ok, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

allowed(Title, #cfg{include_kw = [], exclude_kw = Exc}) ->
    not has_any(Title, Exc);
allowed(Title, #cfg{include_kw = Inc, exclude_kw = Exc}) ->
    has_any(Title, Inc) andalso not has_any(Title, Exc).

has_any(Title, []) ->
    false;
has_any(Title, [K | Ks]) ->
    case string:find(string:lowercase(Title), string:lowercase(K)) of
        nomatch -> has_any(Title, Ks);
        _ -> true
    end.

split_env(Name) ->
    case os:getenv(Name) of
        false -> [];
        "" -> [];
        Str -> [string:trim(S) || S <- string:tokens(Str, ",")]
    end.

maybe_discord(Text, Track, #cfg{discord_webhook = undefined}) ->
    ok;
maybe_discord(Text, Track, #cfg{discord_webhook = Url}) ->
    %% Compose embed with optional IPFS link
    Cid = Track#track.cid,
    Link =
        case Cid of
            undefined -> "";
            C -> ipfs_client:gateway_url(C)
        end,
    Payload = jsx:encode(#{
        <<"content">> => list_to_binary(Text),
        <<"embeds">> => [
            #{
                <<"title">> => list_to_binary(filename:basename(Track#track.path)),
                <<"url">> => list_to_binary(Link)
            }
        ]
    }),
    httpc:request(
        post, {Url, [{"Content-Type", "application/json"}], "application/json", Payload}, [], []
    ),
    ok.

maybe_instagram(_Text, _Track, #cfg{ig_user_id = undefined}) ->
    ok;
maybe_instagram(Text, Track, #cfg{
    ig_user_id = Uid, ig_access_token = Tok, ig_image_url_default = Img
}) ->
    %% Instagram requires an image/video; we post an image with caption.
    Caption =
        case Track#track.cid of
            undefined ->
                Text;
            C ->
                lists:flatten(
                    io_lib:format(
                        "~s\n"
                        "IPFS: ~s",
                        [Text, ipfs_client:gateway_url(C)]
                    )
                )
        end,
    MediaUrl = Img,
    CreateUrl = lists:flatten(
        io_lib:format(
            "https://graph.facebook.com/v21.0/~s/media?image_url=~s&caption=~s&access_token=~s", [
                Uid, uri_string:quote(MediaUrl), uri_string:quote(Caption), Tok
            ]
        )
    ),
    PubUrl = lists:flatten(
        io_lib:format(
            "https://graph.facebook.com/v21.0/~s/media_publish?creation_id=~s&access_token=~s", [
                Uid, "{CREATION_ID}", Tok
            ]
        )
    ),
    case httpc:request(post, {CreateUrl, [], "application/json", <<>>}, [], []) of
        {ok, {{_, 200, _}, _, Body}} ->
            #{<<"id">> := CreationId} = jsx:decode(Body, [return_maps]),
            PubFin = re:replace(PubUrl, "\{CREATION_ID\}", binary_to_list(CreationId), [
                {return, list}
            ]),
            _ = httpc:request(post, {PubFin, [], "application/json", <<>>}, [], []),
            ok;
        Err ->
            ?LOG_INFO("IG create failed ~p", [Err]),
            ok
    end.
