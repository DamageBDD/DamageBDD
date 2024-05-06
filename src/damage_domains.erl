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
-export([is_allowed_domain/1]).
-export([lookup_domain/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Test Reports"]).

trails() ->
  [
    trails:trail(
      "/accounts/domains",
      damage_accounts,
      #{action => domains},
      #{
        get
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "List domain tokens.",
          produces => ["text/plain"],
          parameters => []
        },
        put
        =>
        #{
          tags => ?TRAILS_TAG,
          description => "Submit reset password form.",
          produces => ["text/plain"],
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

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

to_json(_Req, #{action := domains, contract_address := ContractAddress} = State) ->
  {Status, Result} =
    case damage_riak:get(?DOMAIN_TOKEN_BUCKET, ContractAddress) of
      [] -> {200, []};
      Found -> {200, Found}
    end,
  {stop, cowboy_req:reply(Status, jsx:encode(Result)), State}.


from_json(Req, #{action := domain, user := User} = State) ->
  {Status, Result} =
    case damage_auth:issue_token({ok, User, domain}) of
      [] -> {400, []};
      Found -> {200, Found}
    end,
  JsonResult = jsx:encode(Result),
  Resp = cowboy_req:set_resp_body(JsonResult, Req),
  {stop, cowboy_req:reply(Status, Resp), State}.


lookup_domain(Domain) when is_binary(Domain) ->
  lookup_domain(binary_to_list(Domain));

lookup_domain(Domain) ->
  case inet_res:lookup(Domain, in, txt) of
    Records when is_list(Records) ->
      case lists:filtermap(
        fun
          ([Record]) ->
            case string:split(Record, "=") of
              ["damagebdd_token", Token] -> Token;
              _ -> false
            end
        end,
        Records
      ) of
        [] ->
          io:format("No TXT record found for token: ~p~n", [Records]),
          false;

        [Token | _] -> ok = check_host_token(Domain, Token)
      end;

    Other ->
      ?LOG_DEBUG("dns record look up failed ~p ~p", [Domain, Other]),
      false
  end.


is_allowed_domain(Host) when is_binary(Host) ->
  is_allowed_domain(binary_to_list(Host));

is_allowed_domain(Host) ->
  ?LOG_DEBUG("Host check ~p", [Host]),
    case string:split(Host,".",trailing) of
        [_,"lan"] ->
            true;
        [_,"local"] ->
            true;
        _ ->
            AllowedHosts =
                ["jsontest.com", "damagebdd.com", "run.damagebdd.com", "localhost"],
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
                false -> lookup_domain(Host);
                true -> true
            end
end.


check_host_token(_Host, Token) ->
  case oauth2:verify_access_token(Token, []) of
    {ok, {[], Auth}} ->
      #{
        <<"client">> := _Client,
        <<"resource_owner">> := ResourceOwner,
        <<"expiry_time">> := _Expiry,
        <<"scope">> := domain
      } = maps:from_list(Auth),
      case damage_riak:get(?USER_BUCKET, ResourceOwner) of
        {ok, _User} -> ok;
        _ -> false
      end;

    _ -> false
  end.


test() -> ok.
