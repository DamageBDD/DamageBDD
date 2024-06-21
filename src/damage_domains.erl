-module(damage_domains).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).
-export([test/0]).
-export([content_types_accepted/2]).
-export([trails/0]).
-export([delete_resource/2]).
-export([is_allowed_domain/2]).
-export([lookup_domain/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Test Reports"]).
-define(DOMAIN_TOKEN_EXPIRY, 144000).

trails() ->
  [
    trails:trail(
      "/domains",
      damage_domains,
      #{},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "List domain tokens.",
          produces => ["application/json"],
          parameters => []
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Create new domain auth.",
          produces => ["application/json"],
          parameters
          =>
          [
            #{
              name => <<"domain">>,
              description => <<"the domain for which to generate token for.">>,
              in => <<"body">>,
              required => true,
              type => <<"string">>
            }
          ]
        },
        delete
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Delete domain token",
          produces => ["application/json"],
          parameters => []
        }
      }
    )
  ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) -> damage_http:is_authorized(Req, State).

content_types_provided(Req, State) ->
  {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
  {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

allowed_methods(Req, State) ->
  {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

to_json(Req, #{ae_account := AeAccount} = State) ->
  ?LOG_DEBUG("domains ~p", [AeAccount]),
  Domains = list_domains(AeAccount),
  {jsx:encode(Domains), Req, State}.


from_json(Req, #{ae_account := AeAccount} = State) ->
  {ok, Data, _Req2} = cowboy_req:read_body(Req),
  {Status, Resp0} =
    case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
      {'EXIT', {badarg, Trace}} ->
        logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
        {400, <<"Json decoding failed.">>};

      #{domain := Domain} ->
        DomainToken = list_to_binary(uuid:to_string(uuid:uuid4())),
        DomainTokenKey = damage_utils:idhash_keys([AeAccount, Domain]),
        ?LOG_DEBUG("Domain token ~p", [DomainTokenKey]),
        case damage_riak:get(?DOMAIN_TOKEN_BUCKET, DomainTokenKey) of
          notfound ->
            DomainObj =
              #{
                domain_token => DomainToken,
                expiry => get_token_expiry(),
                domain => Domain
              },
            {ok, true} =
              damage_riak:put(
                ?DOMAIN_TOKEN_BUCKET,
                DomainTokenKey,
                DomainObj,
                [{{binary_index, "ae_account"}, [AeAccount]}]
              ),
            {202, DomainObj};

          {ok, Found} -> {200, Found}
        end
    end,
  Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
  cowboy_req:reply(Status, Resp),
  {stop, Resp, State}.


delete_resource(Req, State) ->
  Deleted =
    lists:foldl(
      fun
        (DeleteId, Acc) ->
          ?LOG_DEBUG("deleted ~p ~p", [maps:get(path_info, Req), DeleteId]),
          ok = damage_riak:delete(?DOMAIN_TOKEN_BUCKET, DeleteId),
          Acc + 1
      end,
      0,
      maps:get(path_info, Req)
    ),
  ?LOG_INFO("deleted ~p domain", [Deleted]),
  {true, Req, State}.


get_token_expiry() ->
  %{ok, Expiry} = datestring:format(<<"YmdHMS">>, ),
  date_util:epoch() + (?DOMAIN_TOKEN_EXPIRY * 60).


lookup_domain(Domain, AeAccount) when is_binary(Domain) ->
  lookup_domain(binary_to_list(Domain), AeAccount);

lookup_domain(Domain, AeAccount) ->
  case inet_res:lookup(Domain, in, txt) of
    Records when is_list(Records) ->
      ?LOG_DEBUG("DNS Records ~p", [Records]),
      case lists:filtermap(
        fun
          ([Record]) ->
            {
              true,
              lists:filtermap(
                fun
                  (DamageRecord) ->
                    case string:split(DamageRecord, "=") of
                      ["damage_token", Token] ->
                        ?LOG_DEBUG("dns record list ~p", [Token]),
                        {true, Token};

                      Other ->
                        ?LOG_DEBUG("dns record list ~p", [Other]),
                        false
                    end
                end,
                string:split(Record, ";")
              )
            };

          (Record) ->
            ?LOG_DEBUG("dns record nolist ~p", [Record]),
            case string:split(Record, "=") of
              ["damagebdd_token", Token] -> {true, Token};
              _ -> false
            end
        end,
        Records
      ) of
        [] ->
          io:format("No TXT record found for token: ~p~n", [Records]),
          false;

        [Tokens] ->
          ?LOG_DEBUG("check list tokens ~p", [Tokens]),
          lists:any(
            fun
              (Token) ->
                ?LOG_DEBUG("check list tokens ~p", [Token]),
                check_host_token(Domain, AeAccount, Token)
            end,
            Tokens
          )
      end;

    Other ->
      ?LOG_DEBUG("dns record look up failed ~p ~p", [Domain, Other]),
      false
  end.


is_allowed_domain(Host, AeAccount) when is_binary(Host) ->
  is_allowed_domain(binary_to_list(Host), AeAccount);

is_allowed_domain(Host, AeAccount) ->
  %?LOG_DEBUG("Host check ~p", [Host]),
  case string:split(Host, ".", trailing) of
    [_, "lan"] -> true;
    [_, "local"] -> true;

    _ ->
      AllowedHosts =
        [
          "jsontest.com",
          "damagebdd.com",
          "run.damagebdd.com",
          "localhost",
          "status.sendgrid.com"
        ],
      case lists:any(
        fun
          (LHost) ->
            case LHost of
              Host -> true;
              _ -> false
            end
        end,
        AllowedHosts
      ) of
        false -> lookup_domain(Host, AeAccount);
        true -> true
      end
  end.


check_host_token(Host0, AeAccount, Token0) ->
  Host = list_to_binary(Host0),
  Token = list_to_binary(Token0),
  DomainId = damage_utils:idhash_keys([AeAccount, Host]),
  ?LOG_DEBUG("CHECK domainid ~p ", [DomainId]),
  ?LOG_DEBUG("CHECK host ~p ~p", [Host, Token]),
  case get_domain(DomainId) of
    #{domain := Host, domain_token := Token} = _Domain ->
      ?LOG_DEBUG("CHECK OK ~p ~p", [Host, Token]),
      true;

    Other ->
      ?LOG_DEBUG("CHECK FAIL ~p ", [Other]),
      false
  end.


get_domain_unencrypted(DomainId) ->
  case damage_riak:get(?DOMAIN_TOKEN_BUCKET, DomainId) of
    {ok, Domain} ->
      ?LOG_DEBUG("Loaded DomainId ~p", [DomainId]),
      maps:put(id, DomainId, Domain);

    _ -> none
  end.


get_domain(DomainId) when is_binary(DomainId) ->
  case catch damage_utils:decrypt(DomainId) of
    error ->
      ?LOG_DEBUG("DomainId Decryption error ~p ", [DomainId]),
      get_domain_unencrypted(DomainId);

    {'EXIT', _Error} ->
      ?LOG_DEBUG("DomainId Decryption error ~p ", [DomainId]),
      get_domain_unencrypted(DomainId);

    DomainIdDecrypted -> get_domain_unencrypted(DomainIdDecrypted)
  end;

get_domain(_) -> none.


list_domains(AeAccount) ->
  ?LOG_DEBUG("Contract ~p", [AeAccount]),
  lists:filter(
    fun (none) -> false; (_Other) -> true end,
    [
      get_domain(DomainId)
      ||
      DomainId
      <-
      damage_riak:get_index(
        ?DOMAIN_TOKEN_BUCKET,
        {binary_index, "ae_account"},
        AeAccount
      )
    ]
  ).


test() -> ok.
