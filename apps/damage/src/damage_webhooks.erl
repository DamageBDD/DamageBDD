-module(damage_webhooks).

-vsn("0.1.0").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_accepted/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2]).
-export([allowed_methods/2]).
-export([delete_resource/2]).
-export([trails/0]).
-export([is_authorized/2]).
-export([trigger_webhooks/1]).
-export(
    [
        get_webhooks/1,
        get_webhooks_proc/1,
        contract_call/3,
        restart_webhook_proc/1
    ]
).
-export(
    [
        init/1,
        start_link/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3
    ]
).

-define(DEFAULT_HTTP_TIMEOUT, 60000).
-define(DEFAULT_HEADERS, [
    {<<"accept">>, "application/json,text/html"},
    {<<"user-agent">>, "damagebdd/1.0"},
    {<<"content-type">>, "application/json"}
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(WEBHOOKS_BUCKET, {<<"Default">>, <<"Webhooks">>}).
-define(TRAILS_TAG, ["Manage Webhooks"]).

trails() ->
    [
        trails:trail(
            "/webhooks/[...]",
            damage_webhooks,
            #{},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Form to webhook a test execution.",
                        produces => ["text/html"]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Webhook a test on post",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"feature">>,
                                    description => <<"Test feature data.">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"string">>
                                }
                            ]
                    },
                delete =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Delete webhook",
                        produces => ["application/json"],
                        parameters => []
                    }
            }
        )
    ].
start_link(AeAccount) -> gen_server:start_link(?MODULE, [AeAccount], []).
init([]) ->
    process_flag(trap_exit, true),
    {ok, #{}};
init([AeAccount]) ->
    process_flag(trap_exit, true),
    {ok, #{public_key => AeAccount}}.

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

from_json(Req, State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    #{result := #{returnType := <<"ok">>}} =
        case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
            {'EXIT', {badarg, Trace}} ->
                logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
                {400, <<"Json decoding failed.">>};
            #{name := _WebhookName, url := _WebhookUrl} = Webhook ->
                create_webhook(Webhook, Req, State)
        end,
    Resp = cowboy_req:set_resp_body(jsx:encode(#{status => <<"ok">>}), Req),
    {stop, cowboy_req:reply(201, Resp), State}.

to_json(Req, #{public_key := AeAccount} = State) ->
    Body = jsx:encode(get_webhooks(AeAccount)),
    logger:info("Loading webhooks for ~p ~p", [AeAccount, Body]),
    {Body, Req, State}.

delete_resource(Req, #{public_key := AeAccount} = State) ->
    Deleted =
        lists:foldl(
            fun(DeleteId, Acc) ->
                ?LOG_DEBUG("deleted ~p ~p", [maps:get(path_info, Req), DeleteId]),
                ok = delete_webhook(AeAccount, DeleteId),
                Acc + 1
            end,
            0,
            maps:get(path_info, Req)
        ),
    ?LOG_INFO("deleted ~p webhook", [Deleted]),
    {true, Req, State}.

create_webhook(
    #{name := WebhookName, url := WebhookUrl} = _WebhookData,
    _Req,
    #{public_key := AeAccount} = _State
) ->
    Pid = get_webhooks_proc(AeAccount),

    gen_server:call(Pid, {add_webhook, AeAccount, WebhookName, WebhookUrl}, ?AE_TIMEOUT).

get_webhooks(AeAccount) ->
    Pid = get_webhooks_proc(AeAccount),

    gen_server:call(Pid, get_webhooks, ?AE_TIMEOUT).

gun_await(ConnPid, StreamRef) ->
    case gun:await(ConnPid, StreamRef, ?DEFAULT_HTTP_TIMEOUT) of
        {response, fin, _Status, _Headers} ->
            closed;
        {response, nofin, _Status, _Headers} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            Body
    end.

trigger_webhook(Url, #{fail := FailMessage} = _Context) ->
    trigger_webhook(Url, #{content => FailMessage});
trigger_webhook(Url, #{content := Content} = Context) ->
    {Host0, Port0, Path0} =
        case uri_string:parse(binary_to_list(Url)) of
            #{port := Port, scheme := _Scheme, path := Path, host := Host} ->
                {Host, Port, Path};
            #{scheme := "https", host := Host, path := Path} ->
                {Host, 443, Path};
            #{scheme := "http", host := Host, path := Path} ->
                {Host, 80, Path}
        end,
    {ok, ConnPid} =
        gun:open(Host0, Port0, #{tls_opts => [{verify, verify_none}]}),
    TemplateContext = maps:put(content, damage_utils:safe_json(Content), Context),
    Body =
        case re:run(Url, "https://discord.com.*") of
            nomatch -> damage_utils:safe_json(TemplateContext);
            {match, _} -> damage_utils:load_template("webhooks/discord.mustache", TemplateContext)
        end,
    %?LOG_DEBUG("webhook post ~p ~p.", [Body, TemplateContext]),
    StreamRef = gun:post(ConnPid, Path0, ?DEFAULT_HEADERS, Body),
    Resp = gun_await(ConnPid, StreamRef),
    ?LOG_DEBUG("Got response from webhook url ~p ~p.", [Url, Resp]);
trigger_webhook(#{url := _Url} = _Webhook, _Context) ->
    ok.

trigger_webhooks(FinalContext) ->
    case maps:get(notify_urls, FinalContext, none) of
        none ->
            ok;
        #{"fail" := EventHooks} = _NotifyHooks ->
            [
                trigger_webhook(Webhook, FinalContext)
             || Webhook <- sets:to_list(EventHooks)
            ]
    end.

handle_call({add_webhook, WebhookName, WebhookUrl}, _From, #{public_key := AeAccount} = Cache) ->
    AccountCache = maps:get(AeAccount, Cache, #{}),
    WebHookCache = maps:get(webhooks, AccountCache, #{}),
    WebhookUrlEncrypted = base64:encode(damage_utils:encrypt(WebhookUrl)),
    WebhookNameEncrypted = base64:encode(damage_utils:encrypt(WebhookName)),
    Results =
        contract_call(
            AeAccount,
            "add_webhook",
            [WebhookNameEncrypted, WebhookUrlEncrypted]
        ),
    ?LOG_DEBUG("Webhooks ~p", [Results]),
    {
        reply,
        Results,
        maps:put(
            AeAccount,
            maps:put(
                webhooks,
                maps:put(WebhookName, WebhookUrl, WebHookCache),
                AccountCache
            ),
            Cache
        )
    };
handle_call({delete_webhook, WebhookName}, _From, #{public_key := AeAccount} = Cache) ->
    WebhookNameEncrypted = base64:encode(damage_utils:encrypt(WebhookName)),
    Results =
        contract_call(
            AeAccount,
            "delete_webhook",
            [WebhookNameEncrypted]
        ),
    ?LOG_DEBUG("Webhooks ~p", [Results]),
    {reply, Results, Cache};
handle_call(get_webhooks, _From, #{public_key := AeAccount} = Cache) ->
    case catch maps:get(webhooks, Cache, undefined) of
        undefined ->
            #{decodedResult := Results} =
                contract_call(AeAccount, "get_webhooks", []),
            WebHooks =
                maps:from_list(
                    [
                        {
                            damage_utils:decrypt(Key),
                            damage_utils:decrypt(Hook)
                        }
                     || [Key, Hook] <- Results
                    ]
                ),
            ?LOG_DEBUG("Cache get Webhooks ~p", [WebHooks]),
            {
                reply,
                WebHooks,
                maps:put(webhooks, WebHooks, Cache)
            };
        Context when is_map(Context) -> {reply, Context, Cache}
    end.
handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

get_webhooks_proc(<<"ak_", _/binary>> = AeAccount) ->
    case gproc:lookup_local_name({?MODULE, AeAccount}) of
        undefined ->
            case
                supervisor:start_child(
                    damage_sup,
                    #{
                        % mandatory
                        id => {?MODULE, AeAccount},
                        % mandatory
                        start => {damage_webhooks, start_link, [AeAccount]},
                        % optional
                        restart => permanent,
                        % optional
                        shutdown => 60,
                        % optional
                        type => worker,
                        modules => [damage_ae, damage_context, damage_webhooks]
                    }
                )
            of
                {ok, AePid} ->
                    gproc:reg_other({n, l, {?MODULE, AeAccount}}, AePid),
                    AePid;
                {error, {already_started, AePid}} ->
                    gproc:reg_other({n, l, {?MODULE, AeAccount}}, AePid),
                    AePid
            end;
        Pid ->
            Pid
    end.

restart_webhook_proc(AeAccount) ->
    case gproc:lookup_local_name({?MODULE, AeAccount}) of
        undefined ->
            get_webhooks_proc(AeAccount);
        Pid ->
            supervisor:terminate_child(damage_sup, Pid),
            get_webhooks_proc(AeAccount)
    end.

contract_call(AeAccount, Func, Args) ->
    damage_ae:contract_call(
        AeAccount,
        ?WEBHOOKS_CONTRACT,
        "contracts/webhooks.aes",
        Func,
        Args
    ).
