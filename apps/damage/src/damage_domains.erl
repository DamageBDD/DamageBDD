-module(damage_domains).

-vsn("0.2.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").
-copyright("Steven Joseph <steven@stevenjoseph.in>").
-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).
-export([content_types_accepted/2]).
-export([trails/0]).
-export([delete_resource/2]).
-export([is_allowed_domain/2]).
-export([lookup_domain/2]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Authorized Domains"]).
-define(DOMAIN_TOKEN_EXPIRY, 144000).
-define(DOMAINS_KEY, <<"damage.domains">>).
-define(DOMAINS_META, #{sensitive => false, exposure => step_only, inheritance => none}).

trails() ->
    [
        trails:trail(
            "/domains",
            damage_domains,
            #{},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "List domain verification tokens for the authenticated account.",
                    produces => ["application/json"]
                },
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Create or return a DNS verification token for a domain.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/domains/[...]",
            damage_domains,
            #{},
            #{
                delete => #{
                    tags => ?TRAILS_TAG,
                    description => "Delete domain verification token(s).",
                    produces => ["application/json"]
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

to_json(Req0, #{public_key := AeAccount} = State) ->
    Req = no_store(Req0),
    case load_domains(AeAccount) of
        {ok, Domains} ->
            {jsx:encode(Domains), Req, State};
        {error, Reason} ->
            ?LOG_ERROR("Domain context read failed account=~p reason=~p", [AeAccount, Reason]),
            reply_json_stop(
                503, #{status => <<"error">>, error => <<"DOMAIN_STORE_UNAVAILABLE">>}, Req, State
            )
    end.

from_json(Req0, #{public_key := AeAccount} = State) ->
    case cowboy_req:read_body(Req0, #{length => 8192, period => 5000}) of
        {ok, Data, Req} when byte_size(Data) =< 8192 ->
            case decode_domain_request(Data) of
                {ok, Domain} ->
                    case ensure_domain(AeAccount, Domain) of
                        {ok, created, DomainObj} ->
                            reply_json_stop(201, DomainObj, Req, State);
                        {ok, existing, DomainObj} ->
                            reply_json_stop(200, DomainObj, Req, State);
                        {error, Reason} ->
                            ?LOG_ERROR("Domain context write failed account=~p reason=~p", [
                                AeAccount, Reason
                            ]),
                            reply_json_stop(
                                503,
                                #{status => <<"error">>, error => <<"DOMAIN_STORE_UNAVAILABLE">>},
                                Req,
                                State
                            )
                    end;
                {error, Reason} ->
                    reply_json_stop(
                        400,
                        #{
                            status => <<"error">>,
                            error => <<"INVALID_DOMAIN">>,
                            reason => to_binary(Reason)
                        },
                        Req,
                        State
                    )
            end;
        {_, _, Req} ->
            reply_json_stop(
                413, #{status => <<"error">>, error => <<"DOMAIN_REQUEST_TOO_LARGE">>}, Req, State
            )
    end.

delete_resource(Req, #{public_key := AeAccount} = State) ->
    Ids = [to_binary(Id) || Id <- maps:get(path_info, Req, []), Id =/= <<>>],
    case delete_domains(AeAccount, Ids) of
        {ok, Deleted} ->
            ?LOG_INFO("Deleted domain authorizations account=~p count=~p", [AeAccount, Deleted]),
            {true, no_store(Req), State};
        {error, Reason} ->
            ?LOG_ERROR("Domain context delete failed account=~p reason=~p", [AeAccount, Reason]),
            reply_json_stop(
                503, #{status => <<"error">>, error => <<"DOMAIN_STORE_UNAVAILABLE">>}, Req, State
            )
    end.

ensure_domain(AeAccount, Domain) ->
    Id = damage_utils:idhash_keys([AeAccount, Domain]),
    case load_domains(AeAccount) of
        {ok, Domains} ->
            case maps:get(Id, Domains, undefined) of
                #{domain_token := _} = Existing ->
                    {ok, existing, Existing};
                _ ->
                    DomainObj = #{
                        id => Id,
                        domain_token => list_to_binary(uuid:to_string(uuid:uuid4())),
                        expiry => get_token_expiry(),
                        domain => Domain
                    },
                    case store_domains(AeAccount, maps:put(Id, DomainObj, Domains)) of
                        ok -> {ok, created, DomainObj};
                        {error, _} = Error -> Error
                    end
            end;
        {error, _} = Error ->
            Error
    end.

delete_domains(_AeAccount, []) ->
    {ok, 0};
delete_domains(AeAccount, Ids) ->
    case load_domains(AeAccount) of
        {ok, Domains0} ->
            {Domains, Deleted} = lists:foldl(
                fun(Id, {Acc, Count}) ->
                    case maps:is_key(Id, Acc) of
                        true -> {maps:remove(Id, Acc), Count + 1};
                        false -> {Acc, Count}
                    end
                end,
                {Domains0, 0},
                Ids
            ),
            case persist_domains(AeAccount, Domains) of
                ok -> {ok, Deleted};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

load_domains(AeAccount) ->
    Scope = damage_context:account_scope(AeAccount),
    case damage_context:get(Scope, ?DOMAINS_KEY) of
        {ok, Domains} when is_map(Domains) -> {ok, normalize_domains(Domains)};
        not_found -> {ok, #{}};
        {error, _} = Error -> Error;
        Other -> {error, {invalid_domain_store, Other}}
    end.

store_domains(AeAccount, Domains) ->
    Scope = damage_context:account_scope(AeAccount),
    case damage_context:put(Scope, ?DOMAINS_KEY, normalize_domains(Domains), ?DOMAINS_META) of
        {ok, _} -> ok;
        {error, _} = Error -> Error
    end.

persist_domains(AeAccount, Domains) when map_size(Domains) =:= 0 ->
    case damage_context:delete(damage_context:account_scope(AeAccount), ?DOMAINS_KEY) of
        {ok, _} -> ok;
        not_found -> ok;
        {error, _} = Error -> Error
    end;
persist_domains(AeAccount, Domains) ->
    store_domains(AeAccount, Domains).

normalize_domains(Domains) ->
    maps:from_list([
        begin
            Id = to_binary(Id0),
            Obj = normalize_domain_obj(Id, Obj0),
            {Id, Obj}
        end
     || {Id0, Obj0} <- maps:to_list(Domains), is_map(Obj0)
    ]).

normalize_domain_obj(Id, Obj) ->
    #{
        id => Id,
        domain => to_binary(map_get_any([domain, <<"domain">>], Obj, <<>>)),
        domain_token => to_binary(map_get_any([domain_token, <<"domain_token">>], Obj, <<>>)),
        expiry => int_value(map_get_any([expiry, <<"expiry">>], Obj, 0), 0)
    }.

decode_domain_request(Data) ->
    try jsx:decode(Data, [return_maps]) of
        #{<<"domain">> := Domain0} -> normalize_domain(Domain0);
        _ -> {error, missing_domain}
    catch
        _:_ -> {error, invalid_json}
    end.

normalize_domain(Domain0) ->
    Domain1 = list_to_binary(string:lowercase(string:trim(binary_to_list(to_binary(Domain0))))),
    case
        re:run(
            Domain1,
            <<"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$">>,
            [{capture, none}]
        )
    of
        match -> {ok, Domain1};
        nomatch -> {error, invalid_domain_name}
    end.

get_token_expiry() ->
    date_util:epoch() + (?DOMAIN_TOKEN_EXPIRY * 60).

lookup_domain(Domain, AeAccount) when is_binary(Domain) ->
    lookup_domain(binary_to_list(Domain), AeAccount);
lookup_domain(Domain0, AeAccount) ->
    Domain = string:lowercase(string:trim(Domain0)),
    case inet_res:lookup(Domain, in, txt) of
        Records when is_list(Records) ->
            Tokens = lists:usort(lists:flatmap(fun txt_tokens/1, Records)),
            ?LOG_DEBUG("DNS verification host=~p token_count=~p", [Domain, length(Tokens)]),
            lists:any(fun(Token) -> check_host_token(Domain, AeAccount, Token) end, Tokens);
        Other ->
            ?LOG_DEBUG("dns record lookup failed ~p ~p", [Domain, Other]),
            false
    end.

is_allowed_domain(Host, AeAccount) when is_binary(Host) ->
    is_allowed_domain(binary_to_list(Host), AeAccount);
is_allowed_domain(Host, AeAccount) ->
    case string:split(Host, ".", trailing) of
        [_, "lan"] ->
            true;
        [_, "local"] ->
            true;
        _ ->
            AllowedHosts = [
                "jsontest.com",
                "damagebdd.com",
                "run.damagebdd.com",
                "localhost",
                "status.sendgrid.com"
            ],
            case lists:member(Host, AllowedHosts) of
                true -> true;
                false -> lookup_domain(Host, AeAccount)
            end
    end.

check_host_token(Host0, AeAccount, Token0) ->
    Host = to_binary(string:lowercase(string:trim(to_list(Host0)))),
    Token = to_binary(string:trim(to_list(Token0))),
    DomainId = damage_utils:idhash_keys([AeAccount, Host]),
    case load_domains(AeAccount) of
        {ok, Domains} ->
            case maps:get(DomainId, Domains, undefined) of
                #{domain := Host, domain_token := Token, expiry := Expiry} ->
                    Expiry > date_util:epoch();
                _ ->
                    false
            end;
        {error, _} ->
            false
    end.

txt_tokens(Record0) ->
    Flat = txt_record_to_list(Record0),
    lists:filtermap(
        fun(Part0) ->
            Part = string:trim(Part0),
            case string:split(Part, "=", leading) of
                ["damage_token", Token] -> {true, string:trim(Token)};
                ["damagebdd_token", Token] -> {true, string:trim(Token)};
                _ -> false
            end
        end,
        string:split(Flat, ";", all)
    ).

txt_record_to_list(Bin) when is_binary(Bin) -> binary_to_list(Bin);
txt_record_to_list(List) when is_list(List) ->
    case io_lib:printable_unicode_list(List) of
        true -> List;
        false -> lists:flatten([txt_record_to_list(Item) || Item <- List])
    end;
txt_record_to_list(Other) ->
    to_list(Other).

no_store(Req0) ->
    Req1 = cowboy_req:set_resp_header(<<"cache-control">>, <<"private, no-store">>, Req0),
    cowboy_req:set_resp_header(<<"pragma">>, <<"no-cache">>, Req1).

reply_json_stop(Status, Body, Req0, State) ->
    Req = cowboy_req:reply(
        Status,
        #{
            <<"content-type">> => <<"application/json; charset=utf-8">>,
            <<"cache-control">> => <<"private, no-store">>,
            <<"x-content-type-options">> => <<"nosniff">>
        },
        jsx:encode(Body),
        Req0
    ),
    {stop, Req, State}.

map_get_any([K | Ks], Map, Default) ->
    case maps:find(K, Map) of
        {ok, V} -> V;
        error -> map_get_any(Ks, Map, Default)
    end;
map_get_any([], _Map, Default) ->
    Default.

int_value(V, _Default) when is_integer(V) -> V;
int_value(V, Default) when is_binary(V) ->
    try
        binary_to_integer(V)
    catch
        _:_ -> Default
    end;
int_value(_, Default) ->
    Default.

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) when is_integer(V) -> integer_to_binary(V);
to_binary(V) -> iolist_to_binary(io_lib:format("~p", [V])).

to_list(V) when is_list(V) -> V;
to_list(V) when is_binary(V) -> binary_to_list(V);
to_list(V) -> binary_to_list(to_binary(V)).

normalize_domain_test() ->
    ?assertEqual({ok, <<"example.com">>}, normalize_domain(<<" Example.COM ">>)),
    ?assertMatch({error, _}, normalize_domain(<<"https://example.com">>)),
    ?assertMatch({error, _}, normalize_domain(<<"localhost">>)).

txt_tokens_test() ->
    ?assertEqual(["abc"], txt_tokens("damagebdd_token=abc")),
    ?assertEqual(["abc"], txt_tokens(["damage_token=abc"])),
    ?assertEqual(["abc"], txt_tokens("v=one; damagebdd_token=abc; other=x")).
