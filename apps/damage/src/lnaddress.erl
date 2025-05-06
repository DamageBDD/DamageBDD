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

-define(TRAILS_TAG, ["LN Address resolver"]).
-define(DEFAULT_AMOUNT_MSATS, 1000).

trails() ->
    [
        trails:trail(
            "/.well-known/lnurlp/[:user]",
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
            "/.well-known/nostr.json",
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
        ),
        trails:trail(
            "/zap/",
            lnaddress,
            #{action => nip57},
            #{
                post =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "nip 57.",
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

lookup_user_npub(<<"asyncmind">>) ->
    <<"npub1zmg3gvpasgp3zkgceg62yg8fyhqz9sy3dqt45kkwt60nkctyp9rs9wyppc">>;
lookup_user_npub(<<"damagebdd">>) ->
    <<"npub14ekwjk8gqjlgdv29u6nnehx63fptkhj5yl2sf8lxykdkm58s937sjw99u8">>;
lookup_user_npub(<<"cocd">>) ->
    <<"npub14ekwjk8gqjlgdv29u6nnehx63fptkhj5yl2sf8lxykdkm58s937sjw99u8">>;
lookup_user_npub(<<"coordinator">>) ->
    lookup_user_npub(<<"bitcoinonlyparty">>);
lookup_user_npub(<<"bitcoinonlyparty">>) ->
    <<"npub16a2r3p8d7syd46ypygva0fqw6pfpgdxv5mm4gd8vqra4wr9scj5sx42y5t">>;
lookup_user_npub(_) ->
    false.
default_pay_user(User) ->
    {ok, ApiUrl} = application:get_env(damage, lnpay_host),
    #{
        tag => <<"payRequest">>,
        nostrPubkey => lookup_user_npub(User),
        allowsNostr => true,
        callback =>
            damage_utils:binarystr_join(
                [list_to_binary(ApiUrl), <<"/pay/">>, User]
            )
    }.

to_json(Req, #{action := lnurlp} = State) ->
    case cowboy_req:binding(user, Req) of
        undefined ->
            ?LOG_DEBUG("Lnurl request ~p", [Req]),
            {jsx:encode(default_pay_user(<<"asyncmind">>)), Req, State};
        User ->
            {jsx:encode(default_pay_user(User)), Req, State}
    end;
to_json(Req, #{action := nip05} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
            ?LOG_INFO("Nip05 request data ~p", [Data]),
    {jsx:encode(damage_nostr:get_nostr_json()), Req, State};

to_json(Req, #{action := invoice} = State) ->
    case lookup_user_npub(cowboy_req:binding(user, Req)) of
        undefined ->
            {<<"user required">>, Req, State};
        _User ->
            case cowboy_req:match_qs([{comment, [], none}, {amount, [], none}], Req) of
                #{amount := <<"0">>, comment := Memo} ->
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
        case damage_accounts:reset_password(Data0) of
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
    zap,
    #{memo := Memo, amount := Amount, expiry := Expiry} = Data,
    _Req,
    _State
) ->
    ?LOG_DEBUG("generate invoice ~p", [Data]),
    Invoice = cln:create_invoice(Amount, Memo, Expiry),
    %ZapRecipt = #{
    %    "id"=> Id,
    %    "pubkey":"9630f464cca6a5147aa8a35f0bcdd3ce485324e732fd39e09233b1d848238f31",
    %    "created_at":1674164545,
    %    "kind":9735,
    %    "tags":[
    %        ["p", "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245"],
    %        ["P", "97c70a44366a6535c145b333f973ea86dfdc2d7a99da618c40c64705ad98e322"],
    %        ["e", "3624762a1274dd9636e0c552b53086d70bc88c165bc4dc0f9e836a1eaf86c3b8"],
    %        [
    %            "bolt11",
    %            "lnbc10u1p3unwfusp5t9r3yymhpfqculx78u027lxspgxcr2n2987mx2j55nnfs95nxnzqpp5jmrh92pfld78spqs78v9euf2385t83uvpwk9ldrlvf6ch7tpascqhp5zvkrmemgth3tufcvflmzjzfvjt023nazlhljz2n9hattj4f8jq8qxqyjw5qcqpjrzjqtc4fc44feggv7065fqe5m4ytjarg3repr5j9el35xhmtfexc42yczarjuqqfzqqqqqqqqlgqqqqqqgq9q9qxpqysgq079nkq507a5tw7xgttmj4u990j7wfggtrasah5gd4ywfr2pjcn29383tphp4t48gquelz9z78p4cq7ml3nrrphw5w6eckhjwmhezhnqpy6gyf0"
    %        ],
    %        [
    %            "description",
    %            "{\"pubkey\":\"97c70a44366a6535c145b333f973ea86dfdc2d7a99da618c40c64705ad98e322\",\"content\":\"\",\"id\":\"d9cc14d50fcb8c27539aacf776882942c1a11ea4472f8cdec1dea82fab66279d\",\"created_at\":1674164539,\"sig\":\"77127f636577e9029276be060332ea565deaf89ff215a494ccff16ae3f757065e2bc59b2e8c113dd407917a010b3abd36c8d7ad84c0e3ab7dab3a0b0caa9835d\",\"kind\":9734,\"tags\":[[\"e\",\"3624762a1274dd9636e0c552b53086d70bc88c165bc4dc0f9e836a1eaf86c3b8\"],[\"p\",\"32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245\"],[\"relays\",\"wss://relay.damus.io\",\"wss://nostr-relay.wlvs.space\",\"wss://nostr.fmt.wiz.biz\",\"wss://relay.nostr.bg\",\"wss://nostr.oxtr.dev\",\"wss://nostr.v0l.io\",\"wss://brb.io\",\"wss://nostr.bitcoiner.social\",\"ws://monad.jb55.com:8080\",\"wss://relay.snort.social\"]]}"
    %        ],
    %        ["preimage", "5d006d2cf1e73c7148e7519a4c68adc81642ce0e25a432b2434c99f97344c15f"]
    %    ],
    %    "content":""
    %},
    {201, Invoice};
do_post_action(
    invoice,
    #{amount := 0} = Data,
    Req,
    State
) ->
    do_post_action(
        invoice,
        maps:put(amount, ?DEFAULT_AMOUNT_MSATS, Data),
        Req,
        State
    );
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
