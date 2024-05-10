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
-export([get_global_template_context/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("reporting/formatter.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Context Management"]).

trails() ->
  [
    trails:trail(
      "/context",
      damage_context,
      #{action => context},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "get context variables for account",
          produces => ["application/json"]
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Create a new invoice.",
          produces => ["application/json"],
          parameters
          =>
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

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

from_html(Req, State) -> from_json(Req, State).

from_json(Req, #{contract_address := ContractAddress} = State) ->
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

    PostData ->
      ?LOG_DEBUG("post data ~p ", [PostData]),
      {Status, Message} =
        update_account_context(
          damage_utils:binary_to_atom_keys(PostData),
          ContractAddress
        ),
      Resp =
        cowboy_req:set_resp_body(
          jsx:encode(#{status => <<"ok">>, message => Message}),
          Req
        ),
      ?LOG_DEBUG("post response ~p ~p ", [Status, Resp]),
      {stop, cowboy_req:reply(Status, Resp), State}
  end.


to_json(Req, #{action := context} = State) ->
  ?LOG_DEBUG("context action ~p", [State]),
  case damage_http:is_authorized(Req, State) of
    {true, _Req0, #{contract_address := ContractAddress} = _State0} ->
      ClientContext0 =
        case damage_riak:get(?CONTEXT_BUCKET, ContractAddress) of
          {ok, #{client_context := ClientContext}} -> ClientContext;
          notfound -> #{}
        end,
      {jsx:encode(ClientContext0), Req, State};

    Other ->
      ?LOG_DEBUG("unauthorized ~p", [Other]),
      {<<"Unauthorized.">>, Req, State}
  end.


get_global_template_context(Context) ->
  maps:put(
    formatter_state,
    #state{},
    maps:put(
      headers,
      [],
      maps:put(
        timestamp,
        date_util:now_to_seconds_hires(os:timestamp()),
        Context
      )
    )
  ).

get_account_context(#{contract_address := ContractAddress} = DefaultContext) ->
  case damage_riak:get(?CONTEXT_BUCKET, ContractAddress) of
    {ok, #{client_context := ClientContext} = AccountContext} ->
      ?LOG_DEBUG("got client context ~p", [AccountContext]),
      MergedContext = maps:map(
        fun
          (_Key, Value) when is_map(Value) -> maps:get(value, Value);
          (_Key, Value) -> Value
        end,
        ClientContext
      ),
    maps:put(client_context, ClientContext, MergedContext);

    Other ->
      ?LOG_DEBUG("got no client context ~p", [Other]),
      DefaultContext
  end.


update_account_context(
  #{name := VariableName, value := Value, secret := Secret} = InboundContext,
  ContractAddress
)
when is_map(InboundContext) ->
  case damage_riak:get(?CONTEXT_BUCKET, ContractAddress) of
    {ok, #{client_context := ClientContext} = ContractContext} ->
      ?LOG_DEBUG("update got account context ~p", [ContractContext]),
      UpdatedContext =
        maps:put(
          VariableName,
          #{value => Value, secret => Secret},
          ClientContext
        ),
      {ok, true} =
        damage_riak:put(
          ?CONTEXT_BUCKET,
          ContractAddress,
          maps:put(client_context, UpdatedContext, ContractContext)
        ),
      {202, <<"Client Context updated.">>};

    notfound ->
      NewContext = #{VariableName => #{value => Value, secret => Secret}},
      {ok, true} =
        damage_riak:put(
          ?CONTEXT_BUCKET,
          ContractAddress,
          maps:put(client_context, NewContext, #{})
        ),
      {201, <<"Client Context Created">>}
  end;

update_account_context(InvalidContext, _ContractAddress) ->
    ?LOG_DEBUG("Invalid context received ~p", [InvalidContext]),
  {400, #{<<"message">> => <<"invalid context.">>}}.


clean_secrets(#{client_context := ClientContext} = Context, Body, Args) ->
  %Password = list_to_binary(maps:get(damage_password, Context, "")),
  AccessToken = maps:get(access_token, Context, <<"null">>),
  Args0 = binary:replace(Args, AccessToken, <<"00REDACTED00">>),
  Body0 = binary:replace(Body, AccessToken, <<"00REDACTED00">>),
        clean_context_secrets(ClientContext, Body0, Args0).


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

          _ -> {Body1, Args1}
        end;

      (_Key, _Value, {Body1, Args1}) -> {Body1, Args1}
    end,
    {Body, Args},
    AccountContext
  ).


test_account_context() ->
  Body = <<"blah ablasd assd a testpasswordaasdsdada">>,
  Args = <<"blah ablasd assd a testpasswordaasdsdada">>,
  clean_secrets(#{}, Body, Args).
