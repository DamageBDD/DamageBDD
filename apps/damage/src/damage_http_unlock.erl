%%--------------------------------------------------------------------
%% Handler: damage_http_unlock
%%
%% Render and accept set/unlock node password flows:
%%  - If secrets:has_node_password() == false -> show set_node_password.mustache
%%    (requires password + confirmation; validated by damage_accounts:validate_password/1)
%%  - If secrets:has_node_password() == true  -> show unlock_node.mustache (single password)
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
    case secrets:has_node_password() of
        false ->
            %% No password cached ⇒ first-run / set flow
            Body = damage_utils:load_template("set_node_password.mustache", #{}),
            {Body, Req, State};
        true ->
            %% Password exists (or we want user to unlock) ⇒ unlock flow
            Body = damage_utils:load_template("unlock_node.mustache", #{}),
            {Body, Req, State}
    end.

to_json(Req, State) ->
    %% Simple status endpoint
    Has = secrets:has_node_password(),
    {jsx:encode(#{status => <<"ok">>, has_node_password => Has}), Req, State}.
unlock_node(Password) ->
    secrets:set_node_password(Password),
    case secrets:node_keypair() of
        #{public_key := _PubKey, private_key := _NodePrivateKey} ->
            %% set flow: require confirmation and validate password strength
            #{status => <<"ok">>, message => <<"node unlocked">>};
        {error, decrypt_keypair} ->
            #{status => <<"failed">>, message => <<"decrypt node wallet failed">>}
    end.
%% Validate and set node password (set_password flow)
set_password(PasswordBin, ConfirmBin) ->
    case secrets:node_keypair() of
        #{public_key := _PubKey, private_key := _NodePrivateKey} ->
            %% set flow: require confirmation and validate password strength
            #{status => <<"error">>, message => <<"node keypair already initialized">>};
        {error, keypair_not_initialized} ->
            case PasswordBin of
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
                                    secrets:set_node_password(PasswordBin),

                                    #{public_key := _PubKey, private_key := _NodePrivateKey} = secrets:node_keypair(),
                                    #{status => <<"ok">>, message => <<"node password set">>};
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
    Reply = cowboy_req:set_resp_body(
        jsx:encode(Response),
        Req
    ),
    %% Let cowboy_rest finish with this response
    {stop, Reply, State};
%% Accept form submits (browser)
from_html(Req0, #{action := unlock} = State) ->
    {ok, BodyBin, Req} = cowboy_req:read_body(Req0),
    Form = cow_qs:parse_qs(BodyBin),
    %% expected fields:
    %% - password
    %% - password_confirm (optional, for set flow)
    Password = proplists:get_value(<<"password">>, Form, <<>>),
    Response = unlock_node(Password),
    Reply = cowboy_req:set_resp_body(
        jsx:encode(Response),
        Req
    ),
    {stop, Reply, State}.

%% Accept JSON posts too (API) - set password
from_json(Req0, #{action := set_password} = State) ->
    {ok, DataBin, Req} = cowboy_req:read_body(Req0),
    case catch jsx:decode(DataBin, [return_maps, {labels, atom}]) of
        {'EXIT', _} ->
            Reply0 = cowboy_req:set_resp_body(
                jsx:encode(#{status => <<"failed">>, message => <<"json decode error">>}),
                Req
            ),
            cowboy_req:reply(400, Reply0),
            {stop, Reply0, State};
        Decoded when is_map(Decoded) ->
            Password = maps:get(password, Decoded, undefined),
            Confirm = maps:get(password_confirm, Decoded, undefined),
            Response = set_password(Password, Confirm),
            StatusCode =
                case Response of
                    #{status := <<"ok">>} -> 200;
                    _ -> 400
                end,
            Reply1 = cowboy_req:set_resp_body(
                jsx:encode(Response),
                Req
            ),
            cowboy_req:reply(StatusCode, Reply1),
            {stop, Reply1, State}
    end;
%% Accept JSON posts too (API)
from_json(Req0, #{action := unlock} = State) ->
    {ok, DataBin, Req} = cowboy_req:read_body(Req0),
    case catch jsx:decode(DataBin, [return_maps, {labels, atom}]) of
        {'EXIT', _} ->
            Reply = cowboy_req:set_resp_body(
                jsx:encode(#{status => <<"failed">>, message => <<"json decode error">>}), Req
            ),
            cowboy_req:reply(400, Reply),
            {stop, Reply, State};
        Decoded when is_map(Decoded) ->
            Password = maps:get(password, Decoded, undefined),
            Response = unlock_node(Password),
            Reply = cowboy_req:set_resp_body(
                jsx:encode(Response),
                Req
            ),
            cowboy_req:reply(200, Reply),
            {stop, Reply, State}
    end.
