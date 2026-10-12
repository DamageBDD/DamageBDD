%%%-------------------------------------------------------------------
%%% Cached DamageBDD verification analytics HTTP resource.
%%%-------------------------------------------------------------------
-module(damage_analytics).

-author("Steven Joseph <steven@damagebdd.com>").
-license("Apache-2.0").

-export([
    trails/0,
    init/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    is_authorized/2,
    to_json/2,
    from_json/2
]).

-include_lib("kernel/include/logger.hrl").

trails() ->
    [
        trails:trail(
            "/api/analytics/summary",
            ?MODULE,
            #{action => summary},
            #{
                get => #{
                    tags => ["Analytics"],
                    description =>
                        "Read cached verification analytics for the authenticated account.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/analytics/status",
            ?MODULE,
            #{action => status},
            #{
                get => #{
                    tags => ["Analytics"],
                    description => "Read analytics cache/indexer health.",
                    produces => ["application/json"]
                }
            }
        ),
        trails:trail(
            "/api/analytics/refresh",
            ?MODULE,
            #{action => refresh},
            #{
                post => #{
                    tags => ["Analytics"],
                    description => "Request an asynchronous analytics reconciliation.",
                    produces => ["application/json"]
                }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

allowed_methods(Req, #{action := refresh} = State) -> {[<<"POST">>], Req, State};
allowed_methods(Req, State) -> {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}], Req, State}.

content_types_accepted(Req, #{action := refresh} = State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State};
content_types_accepted(Req, State) ->
    {[], Req, State}.

is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

to_json(Req0, #{action := summary, public_key := Account} = State) ->
    %% Register the authenticated account as a historical AEMDW source before
    %% reading the cache. Registration is cheap and starts an async sync only
    %% when the account is first seen by this node.
    _ = damage_analytics_indexer:track_account(Account),
    Params = maps:from_list(cowboy_req:parse_qs(Req0)),
    Days = window_days(maps:get(<<"window">>, Params, <<"30">>)),
    Summary = damage_analytics_store:summary(Account, Days),
    Body = jsx:encode(Summary),
    ETag = etag(Summary, Days),
    Req1 = set_summary_headers(Req0, ETag),
    case cowboy_req:header(<<"if-none-match">>, Req1) of
        ETag ->
            {stop,
                cowboy_req:reply(
                    304,
                    #{
                        <<"etag">> => ETag,
                        <<"cache-control">> => summary_cache_control()
                    },
                    <<>>,
                    Req1
                ),
                State};
        _ ->
            {Body, Req1, State}
    end;
to_json(Req0, #{action := status, public_key := Account} = State) ->
    _ = damage_analytics_indexer:track_account(Account),
    Store = damage_analytics_store:status(Account),
    Indexer = damage_analytics_indexer:status(),
    Req = cowboy_req:set_resp_header(<<"cache-control">>, <<"private, no-store">>, Req0),
    {jsx:encode(#{status => <<"ok">>, store => Store, indexer => Indexer}), Req, State};
to_json(Req0, State) ->
    Req = cowboy_req:set_resp_header(<<"cache-control">>, <<"private, no-store">>, Req0),
    {jsx:encode(#{status => <<"error">>, error => <<"unsupported analytics action">>}), Req, State}.

from_json(Req0, #{action := refresh, public_key := Account} = State) ->
    _ = damage_analytics_indexer:track_account(Account),
    %% Drain a small optional JSON body. Refresh is global because the indexer
    %% consumes the token contract once; account summaries remain isolated.
    Req = drain_body(Req0),
    ok = damage_analytics_indexer:refresh_async(),
    ok = damage_analytics_store:reproject_ecai(),
    Response = #{status => <<"accepted">>, account => Account, syncing => true},
    Req1 = cowboy_req:set_resp_header(<<"cache-control">>, <<"private, no-store">>, Req),
    {stop,
        cowboy_req:reply(
            202,
            #{<<"content-type">> => <<"application/json; charset=utf-8">>},
            jsx:encode(Response),
            Req1
        ),
        State}.

set_summary_headers(Req0, ETag) ->
    Req1 = cowboy_req:set_resp_header(<<"cache-control">>, summary_cache_control(), Req0),
    Req2 = cowboy_req:set_resp_header(<<"etag">>, ETag, Req1),
    cowboy_req:set_resp_header(<<"x-content-type-options">>, <<"nosniff">>, Req2).

summary_cache_control() ->
    <<"private, max-age=15, stale-while-revalidate=120, stale-if-error=300">>.

etag(Summary, Days) ->
    %% Hash the materialized content rather than the in-memory version counter so
    %% an application restart cannot accidentally reuse an ETag for different data.
    Snapshot = maps:without([freshness, version], Summary),
    Hash = crypto:hash(sha256, term_to_binary({Days, Snapshot}, [deterministic])),
    <<Short:12/binary, _/binary>> = binary:encode_hex(Hash),
    <<"W/\"analytics-", Short/binary, "\"">>.

window_days(<<"7">>) -> 7;
window_days(<<"30">>) -> 30;
window_days(<<"90">>) -> 90;
window_days(7) -> 7;
window_days(30) -> 30;
window_days(90) -> 90;
window_days(_) -> 30.

drain_body(Req0) ->
    case cowboy_req:read_body(Req0, #{length => 8192, period => 1000}) of
        {ok, _Body, Req} -> Req;
        {more, _Body, Req} -> drain_body(Req)
    end.
