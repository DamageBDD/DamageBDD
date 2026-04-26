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
lookup_user_npub(<<"community">>) ->
    <<"npub1lxs7aguh3pjyw2hf76gr8sd0jxpdp8s0tzjlfrzla2ndtk82wjcs36drv5">>;
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

%% Refactored: Zap request handler
handle_zap_request(#{nostr := ZapJsonBin, amount := AmountMsat}) ->
    ?LOG_DEBUG("Zap request payload: ~p", [ZapJsonBin]),
    try
        ZapMap = jsx:decode(ZapJsonBin, [return_maps]),
        Tags = maps:get(<<"tags">>, ZapMap, []),
        EventId = extract_tag(<<"e">>, Tags),
        PubKey = extract_tag(<<"p">>, Tags),
        Memo = maps:get(<<"content">>, ZapMap, <<"Zap! ⚡">>),
        Amount = AmountMsat div 1000,
        Label = <<"zap:", EventId/binary, ":", PubKey/binary>>,
        #{bolt11 := Bolt11} = cln:create_invoice(Amount, Memo, 3600, Label),
        {201, #{pr => Bolt11, routes => []}}
    catch
        _:Error ->
            ?LOG_WARNING("Invalid zap request format: ~p", [Error]),
            {400, #{error => <<"Invalid zap request">>}}
    end.

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
to_json(Req, #{action := nip57} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    ?LOG_INFO("Nip05 request data ~p", [Data]),
    {Status, Response} = handle_zap_request(Data),
    {
        stop,
        cowboy_req:reply(
            Status,
            cowboy_req:set_resp_body(Response)
        ),
        State
    };
to_json(Req, #{action := invoice} = State) ->
    UserBinding = cowboy_req:binding(user, Req),
    ?LOG_INFO("invoice requested for user ~p", [UserBinding]),
    case lookup_user_npub(UserBinding) of
        undefined ->
            {<<"user required">>, Req, State};
        _User ->
            {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
            Label = list_to_binary("zap:" ++ Timestamp),

            ?LOG_DEBUG("got request ~p", [Req]),

            %% NOTE: key is *nostr* (not `nost`), default <<>>.
            Qs = cowboy_req:match_qs(
                [
                    {comment, [], <<>>},
                    {amount, [], <<"0">>},
                    {nostr, [], <<>>}
                ],
                Req
            ),
            ?LOG_DEBUG("invoice qs ~p", [Qs]),

            %% Amount: lnurl is msat
            AmountBin = maps:get(amount, Qs, <<"0">>),
            AmountMsat =
                case AmountBin of
                    %% fallback min
                    <<"0">> -> 1000;
                    _ -> binary_to_integer(AmountBin)
                end,

            Comment = maps:get(comment, Qs, <<>>),
            NostrBin = maps:get(nostr, Qs, <<>>),

            %% NIP-57: if nostr is present and valid, the *description*
            %% MUST be exactly the zap request JSON – nothing else.
            Description =
                case NostrBin of
                    <<>> ->
                        Comment;
                    _ ->
                        case damage_nostr:parse_zap_request(NostrBin) of
                            {ok, ZapReq} ->
                                ?LOG_INFO("valid zap request for invoice: ~p", [ZapReq]),
                                NostrBin;
                            {error, Reason} ->
                                ?LOG_WARNING(
                                    "invalid zap request in `nostr` param (~p), falling back to comment",
                                    [Reason]
                                ),
                                Comment
                        end
                end,

            %% --- NEW: forward invoices for damagebdd_community to remote lnaddress (like rizful) ---
            case forward_lnaddress(UserBinding) of
                undefined ->
                    %% Local invoice (Core Lightning)
                    #{
                        payment_hash := _PaymentHash,
                        expires_at := _Expiry,
                        bolt11 := Bolt11,
                        payment_secret := _PaymentSecret,
                        created_index := _CreatedIndex
                    } = Invoice = cln:create_invoice(AmountMsat, Description, 3600, Label),

                    ?LOG_INFO("invoice ~p", [Invoice]),
                    {jsx:encode(#{pr => Bolt11}), Req, State};
                RemoteLnAddress ->
                    %% Remote invoice (resolve LNURLp -> callback -> pr)
                    case
                        resolve_lnaddress_invoice(RemoteLnAddress, AmountMsat, Comment, NostrBin)
                    of
                        {ok, Bolt11} ->
                            ?LOG_INFO(
                                "forwarded invoice user=~p -> lnaddress=~p",
                                [UserBinding, RemoteLnAddress]
                            ),
                            {jsx:encode(#{pr => Bolt11}), Req, State};
                        {error, Reason0} ->
                            ?LOG_WARNING(
                                "invoice forward failed user=~p lnaddress=~p reason=~p",
                                [UserBinding, RemoteLnAddress, Reason0]
                            ),
                            %% Keep response shape JSON so wallets don't crash hard.
                            {jsx:encode(#{error => <<"invoice_forward_failed">>}), Req, State}
                    end
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
extract_tag(Key, Tags) ->
    case lists:dropwhile(fun([K | _]) -> K =/= Key end, Tags) of
        [[_, Value | _] | _] -> Value;
        _ -> <<>>
    end.
do_post_action(nip57, #{nostr := _, amount := _} = Data, _Req, _State) ->
    handle_zap_request(Data);
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
    {ok, Timestamp} = datestring:format("YmdHMS", erlang:localtime()),
    Label = list_to_binary("zap:" ++ Timestamp),
    Invoice = cln:create_invoice(Amount, Memo, Expiry, Label),
    {201, Invoice};
do_post_action(_Action, Data, _Req, _State) ->
    ?LOG_DEBUG("unhandled do_post_action ~p", [Data]).

from_json(Req, #{action := Action} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
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
%% ---------------------------
%% Remote LN Address forwarding
%% ---------------------------

%% Map a local user to a remote lnaddress, fetched from encrypted secrets storage.
%%
%% Store it once with:
%%   secrets:encrypt_store(community_manager_lnaddress, <<"manager@rizful.com">>).
%%
%% Then requests to /pay/community will forward invoice generation to that lnaddress.
forward_lnaddress(<<"community">>) ->
    case secrets:retrieve_decrypt(community_manager_lnaddress) of
        {ok, V} when is_binary(V), V =/= <<>> ->
            V;
        {ok, V} when is_list(V), V =/= [] ->
            list_to_binary(V);
        _ ->
            %% Safe default: if not configured, don't forward.
            undefined
    end;
forward_lnaddress(_User) ->
    undefined.

%% Resolve an lnaddress (user@domain) via LNURLp and return {ok, Bolt11}.
%% Amount is in millisatoshis (LNURL spec).
resolve_lnaddress_invoice(LnAddress, AmountMsat, Comment, NostrBin) when is_binary(LnAddress) ->
    {LnUser, LnDomain} = parse_lnaddress(LnAddress),
    LnurlpUrl = lnurlp_url(LnDomain, LnUser),
    {ok, Lnurlp} = http_get_json(LnurlpUrl),
    Callback0 = maps:get(<<"callback">>, Lnurlp, undefined),
    case Callback0 of
        undefined ->
            {error, no_callback};
        _ ->
            Callback = ensure_binary(Callback0),
            Query = build_invoice_query(AmountMsat, Comment, NostrBin),
            InvoiceUrl = append_query(Callback, Query),
            {ok, InvoiceResp} = http_get_json(InvoiceUrl),
            case maps:get(<<"pr">>, InvoiceResp, undefined) of
                PR when is_binary(PR), PR =/= <<>> -> {ok, PR};
                _ -> {error, invalid_invoice_response}
            end
    end.

parse_lnaddress(LnAddress) ->
    case binary:split(LnAddress, <<"@">>, [global]) of
        [User, Domain] when User =/= <<>>, Domain =/= <<>> -> {User, Domain};
        _ -> error({bad_lnaddress, LnAddress})
    end.

lnurlp_url(Domain, User) ->
    %% default to https
    <<"https://", Domain/binary, "/.well-known/lnurlp/", User/binary>>.

build_invoice_query(AmountMsat, Comment, NostrBin) ->
    Base = [{"amount", integer_to_list(AmountMsat)}],
    WithComment =
        case Comment of
            <<>> -> Base;
            _ -> Base ++ [{"comment", binary_to_list(Comment)}]
        end,
    WithNostr =
        case NostrBin of
            <<>> -> WithComment;
            _ -> WithComment ++ [{"nostr", binary_to_list(NostrBin)}]
        end,
    uri_string:compose_query(WithNostr).

append_query(UrlBin, QueryStr) when is_binary(UrlBin) ->
    Url0 = binary_to_list(UrlBin),
    Sep =
        case string:find(Url0, "?") of
            nomatch -> "?";
            _ -> "&"
        end,
    list_to_binary(Url0 ++ Sep ++ QueryStr).

ensure_binary(undefined) -> <<>>;
ensure_binary(V) when is_binary(V) -> V;
ensure_binary(V) when is_list(V) -> list_to_binary(V);
ensure_binary(V) -> list_to_binary(io_lib:format("~p", [V])).

http_get_json(UrlBin) when is_binary(UrlBin) ->
    Uri = uri_string:parse(UrlBin),

    Scheme = ensure_binary(maps:get(scheme, Uri, <<"https">>)),
    Host = ensure_binary(maps:get(host, Uri, <<>>)),
    Path0 = ensure_binary(maps:get(path, Uri, <<"/">>)),
    Query0 = maps:get(query, Uri, undefined),

    Port =
        case maps:get(port, Uri, undefined) of
            undefined ->
                case Scheme of
                    <<"https">> -> 443;
                    _ -> 80
                end;
            P ->
                P
        end,

    Path =
        case Path0 of
            <<>> -> <<"/">>;
            _ -> Path0
        end,

    FullPath =
        case Query0 of
            undefined ->
                Path;
            <<>> ->
                Path;
            Q0 ->
                Q = ensure_binary(Q0),
                <<Path/binary, "?", Q/binary>>
        end,

    Transport =
        case Scheme of
            <<"https">> -> tls;
            _ -> tcp
        end,

    Opts =
        #{
            transport => Transport,
            connect_timeout => 15000
        },

    case damage_gun:open(Host, Port, Opts) of
        {ok, ConnPid} ->
            try
                case damage_gun:await_up(ConnPid, 15000) of
                    {ok, _Protocol} ->
                        StreamRef = gun:get(ConnPid, binary_to_list(FullPath)),
                        {ok, get_json_body(ConnPid, StreamRef)};
                    {error, Reason} ->
                        {error, Reason}
                end
            after
                catch gun:close(ConnPid)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

get_json_body(ConnPid, StreamRef) ->
    receive
        {gun_response, ConnPid, StreamRef, fin, Status, _Headers} ->
            ?LOG_WARNING("http_get_json empty response status=~p", [Status]),
            #{};
        {gun_response, ConnPid, StreamRef, nofin, Status, _Headers} ->
            Body = recv_body(ConnPid, StreamRef, <<>>),
            case Status of
                S when S >= 200, S < 300 ->
                    jsx:decode(Body, [return_maps]);
                _ ->
                    ?LOG_WARNING("http_get_json bad status=~p body=~p", [Status, Body]),
                    jsx:decode(Body, [return_maps])
            end
    after 15000 ->
        error(timeout)
    end.

recv_body(ConnPid, StreamRef, Acc) ->
    receive
        {gun_data, ConnPid, StreamRef, nofin, Data} ->
            recv_body(ConnPid, StreamRef, <<Acc/binary, Data/binary>>);
        {gun_data, ConnPid, StreamRef, fin, Data} ->
            <<Acc/binary, Data/binary>>
    after 15000 ->
        error(timeout)
    end.
