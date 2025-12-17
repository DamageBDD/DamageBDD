%%-------------------------------------------------------------------
%% ecai_jobs_http.erl
%% Cowboy REST handler exposing ecai_jobs_srv
%%-------------------------------------------------------------------
-module(ecai_jobs_http).

-export([init/2]).
-export([content_types_accepted/2, content_types_provided/2]).
-export([allowed_methods/2, from_json/2, to_json/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").

-define(TRAILS_TAG, ["ECAI Jobs"]).

trails() ->
    [
        trails:trail(
            "/ecai/jobs/",
            ecai_jobs_http,
            #{action => list},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/ecai/jobs/publish",
            ecai_jobs_http,
            #{action => publish},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/ecai/jobs/:id",
            ecai_jobs_http,
            #{action => get},
            #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/ecai/jobs/:id/claim",
            ecai_jobs_http,
            #{action => claim},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/ecai/jobs/:id/submit",
            ecai_jobs_http,
            #{action => submit},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        ),
        trails:trail(
            "/ecai/jobs/:id/pay",
            ecai_jobs_http,
            #{action => pay},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, from_json}], Req, State}.

%% --- GET responders ---
to_json(Req0, #{action := list} = State) ->
    Qs = cowboy_req:parse_qs(Req0),
    Status =
        case lists:keyfind(<<"status">>, 1, Qs) of
            {_, V} -> binary_to_atom(V, utf8);
            false -> any
        end,
    {ok, Jobs} = ecai_jobs_srv:list(#{status => Status}),
    Body = jsx:encode(#{status => <<"ok">>, jobs => Jobs}),
    {Body, Req0, State};
to_json(Req0, #{action := get} = State) ->
    IdBin = cowboy_req:binding(id, Req0),
    Id = binary_to_integer(IdBin),
    case ecai_jobs_srv:get(Id) of
        {ok, Job} ->
            {jsx:encode(#{status => <<"ok">>, job => Job}), Req0, State};
        {error, not_found} ->
            {jsx:encode(#{status => <<"notok">>, error => <<"not_found">>}), Req0, State}
    end;
to_json(Req0, State) ->
    {jsx:encode(#{status => <<"ok">>}), Req0, State}.

%% --- POST handlers ---
from_json(Req0, #{action := publish} = State) ->
    {ok, Data, Req1} = cowboy_req:read_body(Req0),
    J = jsx:decode(Data, [{labels, atom}, return_maps]),
    OwnerAk = maps:get(owner_ak, J),
    MarketCt = maps:get(market_ct, J),
    Paths = maps:get(paths, J, []),
    Reward = maps:get(reward_damage, J),
    Ttl = maps:get(ttl_blocks, J),
    {ok, Ids} = ecai_jobs_srv:publish_chunks(OwnerAk, MarketCt, Paths, Reward, Ttl),
    Reply = #{status => <<"ok">>, job_ids => Ids},
    Req2 = cowboy_req:reply(
        200, #{<<"content-type">> => <<"application/json">>}, jsx:encode(Reply), Req1
    ),
    {stop, Req2, State};
from_json(Req0, #{action := claim} = State) ->
    {ok, Data, Req1} = cowboy_req:read_body(Req0),
    J = jsx:decode(Data, [{labels, atom}, return_maps]),
    MinerAk = maps:get(miner_ak, J),
    Id = binary_to_integer(cowboy_req:binding(id, Req1)),
    case ecai_jobs_srv:claim(Id, MinerAk) of
        {ok, Job} ->
            ok_reply(Req1, State, #{status => <<"ok">>, job => Job});
        {error, Reason} ->
            ok_reply(Req1, State, #{status => <<"notok">>, error => term_to_bin(Reason)})
    end;
from_json(Req0, #{action := submit} = State) ->
    {ok, Data, Req1} = cowboy_req:read_body(Req0),
    J = jsx:decode(Data, [{labels, atom}, return_maps]),
    MinerAk = maps:get(miner_ak, J),
    Att = maps:get(attestation, J),
    Evidence = maps:get(evidence_ref, J, undefined),
    Id = binary_to_integer(cowboy_req:binding(id, Req1)),
    case ecai_jobs_srv:submit(Id, MinerAk, Att, Evidence) of
        {ok, Job} ->
            ok_reply(Req1, State, #{status => <<"ok">>, job => Job});
        {error, Reason} ->
            ok_reply(Req1, State, #{status => <<"notok">>, error => term_to_bin(Reason)})
    end;
from_json(Req0, #{action := pay} = State) ->
    {ok, Data, Req1} = cowboy_req:read_body(Req0),
    J = jsx:decode(Data, [{labels, atom}, return_maps]),
    AdminAk = maps:get(admin_ak, J),
    Id = binary_to_integer(cowboy_req:binding(id, Req1)),
    case ecai_jobs_srv:pay(Id, AdminAk) of
        {ok, Job} ->
            ok_reply(Req1, State, #{status => <<"ok">>, job => Job});
        {error, Reason} ->
            ok_reply(Req1, State, #{status => <<"notok">>, error => term_to_bin(Reason)})
    end;
from_json(Req0, State) ->
    ok_reply(Req0, State, #{status => <<"notok">>, error => <<"bad_action">>}).

ok_reply(Req, State, Map) ->
    Req2 = cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(Map),
        Req
    ),
    {stop, Req2, State}.

term_to_bin(T) when is_binary(T) -> T;
term_to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).
