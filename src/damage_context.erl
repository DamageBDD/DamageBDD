-module(damage_context).

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, from_html/2]).
-export([content_types_accepted/2]).
-export([get_account_context/1]).
-export([trails/0]).
-export([clean_secrets/3]).
-export([test_account_context/0]).
-export([is_authorized/2]).
-export([delete_resource/2]).
-export([get_global_template_context/1]).

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

from_json(Req, #{username := Username} = State) ->
    {ok, Data, Req0} = cowboy_req:read_body(Req),
    ?LOG_DEBUG("post action ~p ", [Data]),
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
        #{key := Key, value := Value, masked := Masked} ->
            Result = damage_ae:add_context(Username, Key, Value, Masked),
            Resp =
                cowboy_req:set_resp_body(
                    jsx:encode(#{status => <<"ok">>, result => Result}),
                    Req
                ),
            ?LOG_DEBUG("post response ~p ~p ", [Resp]),
            {stop, cowboy_req:reply(201, Resp), State}
    end.

to_json(Req, #{action := context, username := Username} = State) ->
    ?LOG_DEBUG("context action ~p", [State]),
    {ok, ClientContextRaw} = damage_ae:get_account_context(Username),
    {jsx:encode(ClientContextRaw), Req, State}.

delete_resource(Req, #{username := Username} = State) ->
    Deleted =
        lists:foldl(
            fun(DeleteId, Acc) ->
                ?LOG_DEBUG("deleted ~p ~p", [maps:get(path_info, Req), DeleteId]),
                ok = damage_ae:delete_context(Username, DeleteId),
                Acc + 1
            end,
            0,
            maps:get(path_info, Req)
        ),
    ?LOG_INFO("deleted ~p context", [Deleted]),
    {true, Req, State}.

get_global_template_context(Context) ->
    {ok, DamageApi} = application:get_env(damage, api_url),
    {ok, DamageTokenContract} = application:get_env(damage, token_contract),
    {ok, DamageAccountContract} = application:get_env(damage, account_contract),
    {ok, NodePublicKey} = application:get_env(damage, node_public_key),
    maps:merge(
        #{
            api_url => DamageApi,
            formatter_state => #damage_state{},
            headers => [],
            token_contract => list_to_binary(DamageTokenContract),
            account_contract => list_to_binary(DamageAccountContract),
            node_public_key => list_to_binary(NodePublicKey),
            timestamp => date_util:now_to_seconds_hires(os:timestamp())
        },
        Context
    ).

get_account_context(#{username := Username} = DefaultContext) ->
    ClientContextRaw = damage_ae:get_account_context(Username),
    ClientContext =
        maps:map(
            fun
                (_Key, Value) when is_map(Value) -> maps:get(value, Value);
                (_Key, Value) -> Value
            end,
            ClientContextRaw
        ),
    damage_webhooks:load_all_webhooks(
        maps:put(
            client_context,
            ClientContext,
            maps:merge(DefaultContext, ClientContext)
        )
    ).

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

test_account_context() ->
    Body = <<"blah ablasd assd a testpasswordaasdsdada">>,
    Args = <<"blah ablasd assd a testpasswordaasdsdada">>,
    clean_secrets(#{}, Body, Args).
