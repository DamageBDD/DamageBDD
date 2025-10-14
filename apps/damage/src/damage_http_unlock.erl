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
         get => #{ produces => ["text/html"] },
         post => #{ produces => ["application/json","text/html"] }
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
ensure_localhost(Req) ->
    case cowboy_req:peer(Req) of
        {{127,0,0,1}, _Port} ->
            {ok, Req};
        {{0,0,0,0,0,0,0,1}, _Port} ->
            {ok, Req};
        {PeerAddr, _Port} ->
            ?LOG_WARNING("Blocked non-localhost request from ~p", [PeerAddr]),
            {forbidden, Req}
    end.

is_authorized(Req0, State) ->
    case ensure_localhost(Req0) of
        {ok, Req} ->
            {true, Req, State};
        {forbidden, Req} ->
            Body = jsx:encode(#{status => <<"forbidden">>, message => <<"localhost only">>}),
            Req2 = cowboy_req:set_resp_body(Body, Req),
            Req3 = cowboy_req:reply(403, Req2),
            {stop, Req3, State}
    end.


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

%% Accept form submits (browser)
from_html(Req0, State) ->
    {ok, BodyBin, Req} = cowboy_req:read_body(Req0),
    Form = cow_qs:parse_qs(BodyBin),
    %% expected fields:
    %% - password
    %% - password_confirm (optional, for set flow)
    Password = proplists:get_value(<<"password">>, Form, <<>>),
    PasswordConfirm = proplists:get_value(<<"password_confirm">>, Form, <<>>),

    case secrets:has_node_password() of
        false ->
            %% set flow: require confirmation and validate password strength
            case {Password, PasswordConfirm} of
                {<<>>, _} ->
                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password required">>}), Req),
                    cowboy_req:reply(400, Reply),
                    {stop, Reply, State};
                {_, <<>>} ->
                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password confirmation required">>}), Req),
                    cowboy_req:reply(400, Reply),
                    {stop, Reply, State};
                {P, PC} when P =/= PC ->
                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"passwords do not match">>}), Req),
                    cowboy_req:reply(400, Reply),
                    {stop, Reply, State};
                {P, P} ->
                    %% validate strength using existing helper
                    case damage_accounts:validate_password(binary_to_list(P)) of
                        true ->
                            case secrets:set_node_password(binary_to_list(P)) of
                                ok ->
                                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
                                    cowboy_req:reply(200, Reply),
                                    {stop, Reply, State};
                                {error, already_set} ->
                                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"node password already set in process">>}), Req),
                                    cowboy_req:reply(400, Reply),
                                    {stop, Reply, State};
                                {error, too_short} ->
                                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password too short">>}), Req),
                                    cowboy_req:reply(400, Reply),
                                    {stop, Reply, State};
                                Other ->
                                    ?LOG_ERROR("set_node_password unexpected result: ~p", [Other]),
                                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"internal error">>}), Req),
                                    cowboy_req:reply(500, Reply),
                                    {stop, Reply, State}
                            end;
                        false ->
                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password does not meet complexity requirements">>}), Req),
                            cowboy_req:reply(400, Reply),
                            {stop, Reply, State}
                    end
            end;
        true ->
            %% unlock flow: single password submit - we attempt to set the password in the secrets gen_server cache
            case Password of
                <<>> ->
                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password required">>}), Req),
                    cowboy_req:reply(400, Reply),
                    {stop, Reply, State};
                P ->
                    case secrets:set_node_password(binary_to_list(P)) of
                        ok ->
                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>, message => <<"unlocked">>}), Req),
                            cowboy_req:reply(200, Reply),
                            {stop, Reply, State};
                        {error, already_set} ->
                            %% If the secrets gen_server already has node_password, we treat it as success
                            %% (already unlocked in process). But if the provided password is wrong (we can't verify easily),
                            %% return a friendly message asking to clear cache and try again.
                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"already unlocked in this process or invalid password">>}), Req),
                            cowboy_req:reply(400, Reply),
                            {stop, Reply, State};
                        {error, too_short} ->
                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password too short">>}), Req),
                            cowboy_req:reply(400, Reply),
                            {stop, Reply, State};
                        Other ->
                            ?LOG_ERROR("unlock unexpected result: ~p", [Other]),
                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"internal error">>}), Req),
                            cowboy_req:reply(500, Reply),
                            {stop, Reply, State}
                    end
            end
    end.

%% Accept JSON posts too (API)
from_json(Req0, State) ->
    {ok, DataBin, Req} = cowboy_req:read_body(Req0),
    case catch jsx:decode(DataBin, [return_maps, {labels, atom}]) of
        {'EXIT', _} ->
            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"json decode error">>}), Req),
            cowboy_req:reply(400, Reply),
            {stop, Reply, State};
        Decoded when is_map(Decoded) ->
            Password = maps:get(password, Decoded, undefined),
            PasswordConfirm = maps:get(password_confirm, Decoded, undefined),
            case secrets:has_node_password() of
                false ->
                    %% set flow
                    case {Password, PasswordConfirm} of
                        {undefined, _} ->
                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password required">>}), Req),
                            cowboy_req:reply(400, Reply),
                            {stop, Reply, State};
                        {_P, undefined} ->
                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password_confirm required">>}), Req),
                            cowboy_req:reply(400, Reply),
                            {stop, Reply, State};
                        {P, PC} when P =/= PC ->
                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"passwords do not match">>}), Req),
                            cowboy_req:reply(400, Reply),
                            {stop, Reply, State};
                        {P, P} ->
                            case damage_accounts:validate_password(binary_to_list(P)) of
                                true ->
                                    case secrets:set_node_password(binary_to_list(P)) of
                                        ok ->
                                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
                                            cowboy_req:reply(200, Reply),
                                            {stop, Reply, State};
                                        {error, already_set} ->
                                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"already_set">>}), Req),
                                            cowboy_req:reply(400, Reply),
                                            {stop, Reply, State};
                                        {error, too_short} ->
                                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"too_short">>}), Req),
                                            cowboy_req:reply(400, Reply),
                                            {stop, Reply, State};
                                        Other ->
                                            ?LOG_ERROR("set_node_password json unexpected: ~p", [Other]),
                                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"internal error">>}), Req),
                                            cowboy_req:reply(500, Reply),
                                            {stop, Reply, State}
                                    end;
                                false ->
                                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password requirements not met">>}), Req),
                                    cowboy_req:reply(400, Reply),
                                    {stop, Reply, State}
                            end
                    end;
                true ->
                    %% unlock flow
                    case Password of
                        undefined ->
                            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"password required">>}), Req),
                            cowboy_req:reply(400, Reply),
                            {stop, Reply, State};
                        P ->
                            case secrets:set_node_password(binary_to_list(P)) of
                                ok ->
                                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>, message => <<"unlocked">>}), Req),
                                    cowboy_req:reply(200, Reply),
                                    {stop, Reply, State};
                                {error, already_set} ->
                                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"already_unlocked_or_invalid">>}), Req),
                                    cowboy_req:reply(400, Reply),
                                    {stop, Reply, State};
                                {error, too_short} ->
                                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"too_short">>}), Req),
                                    cowboy_req:reply(400, Reply),
                                    {stop, Reply, State};
                                Other ->
                                    ?LOG_ERROR("unlock json unexpected: ~p", [Other]),
                                    Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"internal error">>}), Req),
                                    cowboy_req:reply(500, Reply),
                                    {stop, Reply, State}
                            end
                    end
            end;
        _ ->
            Reply = cowboy_req:set_resp_body(jsx:encode(#{status => <<"failed">>, message => <<"bad request">>}), Req),
            cowboy_req:reply(400, Reply),
            {stop, Reply, State}
    end.
