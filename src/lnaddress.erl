-module(lnaddress).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Damage LN Address resolver"]).

trails() ->
    [
        trails:trail(
            "/.well-known/lnurlp/:user",
            lnaddress,
            #{action => lnurlp},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "resolve lnurl.",
                        produces => ["text/html"]
                    }
            }
        ),
        trails:trail(
            "/.well-known/nostr.json?name=:user",
            lnaddress,
            #{action => nip05},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "resolve lnurl.",
                        produces => ["text/html"]
                    }
            }
        ),
        trails:trail(
            "/pay/:user/",
            lnaddress,
            #{action => invoice},
            #{
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "pay user.",
                        produces => ["text/html"]
                    }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
            {{<<"application">>, <<"x-yaml">>, '*'}, from_yaml},
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

to_json(Req, #{action := lnurlp} = State) ->
    case cowboy_req:binding(user, Req) of
        undefined ->
            {<<"user">>, Req, State};
        User ->
            {ok, ApiUrl} = application:get_env(damage, lnpay_host),
            {
                jsx:encode(
                    #{
                        tag => <<"payRequest">>,
                        callback =>
                            damage_utils:binarystr_join(
                                [list_to_binary(ApiUrl), <<"/pay/">>, User]
                            )
                    }
                ),
                Req,
                State
            }
    end;
to_json(Req, #{action := nip05} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    case maps:from_list(cow_qs:parse_qs(Data)) of
        #{name := Name} ->
            ?LOG_INFO("Nip05 request ~p", [Name]),
            PublicKeys = damage_nostr:get_public_keys(Name),
            {jsx:encode(#{names => PublicKeys}), Req, State};
        Unexpected ->
            ?LOG_INFO("invalid Nip05 request ~p", [Unexpected]),
            {jsx:encode(#{names => []}), Req, State}
    end;
to_json(Req, #{action := invoice} = State) ->
    case cowboy_req:binding(user, Req) of
        undefined ->
            {<<"user required">>, Req, State};
        <<"asyncmind">> ->
            case cowboy_req:match_qs([{comment, [], none}, {amount, [], none}], Req) of
                #{amount := none, comment := Memo} ->
                    Amount = 1000,
                    #{
                        payment_hash := _PaymentHash,
                        expires_at := _Expiry,
                        bolt11 := Bolt11,
                        payment_secret := _PaymentSecret,
                        created_index := _CreatedIndex
                    } = Invoice = cln:create_invoice(Amount, Memo),
                    ?LOG_INFO("invoice ~p", [Invoice]),
                    {jsx:encode(#{pr => Bolt11}), Req, State};
                #{amount := AmountBin, comment := Memo} ->
                    Amount = binary_to_integer(AmountBin),
                    #{
                        payment_hash := _PaymentHash,
                        expires_at := _Expiry,
                        bolt11 := Bolt11,
                        payment_secret := _PaymentSecret,
                        created_index := _CreatedIndex
                    } = Invoice = cln:create_invoice(Amount, Memo),
                    ?LOG_INFO("invoice ~p", [Invoice]),
                    {jsx:encode(#{pr => Bolt11}), Req, State};
                Unexpected ->
                    ?LOG_INFO("invalid invoice request ~p", [Unexpected]),
                    {jsx:encode(#{names => []}), Req, State}
            end
    end.

from_html(Req, #{action := reset_password} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    Data0 = maps:from_list(cow_qs:parse_qs(Data)),
    {Status0, Response0} =
        case damage_oauth:reset_password(Data0) of
            {ok, Message} ->
                {ok, ApiUrl} = application:get_env(damage, api_url),
                {
                    200,
                    damage_utils:load_template(
                        "reset_password_response.html.mustache",
                        #{status => <<"ok">>, message => Message, login_url => ApiUrl}
                    )
                };
            {error, Message} ->
                {
                    400,
                    damage_utils:load_template(
                        "reset_password_response.html.mustache",
                        #{status => <<"failed">>, message => Message}
                    )
                }
        end,
    {
        stop,
        cowboy_req:reply(Status0, cowboy_req:set_resp_body(Response0, Req)),
        State
    }.

do_post_action(
    invoice,
    #{memo := Memo, amount := Amount, expiry := Expiry} = Data,
    _Req,
    _State
) ->
    ?LOG_DEBUG("generate invoice ~p", [Data]),
    Invoice = cln:create_invoice(Amount, Memo, Expiry),
    {201, Invoice};
do_post_action(_Action, Data, _Req, _State) ->
    ?LOG_DEBUG("unhandled do_post_action ~p", [Data]).

from_json(Req, #{action := Action} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("lnaddress post action ~p ", [Data]),
    case catch jsx:decode(Data, [return_maps, {labels, atom}]) of
        badarg ->
            Response =
                cowboy_req:set_resp_body(
                    jsx:encode(
                        #{status => <<"failed">>, message => <<"Json decode error.">>}
                    ),
                    Req0
                ),
            cowboy_req:reply(400, Response),
            ?LOG_DEBUG("post response 400 ~p ", [Response]),
            {stop, Response, State};
        {'EXIT', {badarg, _}} ->
            Response =
                cowboy_req:set_resp_body(
                    jsx:encode(
                        #{status => <<"failed">>, message => <<"Json decode error.">>}
                    ),
                    Req0
                ),
            cowboy_req:reply(400, Response),
            ?LOG_DEBUG("post response 400 ~p ", [Response]),
            {stop, Response, State};
        Data0 ->
            ?LOG_DEBUG("post action  ~p ", [Data0]),
            case do_post_action(Action, Data0, Req0, State) of
                {204, <<"">>} ->
                    Response = cowboy_req:reply(204, Req0),
                    {stop, Response, State};
                {Status0, Response0} ->
                    Response = cowboy_req:set_resp_body(jsx:encode(Response0), Req0),
                    cowboy_req:reply(Status0, Response),
                    ?LOG_DEBUG("post response ~p ~p ", [Status0, Response]),
                    {stop, Response, State}
            end
    end.
