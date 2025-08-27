-module(damage_context).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([content_types_accepted/2]).
-export([get_context/1]).
-export([trails/0]).
-export([clean_secrets/3]).
-export([test/0, test_account_context/0]).
-export([is_authorized/2]).
-export([delete_resource/2]).
-export([get_global_template_context/1]).
-export(
    [
        get_context_proc/1,
        add_context/3,
        add_context/4,
        load_context/1,
        restart_context_proc/1
    ]
).
-behaviour(gen_server).
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
-export([
    contract_add_context/4,
    contract_delete_context/2,
    get_stepargs/1,
    render_body_args/2,
    contract_get_context/1
]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Context Management"]).

trails() ->
    [
        trails:trail(
            "/context",
            damage_context,
            #{action => context},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "get context variables for account",
                        produces => ["application/json"]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Create a new invoice.",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    account_context => <<"account_context">>,
                                    description => <<"custom context for account">>,
                                    in => <<"body">>,
                                    required => true,
                                    type => <<"map">>
                                }
                            ]
                    }
            }
        )
    ].
start_link(AeAccount) -> gen_server:start_link(?MODULE, [AeAccount], []).
get_ets_id(AeAccount) when is_binary(AeAccount) ->
    get_ets_id(binary_to_list(AeAccount));
get_ets_id(AeAccount) ->
    list_to_atom("context_" ++ AeAccount).
%% gen_server init
init([AeAccount]) ->
    process_flag(trap_exit, true),
    Table = ets:new(get_ets_id(AeAccount), [named_table, set, private]),
    {ok, #{ets_table => Table}}.

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"x-www-form-urlencoded">>, '*'}, from_html},
            {{<<"application">>, <<"json">>, '*'}, from_json}
        ],
        Req,
        State
    }.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

from_html(Req, State) -> from_json(Req, State).

from_json(Req, #{public_key := AeAccount} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("post action ~p ", [Data]),
    case catch jsx:decode(Data, [return_maps, {labels, atom}]) of
        #{key := Key, value := Value, masked := Masked} ->
            Result = contract_add_context(AeAccount, Key, Value, #{masked => Masked}),
            Resp =
                cowboy_req:set_resp_body(
                    jsx:encode(#{status => <<"ok">>, result => Result}),
                    Req
                ),
            ?LOG_DEBUG("post response ~p ~p ", [Resp]),
            {stop, cowboy_req:reply(201, Resp), State};
        #{key := Key, value := Value} ->
            Result = contract_add_context(AeAccount, Key, Value, #{masked => false}),
            Resp =
                cowboy_req:set_resp_body(
                    jsx:encode(#{status => <<"ok">>, result => Result}),
                    Req
                ),
            ?LOG_DEBUG("post response ~p ~p ", [Resp]),
            {stop, cowboy_req:reply(201, Resp), State};
        _ ->
            Response =
                cowboy_req:set_resp_body(
                    jsx:encode(
                        #{status => <<"failed">>, message => <<"Json decode error.">>}
                    ),
                    Req0
                ),
            cowboy_req:reply(400, Response),
            ?LOG_DEBUG("post response 400 ~p ", [Response]),
            {stop, Response, State}
    end.

to_json(Req, #{action := context, public_key := AeAccount} = State) ->
    ?LOG_DEBUG("context action ~p", [State]),
    ClientContextRaw = get_context(AeAccount),
    {jsx:encode(ClientContextRaw), Req, State}.

delete_resource(Req, #{public_key := AeAccount} = State) ->
    Deleted =
        lists:foldl(
            fun(DeleteId, Acc) ->
                ?LOG_DEBUG("deleted ~p ~p", [maps:get(path_info, Req), DeleteId]),
                ok = contract_call(AeAccount, "delete_context", [DeleteId]),
                Acc + 1
            end,
            0,
            maps:get(path_info, Req)
        ),
    ?LOG_INFO("deleted ~p context", [Deleted]),
    {true, Req, State}.

handle_call(get_context, _From, #{ets_table := Table} = State) ->
    {
        reply,
        maps:from_list(ets:tab2list(Table)),
        State
    };
handle_call(load_context, _From, #{public_key := AeAccount, ets_table := Table} = State) ->
    #{decodedResult := Results} = contract_get_context(AeAccount),

    {
        reply,
        [
            ets:insert(Table, {
                secrets:decrypt(KeyEncrypted),
                secrets:decrypt(ValueEncrypted)
            })
         || [KeyEncrypted, ValueEncrypted] <- Results
        ],
        State
    };
handle_call({get_value, Key}, _From, #{ets := Table} = State) ->
    case ets:lookup(Table, Key) of
        [{Key, Val}] ->
            {reply, Val, State};
        [] ->
            {reply, notfound, State}
    end;
handle_call({add_context, AeAccount, Key, Value, Meta}, _From, State) ->
    AccountCache = maps:get(AeAccount, State, #{}),
    ContextCache = maps:get(context, AccountCache, #{}),
    KeyHashed = secrets:salted_hash(Key),
    ValueEncrypted = secrets:encrypt(Value),
    MetaEncrypted = secrets:encrypt(term_to_binary(Meta)),
    Results =
        contract_call(
            AeAccount,
            "add_context",
            [KeyHashed, ValueEncrypted, MetaEncrypted]
        ),
    ?LOG_DEBUG("AddContext ~p", [Results]),
    {
        reply,
        Results,
        maps:put(
            AeAccount,
            maps:put(context, maps:put(Key, Value, ContextCache), AccountCache),
            State
        )
    };
handle_call({delete_context, AeAccount, Key}, _From, State) ->
    AccountCache = maps:get(AeAccount, State, #{}),
    ContextCache = maps:get(context, AccountCache, #{}),
    ContextKeyEnc = secrets:encrypt(Key),
    Results =
        contract_call(
            AeAccount,
            "delete_context",
            [ContextKeyEnc]
        ),
    ?LOG_DEBUG("wWebhooks ~p", [Results]),
    {
        reply,
        Results,
        maps:put(
            AeAccount,
            maps:put(context, maps:delete(Key, ContextCache), AccountCache),
            State
        )
    }.

handle_cast(Event, State) ->
    ?LOG_DEBUG("unhandled cast : ~p", [Event]),
    {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(Reason, _State) ->
    ?LOG_INFO("Server ~p terminating with reason ~p~n", [self(), Reason]),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
add_context(AeAccount, Key, Value) ->
    Pid = get_context_proc(AeAccount),
    gen_server:call(Pid, {add_context, AeAccount, Key, Value, []}, ?AE_TIMEOUT).
add_context(AeAccount, Key, Value, masked) ->
    Pid = get_context_proc(AeAccount),
    gen_server:call(Pid, {add_context, AeAccount, Key, Value, [masked]}, ?AE_TIMEOUT).
load_context(AeAccount) ->
    Pid = get_context_proc(AeAccount),
    gen_server:call(Pid, {load_context, AeAccount}, ?AE_TIMEOUT).

get_global_template_context(Context) ->
    {ok, DamageApi} = application:get_env(damage, api_url),
    #{public_key := NodePublicKey, private_key := _PrivateKey} = secrets:node_keypair(),
    maps:merge(
        #{
            api_url => DamageApi,
            formatter_state => #damage_state{},
            headers => [],
            token_contract => list_to_binary(?DAMAGE_TOKEN_CONTRACT),
            node_public_key => list_to_binary(NodePublicKey),
            timestamp => date_util:now_to_seconds_hires(os:timestamp())
        },
        Context
    ).

get_context(AeAccount) ->
    Pid = get_context_proc(AeAccount),
    gen_server:call(Pid, get_context, ?AE_TIMEOUT).

clean_secrets(#{client_context := ClientContext} = Context, Body, Args) ->
    %Password = list_to_binary(maps:get(damage_password, Context, "")),
    AccessToken = maps:get(access_token, Context, <<"null">>),
    Args0 = binary:replace(Args, AccessToken, <<"00REDACTED00">>),
    Body0 = binary:replace(Body, AccessToken, <<"00REDACTED00">>),
    clean_context_secrets(ClientContext, Body0, Args0);
clean_secrets(_Context, Body, Args) ->
    {Body, Args}.

clean_context_secrets(AccountContext, Body, Args) ->
    %?LOG_DEBUG("clean got context ~p ~p ~p", [AccountContext, Body, Args]),
    maps:fold(
        fun
            (_Key, Value, {Body1, Args1}) when is_map(Value) ->
                case maps:get(secret, Value) of
                    true ->
                        {
                            binary:replace(
                                Body1,
                                maps:get(value, Value, <<"">>),
                                <<"00REDACTED00">>
                            ),
                            binary:replace(
                                Args1,
                                maps:get(value, Value, <<"">>),
                                <<"00REDACTED00">>
                            )
                        };
                    _ ->
                        {Body1, Args1}
                end;
            (_Key, _Value, {Body1, Args1}) ->
                {Body1, Args1}
        end,
        {Body, Args},
        AccountContext
    ).

get_context_proc(<<"ak_", _/binary>> = AeAccount) ->
    case gproc:lookup_local_name({?MODULE, AeAccount}) of
        undefined ->
            case
                supervisor:start_child(
                    damage_sup,
                    #{
                        % mandatory
                        id => {?MODULE, AeAccount},
                        % mandatory
                        start => {damage_context, start_link, [AeAccount]},
                        % optional
                        restart => permanent,
                        % optional
                        shutdown => 60,
                        % optional
                        type => worker,
                        modules => [damage_ae, damage_context]
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

restart_context_proc(AeAccount) ->
    case gproc:lookup_local_name({?MODULE, AeAccount}) of
        undefined ->
            get_context_proc(AeAccount);
        Pid ->
            supervisor:terminate_child(damage_sup, Pid),
            get_context_proc(AeAccount)
    end.
contract_call(AeAccount, Func, Args) ->
    ?LOG_DEBUG("damage_context ~p ~p ~p", [AeAccount, Func, Args]),
    damage_ae:contract_call_payfor_user(
        AeAccount,
        ?CONTEXT_CONTRACT,
        "contracts/context.aes",
        Func,
        Args
    ).
contract_add_context(AccountPubKey, Key, Value, Meta) ->
    KeyHash = secrets:salted_hash(Key),
    EncValue = secrets:encrypt(Value),
    EncMeta = secrets:encrypt(term_to_binary(Meta)),
    contract_call(AccountPubKey, "add_context", [KeyHash, EncValue, EncMeta]).

contract_delete_context(AccountPubKey, Key) ->
    KeyEnc = secrets:encrypt(Key),
    contract_call(AccountPubKey, "delete_context", [KeyEnc]).

contract_get_context(AccountPubKey) ->
    contract_call(AccountPubKey, "get_context", []).

get_stepargs(Body) when is_list(Body) ->
    case lists:keytake(<<"\"\"\"">>, 1, Body) of
        {value, {<<"\"\"\"">>, Doc}, Body0} ->
            {
                damage_utils:binarystr_join(Body0, <<" ">>),
                damage_utils:binarystr_join(Doc)
            };
        _ ->
            {damage_utils:binarystr_join(Body, <<" ">>), <<"">>}
    end.

render_body_args(Body, Context) when is_map(Context) ->
    {Body0, Args} = get_stepargs(Body),
    try
        Body1 =
            damage_utils:tokenize(
                bbmustache:render(
                    Body0,
                    Context
                )
            ),

        Args0 =
            list_to_binary(
                bbmustache:render(
                    Args,
                    Context
                )
            ),
        {ok, {Body1, Args0}}
    catch
        error:{unbound_var, Fail} ->
            ?LOG_ERROR("unbound_var ~p", [Fail]),
            {error, {Body0, Args}, {unbound_var, Fail}};
        error:Reason ->
            {error, {Body0, Args}, {render, Reason}};
        Other ->
            {error, {Body0, Args}, {unknown, Other}}
    end.

test() ->
    {ok, TestUserEmail} = application:get_env(damage, test_user),
    {PubKey, _Password, _PrivateKey} = identity_server:get_account_by_email(
        list_to_binary(TestUserEmail)
    ),
    TestKey = <<"testkey">>,
    TestValue = <<"testvalue">>,
    TestMeta = #{},
    contract_add_context(PubKey, TestKey, TestValue, TestMeta).

test_account_context() ->
    Body = <<"blah ablasd assd a testpasswordaasdsdada">>,
    Args = <<"blah ablasd assd a testpasswordaasdsdada">>,
    clean_secrets(#{}, Body, Args).
