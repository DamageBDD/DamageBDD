-module(steps_syncthing).

-author("Steven Joseph <steven@stevenjoseph.in>").

-include_lib("kernel/include/logger.hrl").
%% Adjust path if your damage include lives elsewhere
%-include_lib("damage/include/damage.hrl").
-include_lib("damage.hrl").

-export([step/6]).

%% -------------------------------------------------------------------
%% Step patterns
%% -------------------------------------------------------------------

-define(STEP_SYN_BASE_URL,        ["I am using syncthing at", Url]).
-define(STEP_SYN_API_KEY,         ["I set syncthing api key to", ApiKey]).
-define(STEP_SYN_ADD_DEVICE,      ["I add syncthing device", DeviceId, "named", Name]).
-define(STEP_SYN_SHARE_FOLDER,    ["I share folder", FolderId, "at path", FolderPath, "named", Label, "with device", DeviceId]).
-define(STEP_SYN_ADD_DEV_TO_FOLD, ["I add device", DeviceId, "to syncthing folder", FolderId]).
-define(STEP_SYN_STATUS,          ["the syncthing response status must be", Status]).

%% -------------------------------------------------------------------
%% Public BDD step entry point
%% -------------------------------------------------------------------

-spec step(
    proplists:proplist(),
    map(),
    binary(),
    non_neg_integer(),
    list(),
    term()
) -> {ok, map()} | {error, term()} | undefined.

%% Base URL
step(_Config, Context, _Keyword, _Line, ?STEP_SYN_BASE_URL, _Args) ->
    {ok, set_syncthing_base_url(Context, Url)};

%% API key
step(_Config, Context, _Keyword, _Line, ?STEP_SYN_API_KEY, _Args) ->
    {ok, set_syncthing_api_key(Context, ApiKey)};

%% Add/update a device in Syncthing config
step(Config, Context, _Keyword, _Line, ?STEP_SYN_ADD_DEVICE, _Args) ->
    DeviceIdBin = to_bin(DeviceId),
    NameBin     = to_bin(Name),
    Body = #{
        <<"deviceID">> => DeviceIdBin,
        <<"name">>     => NameBin
    },
    Path = "/rest/config/devices",
    case syncthing_request(Config, Context, post, Path, Body) of
        {ok, Resp} ->
            {ok, Context#{last_syncthing_response => Resp}};
        Error ->
            ?LOG_ERROR("Syncthing add device failed: ~p", [Error]),
            Error
    end;

%% Create/share a folder with a device (POST /rest/config/folders)
step(Config, Context, _Keyword, _Line, ?STEP_SYN_SHARE_FOLDER, _Args) ->
    FolderIdBin   = to_bin(FolderId),
    FolderPathBin = to_bin(FolderPath),
    LabelBin      = to_bin(Label),
    DeviceIdBin   = to_bin(DeviceId),

    Body = #{
        <<"id">>      => FolderIdBin,
        <<"label">>   => LabelBin,
        <<"path">>    => FolderPathBin,
        <<"type">>    => <<"sendreceive">>,
        <<"devices">> => [#{<<"deviceID">> => DeviceIdBin}]
    },

    Path = "/rest/config/folders",
    case syncthing_request(Config, Context, post, Path, Body) of
        {ok, Resp} ->
            {ok, Context#{last_syncthing_response => Resp}};
        Error ->
            ?LOG_ERROR("Syncthing share folder failed: ~p", [Error]),
            Error
    end;

%% Add a device to an existing folder (PATCH /rest/config/folders/<id>)
step(Config, Context, _Keyword, _Line, ?STEP_SYN_ADD_DEV_TO_FOLD, _Args) ->
    FolderIdBin = to_bin(FolderId),
    DeviceIdBin = to_bin(DeviceId),

    FolderPath =
        "/rest/config/folders/" ++ binary_to_list(FolderIdBin),

    %% 1. Get current folder config
    case syncthing_request(Config, Context, get, FolderPath, undefined) of
        {ok, #{status := 200, body := BodyBin}} ->
            case jsx:decode(BodyBin, [return_maps]) of
                FolderMap when is_map(FolderMap) ->
                    Devices0 = maps:get(<<"devices">>, FolderMap, []),
                    Devices1 = ensure_device_in_list(DeviceIdBin, Devices0),
                    PatchBody = #{<<"devices">> => Devices1},
                    %% 2. PATCH back just the devices array
                    case syncthing_request(Config, Context, patch, FolderPath, PatchBody) of
                        {ok, Resp2} ->
                            {ok, Context#{last_syncthing_response => Resp2}};
                        Error2 ->
                            ?LOG_ERROR("Syncthing PATCH folder devices failed: ~p", [Error2]),
                            Error2
                    end;
                DecodeError ->
                    ?LOG_ERROR("Failed to decode folder JSON: ~p", [DecodeError]),
                    {error, decode_error}
            end;
        {ok, Resp = #{status := Status}} ->
            ?LOG_ERROR("Unexpected status when GET folder: ~p", [Resp]),
            {error, {unexpected_status, Status}};
        Error ->
            ?LOG_ERROR("Syncthing GET folder failed: ~p", [Error]),
            Error
    end;

%% Assert last response status code
step(_Config, Context, _Keyword, _Line, ?STEP_SYN_STATUS, _Args) ->
    case maps:get(last_syncthing_response, Context, undefined) of
        #{status := StatusCode} ->
            Expected = list_to_integer(Status),
            case StatusCode of
                Expected ->
                    {ok, Context};
                _Other ->
                    {error, {status_mismatch, Expected, StatusCode}}
            end;
        undefined ->
            {error, no_syncthing_response}
    end;

%% If the step does not match anything in this module, let another module try.
step(_Config, _Context, _Keyword, _Line, _Step, _Args) ->
    undefined.

%% -------------------------------------------------------------------
%% Helpers
%% -------------------------------------------------------------------

set_syncthing_base_url(Context, UrlList) when is_list(UrlList) ->
    Context#{syncthing_base_url => UrlList};
set_syncthing_base_url(Context, UrlBin) when is_binary(UrlBin) ->
    Context#{syncthing_base_url => binary_to_list(UrlBin)}.

set_syncthing_api_key(Context, ApiKeyList) when is_list(ApiKeyList) ->
    Context#{syncthing_api_key => ApiKeyList};
set_syncthing_api_key(Context, ApiKeyBin) when is_binary(ApiKeyBin) ->
    Context#{syncthing_api_key => binary_to_list(ApiKeyBin)}.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L)   -> list_to_binary(L).

default_port(<<"http">>)  -> 8384;
default_port(<<"https">>) -> 8384;
default_port(_)           -> 8384.

get_syncthing_base(Context) ->
    maps:get(syncthing_base_url, Context, "http://127.0.0.1:8384").

get_syncthing_headers(Context) ->
    ApiKey = maps:get(syncthing_api_key, Context, undefined),
    Base   = [{<<"Accept">>, <<"application/json">>}],
    case ApiKey of
        undefined ->
            Base;
        AK when is_binary(AK) ->
            [{<<"X-API-Key">>, AK} | Base];
        AKList when is_list(AKList) ->
            [{<<"X-API-Key">>, list_to_binary(AKList)} | Base]
    end.

add_ct_json(Headers) ->
    [{<<"Content-Type">>, <<"application/json">>} | Headers].

ensure_device_in_list(DeviceIdBin, Devices0) ->
    Already =
        lists:any(
          fun(#{<<"deviceID">> := D}) -> D =:= DeviceIdBin;
             (_)                      -> false
          end,
          Devices0
        ),
    case Already of
        true  -> Devices0;
        false -> Devices0 ++ [#{<<"deviceID">> => DeviceIdBin}]
    end.

%% -------------------------------------------------------------------
%% Low-level Syncthing HTTP helper (gun-based)
%% -------------------------------------------------------------------

-type syn_method() :: get | post | patch.

-spec syncthing_request(
    proplists:proplist(),
    map(),
    syn_method(),
    string(),
    map() | undefined
) -> {ok, #{status := integer(), headers := list(), body := binary()}}
   | {error, term()}.
syncthing_request(_Config, Context, Method, Path, Body) ->
    Base  = get_syncthing_base(Context),
    %% uri_string:parse/1 accepts list or binary
    {ok, Parsed} = uri_string:parse(Base),
    HostBin = maps:get(host, Parsed, <<"127.0.0.1">>),
    Host    = binary_to_list(HostBin),
    Scheme  = maps:get(scheme, Parsed, <<"http">>),
    Port0   = maps:get(port, Parsed, undefined),
    Port    = case Port0 of undefined -> default_port(Scheme); P -> P end,
    Transport =
        case Scheme of
            <<"https">> -> tls;
            _           -> tcp
        end,

    ConnOpts = #{transport => Transport, protocols => [http]},
    case gun:open(Host, Port, ConnOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid) of
                {ok, _Proto} ->
                    do_syncthing_request(ConnPid, Context, Method, Path, Body);
                Error ->
                    gun:shutdown(ConnPid),
                    {error, Error}
            end;
        Error ->
            {error, Error}
    end.

do_syncthing_request(ConnPid, Context, Method, Path, Body) ->
    Headers0 = get_syncthing_headers(Context),
    {StreamRef, _Headers1} =
        case Method of
            get ->
                {gun:get(ConnPid, Path, Headers0), Headers0};
            post ->
                BinBody = jsx:encode(Body),
                H1 = add_ct_json(Headers0),
                {gun:post(ConnPid, Path, H1, BinBody), H1};
            patch ->
                BinBody = jsx:encode(Body),
                H1 = add_ct_json(Headers0),
                {gun:request(ConnPid, <<"PATCH">>, Path, H1, BinBody), H1}
        end,
    case gun:await(ConnPid, StreamRef, 60000) of
        {response, nofin, Status, RespHeaders} ->
            case gun:await_body(ConnPid, StreamRef, 60000) of
                {ok, BodyBin} ->
                    gun:shutdown(ConnPid),
                    {ok, #{status => Status, headers => RespHeaders, body => BodyBin}};
                Err ->
                    gun:shutdown(ConnPid),
                    {error, Err}
            end;
        {response, fin, Status, RespHeaders} ->
            gun:shutdown(ConnPid),
            {ok, #{status => Status, headers => RespHeaders, body => <<>>}};
        Other ->
            gun:shutdown(ConnPid),
            {error, Other}
    end.
