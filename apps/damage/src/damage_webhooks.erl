-module(damage_webhooks).

-behaviour(gen_server).

-vsn("0.2.0").

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
-export([
    get_webhooks/1,
    get_webhooks_proc/1,
    contract_call/3,
    restart_webhook_proc/1
]).
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

-define(DEFAULT_HEADERS, [
    {<<"accept">>, "application/json,text/html"},
    {<<"user-agent">>, "damagebdd/1.0"},
    {<<"content-type">>, "application/json"}
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

%% Webhook URLs may contain bearer tokens or path secrets. Keep the whole map
%% encrypted in the authenticated account scope and out of Gherkin templates.
-define(WEBHOOKS_KEY, <<"damage.webhooks">>).
-define(WEBHOOKS_META, #{sensitive => true, exposure => step_only}).
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
    {[<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>], Req, State}.

from_json(Req0, State) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req} ->
            case decode_webhook(Data) of
                {ok, Webhook} ->
                    case create_webhook(Webhook, Req, State) of
                        {ok, Result} ->
                            reply_json_stop(
                                201,
                                #{status => <<"ok">>, result => Result},
                                Req,
                                State
                            );
                        {error, Reason} ->
                            ?LOG_ERROR("Webhook context write failed reason=~p", [Reason]),
                            reply_json_stop(
                                503,
                                #{status => <<"error">>, error => <<"WEBHOOK_STORE_UNAVAILABLE">>},
                                Req,
                                State
                            )
                    end;
                {error, Reason} ->
                    ?LOG_WARNING(
                        "Invalid webhook JSON bytes=~p reason=~p",
                        [byte_size(Data), Reason]
                    ),
                    reply_json_stop(
                        400,
                        #{status => <<"error">>, error => <<"INVALID_WEBHOOK_REQUEST">>},
                        Req,
                        State
                    )
            end;
        {more, _Data, Req} ->
            reply_json_stop(
                413,
                #{status => <<"error">>, error => <<"WEBHOOK_REQUEST_TOO_LARGE">>},
                Req,
                State
            )
    end.

to_json(Req, #{public_key := AeAccount} = State) ->
    case get_webhooks(AeAccount) of
        Webhooks when is_map(Webhooks) ->
            ?LOG_INFO("Loading webhooks account=~p count=~p", [AeAccount, map_size(Webhooks)]),
            {jsx:encode(Webhooks), set_no_store(Req), State};
        {error, Reason} ->
            ?LOG_ERROR("Webhook context read failed account=~p reason=~p", [AeAccount, Reason]),
            reply_json_stop(
                503,
                #{status => <<"error">>, error => <<"WEBHOOK_STORE_UNAVAILABLE">>},
                Req,
                State
            )
    end.

delete_resource(Req, #{public_key := AeAccount} = State) ->
    case delete_webhook_ids(AeAccount, maps:get(path_info, Req, []), 0) of
        {ok, Deleted} ->
            ?LOG_INFO("Deleted webhooks account=~p count=~p", [AeAccount, Deleted]),
            {true, Req, State};
        {error, Reason} ->
            ?LOG_ERROR("Webhook context delete failed account=~p reason=~p", [AeAccount, Reason]),
            reply_json_stop(
                503,
                #{status => <<"error">>, error => <<"WEBHOOK_STORE_UNAVAILABLE">>},
                Req,
                State
            )
    end.

create_webhook(
    #{name := WebhookName, url := WebhookUrl} = _WebhookData,
    _Req,
    #{public_key := AeAccount} = _State
) ->
    Pid = get_webhooks_proc(AeAccount),
    gen_server:call(Pid, {add_webhook, WebhookName, WebhookUrl}, ?AE_TIMEOUT).

delete_webhook(AeAccount, WebhookId) ->
    Pid = get_webhooks_proc(AeAccount),
    gen_server:call(Pid, {delete_webhook, WebhookId}, ?AE_TIMEOUT).
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
        damage_gun:open(Host0, Port0),
    TemplateContext = maps:put(content, damage_utils:json_decode(Content), Context),
    Body =
        case re:run(Url, "https://discord.com.*") of
            nomatch -> damage_utils:json_decode(TemplateContext);
            {match, _} -> damage_utils:load_template("webhooks/discord.mustache", TemplateContext)
        end,
    %?LOG_DEBUG("webhook post ~p ~p.", [Body, TemplateContext]),
    StreamRef = gun:post(ConnPid, Path0, ?DEFAULT_HEADERS, Body),
    Resp = gun_await(ConnPid, StreamRef),
    ?LOG_DEBUG("Got response from webhook host=~p response=~p", [Host0, Resp]);
trigger_webhook(#{url := _Url} = _Webhook, _Context) ->
    ok.

trigger_webhooks(FinalContext) ->
    case maps:get(notify_urls, FinalContext, none) of
        #{"fail" := EventHooks} ->
            trigger_webhook_set(EventHooks, FinalContext);
        #{<<"fail">> := EventHooks} ->
            trigger_webhook_set(EventHooks, FinalContext);
        _ ->
            ok
    end.

trigger_webhook_set(EventHooks, FinalContext) ->
    Webhooks =
        try sets:to_list(EventHooks) of
            Values when is_list(Values) -> Values
        catch
            _:_ when is_list(EventHooks) -> EventHooks;
            _:_ -> []
        end,
    lists:foreach(fun(Webhook) -> trigger_webhook(Webhook, FinalContext) end, Webhooks),
    ok.

handle_call(
    {add_webhook, AeAccount, WebhookName, WebhookUrl},
    From,
    #{public_key := AeAccount} = State
) ->
    handle_call({add_webhook, WebhookName, WebhookUrl}, From, State);
handle_call(
    {add_webhook, WebhookName0, WebhookUrl0},
    _From,
    #{public_key := AeAccount} = State
) ->
    WebhookName = to_binary(WebhookName0),
    WebhookUrl = to_binary(WebhookUrl0),
    Reply =
        case load_webhooks(AeAccount) of
            {ok, Webhooks0} ->
                Webhooks = maps:put(WebhookName, WebhookUrl, Webhooks0),
                case store_webhooks(AeAccount, Webhooks) of
                    {ok, Summary} ->
                        {ok, #{name => WebhookName, context => Summary}};
                    {error, _} = Error ->
                        Error
                end;
            {error, _} = Error ->
                Error
        end,
    {reply, Reply, State};
handle_call({delete_webhook, WebhookName0}, _From, #{public_key := AeAccount} = State) ->
    WebhookName = to_binary(WebhookName0),
    Reply =
        case load_webhooks(AeAccount) of
            {ok, Webhooks0} ->
                case maps:is_key(WebhookName, Webhooks0) of
                    false ->
                        ok;
                    true ->
                        persist_webhook_delete(
                            AeAccount,
                            maps:remove(WebhookName, Webhooks0)
                        )
                end;
            {error, _} = Error ->
                Error
        end,
    {reply, Reply, State};
handle_call(get_webhooks, _From, #{public_key := AeAccount} = State) ->
    Reply =
        case load_webhooks(AeAccount) of
            {ok, Webhooks} -> Webhooks;
            {error, _} = Error -> Error
        end,
    {reply, Reply, State};
handle_call(Other, _From, State) ->
    ?LOG_WARNING("Unhandled damage_webhooks call ~p", [Other]),
    {reply, {error, unsupported_call}, State}.
handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

get_webhooks_proc(AeAccount) when is_list(AeAccount) ->
    get_webhooks_proc(list_to_binary(AeAccount));
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
                        modules => [damage_webhooks]
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

webhook_scope(AeAccount) ->
    damage_context:account_scope(to_binary(AeAccount)).

load_webhooks(AeAccount) ->
    case damage_context:get(webhook_scope(AeAccount), ?WEBHOOKS_KEY) of
        {ok, Webhooks} when is_map(Webhooks) ->
            {ok, normalize_webhooks(Webhooks)};
        {ok, Other} ->
            {error, {invalid_webhooks_context_value, Other}};
        not_found ->
            {ok, #{}};
        {error, _} = Error ->
            Error
    end.

store_webhooks(AeAccount, Webhooks) when is_map(Webhooks) ->
    damage_context:put(
        webhook_scope(AeAccount),
        ?WEBHOOKS_KEY,
        normalize_webhooks(Webhooks),
        ?WEBHOOKS_META
    ).

persist_webhook_delete(AeAccount, Webhooks) when map_size(Webhooks) =:= 0 ->
    case damage_context:delete(webhook_scope(AeAccount), ?WEBHOOKS_KEY) of
        {ok, _Summary} -> ok;
        {error, _} = Error -> Error
    end;
persist_webhook_delete(AeAccount, Webhooks) ->
    case store_webhooks(AeAccount, Webhooks) of
        {ok, _Summary} -> ok;
        {error, _} = Error -> Error
    end.

normalize_webhooks(Webhooks) ->
    maps:from_list([
        {to_binary(Name), to_binary(Url)}
     || {Name, Url} <- maps:to_list(Webhooks)
    ]).

decode_webhook(Data) ->
    try jsx:decode(Data, [return_maps]) of
        #{<<"name">> := Name, <<"url">> := Url} ->
            normalize_webhook(Name, Url);
        #{name := Name, url := Url} ->
            normalize_webhook(Name, Url);
        _ ->
            {error, missing_name_or_url}
    catch
        Class:Reason:Stacktrace ->
            {error, {json_decode_failed, Class, Reason, Stacktrace}}
    end.

normalize_webhook(Name0, Url0) ->
    Name = to_binary(Name0),
    Url = to_binary(Url0),
    case {Name, Url} of
        {<<>>, _} -> {error, empty_webhook_name};
        {_, <<>>} -> {error, empty_webhook_url};
        _ -> {ok, #{name => Name, url => Url}}
    end.

delete_webhook_ids(_AeAccount, [], Deleted) ->
    {ok, Deleted};
delete_webhook_ids(AeAccount, [WebhookId | Rest], Deleted) ->
    case delete_webhook(AeAccount, WebhookId) of
        ok -> delete_webhook_ids(AeAccount, Rest, Deleted + 1);
        {error, _} = Error -> Error
    end.

reply_json_stop(Status, Body, Req0, State) ->
    Req = cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/json">>,
            <<"cache-control">> => <<"private, no-store">>
        },
        jsx:encode(Body),
        Req0
    ),
    {stop, Req, State}.

set_no_store(Req) ->
    cowboy_req:set_resp_header(<<"cache-control">>, <<"private, no-store">>, Req).

%% Compatibility shim for older callers. Webhook persistence no longer uses
%% an Aeternity contract; callers should use get_webhooks/1 or the HTTP API.
contract_call(AeAccount, Func, Args) ->
    ?LOG_WARNING(
        "Legacy webhook contract call rejected account=~p function=~p args_count=~p",
        [AeAccount, Func, length(Args)]
    ),
    {error, webhooks_contract_removed}.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) -> unicode:characters_to_binary(io_lib:format("~p", [Value])).
