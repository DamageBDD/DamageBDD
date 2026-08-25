%%--------------------------------------------------------------------
%% Handler: damage_http_unlock
%%
%% Render and accept set/unlock node password flows:
%%  - If no node keypair exists -> show set_node_password.mustache
%%    (requires password + confirmation; validated by damage_accounts:validate_password/1)
%%  - If a node keypair exists -> show unlock_node.mustache (single password)
%%
%% POST (form/json) attempts secrets:set_node_password(Password).
%%  - on success -> 200 + {status => "ok"}
%%  - on failure -> 400 + {status=>"failed", message => Reason}
%%
%% Note: secrets:set_node_password/1 sets the node password into the secrets gen_server
%%       (it will return {error, already_set} if the gen_server already has the password).
%%
%%--------------------------------------------------------------------
-module(damage_http_unlock).

-author("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% cowboy_rest callbacks
-export([
    init/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    is_authorized/2,
    to_html/2,
    to_json/2,
    from_html/2,
    from_json/2
]).
-export([trails/0]).

-define(TRAILS_TAG, ["Scheduling Tests"]).

trails() ->
    [
        trails:trail(
            "/secrets/unlock",
            damage_http_unlock,
            #{action => unlock},
            #{
                get => #{produces => ["text/html"]},
                post => #{produces => ["application/json", "text/html"]}
            }
        ),
        trails:trail(
            "/secrets/set_password",
            damage_http_unlock,
            #{action => set_password},
            #{
                get => #{produces => ["text/html"]},
                post => #{produces => ["application/json", "text/html"]}
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {
        [
            {{<<"text">>, <<"html">>, '*'}, to_html},
            {{<<"application">>, <<"json">>, []}, to_json}
        ],
        Req,
        State
    }.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, from_json},
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
            {{<<"text">>, <<"plain">>, '*'}, from_html}
        ],
        Req,
        State
    }.
%%--------------------------------------------------------------------
%% ensure_localhost/1
%%--------------------------------------------------------------------
%% Returns {ok, Req} if client is 127.0.0.1 / ::1, else {forbidden, Req}
%%--------------------------------------------------------------------
%ensure_localhost(Req) ->
%    case cowboy_req:peer(Req) of
%        {{127, 0, 0, 1}, _Port} ->
%            {ok, Req};
%        {{0, 0, 0, 0, 0, 0, 0, 1}, _Port} ->
%            {ok, Req};
%        {PeerAddr, _Port} ->
%            ?LOG_WARNING("Blocked non-localhost request from ~p", [PeerAddr]),
%            {forbidden, Req}
%    end.
%
%is_authorized(Req0, State) ->
%    case ensure_localhost(Req0) of
%        {ok, Req} ->
%            {true, Req, State};
%        {forbidden, Req} ->
%            Body = jsx:encode(#{status => <<"forbidden">>, message => <<"localhost only">>}),
%            Req2 = cowboy_req:set_resp_body(Body, Req),
%            Req3 = cowboy_req:reply(403, Req2),
%            {stop, Req3, State}
%    end.
is_authorized(Req, State) ->
    {true, Req, State}.

%% Render HTML page depending on whether a password is present/cached
to_html(Req, State) ->
    case secrets:has_node_keypair() of
        false ->
            %% No keystore yet => first-run / set flow.
            Body = damage_utils:load_template("set_node_password.mustache", #{}),
            {Body, Req, State};
        true ->
            %% Existing keystore => unlock flow, even while password is not cached.
            Body = damage_utils:load_template("unlock_node.mustache", #{}),
            {Body, Req, State}
    end.

to_json(Req, State) ->
    %% Simple status endpoint
    Has = secrets:has_node_password(),
    {jsx:encode(#{status => <<"ok">>, has_node_password => Has}), Req, State}.
unlock_node(Password) ->
    case secrets:has_node_keypair() of
        false ->
            #{status => <<"failed">>, message => <<"node keypair not initialized">>};
        true ->
            case secrets:set_node_password(Password) of
                ok ->
                    case secrets:node_keypair() of
                        #{public_key := _PubKey, private_key := _NodePrivateKey} ->
                            #{status => <<"ok">>, message => <<"node unlocked">>};
                        {error, _} ->
                            #{status => <<"failed">>, message => <<"decrypt node wallet failed">>}
                    end;
                {error, password_required} ->
                    #{status => <<"failed">>, message => <<"password required">>};
                {error, invalid_password} ->
                    #{status => <<"failed">>, message => <<"invalid node password">>};
                {error, _} ->
                    #{status => <<"failed">>, message => <<"invalid node password">>}
            end
    end.
%% Validate and set node password (set_password flow)
set_password(PasswordBin, ConfirmBin) ->
    case secrets:has_node_keypair() of
        true ->
            #{status => <<"error">>, message => <<"node keypair already initialized">>};
        false ->
            case PasswordBin of
                undefined ->
                    #{status => <<"failed">>, message => <<"password required">>};
                <<>> ->
                    #{status => <<"failed">>, message => <<"password required">>};
                _ ->
                    case PasswordBin =:= ConfirmBin of
                        false ->
                            #{status => <<"failed">>, message => <<"passwords do not match">>};
                        true ->
                            %% Validate strength via accounts module
                            case damage_accounts:validate_password(PasswordBin) of
                                true ->
                                    %% Reuse unlock_node/1 to:
                                    %%  - cache password in secrets
                                    %%  - create/decrypt node keypair
                                    ok = secrets:set_node_password(PasswordBin),
                                    case secrets:node_keypair() of
                                        #{public_key := _PubKey, private_key := _NodePrivateKey} ->
                                            #{
                                                status => <<"ok">>,
                                                message => <<"node password set">>
                                            };
                                        {error, _} ->
                                            #{
                                                status => <<"failed">>,
                                                message => <<"node keypair initialization failed">>
                                            }
                                    end;
                                {error, Reason} ->
                                    #{
                                        status => <<"failed">>,
                                        message => <<"invalid password">>,
                                        reason => Reason
                                    };
                                Other ->
                                    #{
                                        status => <<"failed">>,
                                        message => <<"invalid password">>,
                                        reason => Other
                                    }
                            end
                    end
            end
    end.

%% Accept form submits (browser) - set password
from_html(Req0, #{action := set_password} = State) ->
    {ok, BodyBin, Req} = cowboy_req:read_body(Req0),
    Form = cow_qs:parse_qs(BodyBin),
    %% expected fields:
    %% - password
    %% - password_confirm
    Password = proplists:get_value(<<"password">>, Form, <<>>),
    Confirm = proplists:get_value(<<"password_confirm">>, Form, <<>>),
    Response = set_password(Password, Confirm),
    reply_response(Response, Req, State);
%% Accept form submits (browser)
from_html(Req0, #{action := unlock} = State) ->
    {ok, BodyBin, Req} = cowboy_req:read_body(Req0),
    Form = cow_qs:parse_qs(BodyBin),
    %% expected fields:
    %% - password
    %% - password_confirm (optional, for set flow)
    Password = proplists:get_value(<<"password">>, Form, <<>>),
    Response = unlock_node(Password),
    reply_response(Response, Req, State).

%% Accept JSON posts too (API) - set password
from_json(Req0, #{action := set_password} = State) ->
    {ok, DataBin, Req} = cowboy_req:read_body(Req0),
    try jsx:decode(DataBin, [return_maps, {labels, atom}]) of
        Decoded when is_map(Decoded) ->
            Password = maps:get(password, Decoded, undefined),
            Confirm = maps:get(password_confirm, Decoded, undefined),
            Response = set_password(Password, Confirm),
            reply_response(Response, Req, State)
    catch
        _Class:_Reason:_Stack ->
            json_decode_error(Req, State)
    end;
%% Accept JSON posts too (API)
from_json(Req0, #{action := unlock} = State) ->
    {ok, DataBin, Req} = cowboy_req:read_body(Req0),
    try jsx:decode(DataBin, [return_maps, {labels, atom}]) of
        Decoded when is_map(Decoded) ->
            Password = maps:get(password, Decoded, undefined),
            Response = unlock_node(Password),
            reply_response(Response, Req, State);
        _ ->
            json_decode_error(Req, State)
    catch
        _Class:_Reason:_Stack ->
            json_decode_error(Req, State)
    end.

json_decode_error(Req, State) ->
    reply_response(
        #{status => <<"failed">>, message => <<"json decode error">>},
        Req,
        State
    ).

reply_response(Response, Req, State) ->
    StatusCode =
        case Response of
            #{status := <<"ok">>} -> 200;
            _ -> 400
        end,
    Req1 = cowboy_req:reply(
        StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Response),
        Req
    ),

    {stop, Req1, State}.
