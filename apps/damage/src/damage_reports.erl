-module(damage_reports).

-vsn("0.1.0").

-include_lib("kernel/include/logger.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2]).
-export([to_html/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).
-export([test/0]).
-export([ls/1]).
-export([content_types_accepted/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("damage.hrl").

-define(TRAILS_TAG, ["Test Reports"]).

trails() ->
    [
        trails:trail(
            "/features/:hash/",
            damage_reports,
            #{action => features},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Get the test feature data.",
                        produces => ["text/plain", "application/json", "text/html"]
                    }
            }
        ),
        trails:trail(
            "/reports/",
            damage_reports,
            #{},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "List test execution report directory .",
                        produces => ["text/html"]
                    }
            }
        ),
        trails:trail(
            "/reports/:hash/[:path]",
            damage_reports,
            #{},
            #{
                get =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "List test execution report directory .",
                        produces => ["text/html", "application/json"]
                    },
                put =>
                    #{
                        tags => ?TRAILS_TAG,
                        description => "Query test reports",
                        produces => ["application/json"],
                        parameters =>
                            [
                                #{
                                    name => <<"start">>,
                                    description =>
                                        <<"Include Test execution reports from `start` date .">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"end">>,
                                    description =>
                                        <<"Include test execution reports to `end` date .">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"string">>
                                },
                                #{
                                    name => <<"tags">>,
                                    description =>
                                        <<"Include Test execution reports with tags matching `tags`.">>,
                                    in => <<"body">>,
                                    required => false,
                                    type => <<"string">>
                                }
                            ]
                    }
            }
        )
    ].

init(Req, Opts) -> {cowboy_rest, Req, Opts}.

is_authorized(Req, State) ->
    case cowboy_req:binding(hash, Req) of
        undefined -> damage_http:is_authorized(Req, State);
        Hash -> {true, Req, maps:put(hash, Hash, State)}
    end.

content_types_provided(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, to_json},
            {{<<"text">>, <<"html">>, []}, to_html},
            {{<<"text">>, <<"plain">>, []}, to_json}
        ],
        Req,
        State
    }.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State}.

allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>], Req, State}.

%% ================= Helpers =================

get_reports_dir(Hash) ->
    list_to_binary(string:join([binary_to_list(Hash), "reports"], "/")).

list_reports(Hash) ->
    Dir0 = ls(get_reports_dir(Hash)),
    lists:sort(fun(A, B) -> A =< B end, Dir0).

build_report_li(DamageApi, Hash, File) ->
    bbmustache:render(
        <<"<li><a href=\"{{api_url}}/reports/{{hash}}/{{file}}\">{{file}}</a></li>">>,
        damage_utils:normalize_context([
            {api_url, DamageApi},
            {hash, Hash},
            {file, File}
        ])
    ).

render_reports_index(Hash) ->
    {ok, DamageApi} = application:get_env(damage, api_url),
    Items =
        [
            binary_to_list(build_report_li(DamageApi, Hash, X))
         || X <- list_reports(Hash)
        ],
    ReportList = list_to_binary(string:join(Items, "\n")),
    damage_utils:load_template("report.mustache", #{reports_list => ReportList, hash => Hash}).

full_reports_path(PathList) ->
    string:join(["reports", PathList], "/").

render_report_html(Hash, PathList) ->
    FullPath = full_reports_path(PathList),
    HtmlFrag = cat(Hash, FullPath),
    damage_utils:load_template(
        "report_html.mustache",
        #{
            hash => Hash,
            path => list_to_binary(PathList),
            report_fragment => HtmlFrag
        }
    ).

reply_plain_text(Req, Txt) ->
    cowboy_req:reply(
        200,
        #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
        Txt,
        Req
    ).

route_report_file(Hash, Req, State, PathBin) ->
    PathList = binary_to_list(PathBin),
    FullPath = full_reports_path(PathList),
    case filename:extension(PathList) of
        ".html" ->
            {render_report_html(Hash, PathList), Req, State};
        ".txt" ->
            Txt = cat(Hash, FullPath),
            Req1 = reply_plain_text(Req, Txt),
            {stop, Req1, State};
        _Other ->
            {cat(Hash, FullPath), Req, State}
    end.

%% ================= Controller =================
to_html(Req, #{action := features} = State) ->
    ?LOG_DEBUG("feature to ", []),
    case cowboy_req:binding(hash, Req) of
        undefined ->
            {<<"Hash required">>, Req, State};
        Hash0 ->
            Hash = binary_to_list(Hash0),
            FeatureData = cat(list_to_binary(Hash), <<"">>),
            FeatureTitle =
                lists:nth(1, binary:split(FeatureData, <<"\n">>, [global])),
            Body =
                damage_utils:load_template(
                    "feature.mustache",
                    #{body => FeatureData, feature_title => FeatureTitle}
                ),
            {Body, Req, State}
    end;
to_html(Req, #{hash := Hash} = State) ->
    case cowboy_req:binding(path, Req) of
        undefined ->
            Body = render_reports_index(Hash),
            ?LOG_INFO("report html ~p", [Body]),
            {Body, Req, State};
        PathBin ->
            ?LOG_DEBUG("cat hash ~p", [Hash]),
            route_report_file(Hash, Req, State, PathBin)
    end.

to_json(Req, #{action := features} = State) ->
    ?LOG_DEBUG("feature to ", []),
    case cowboy_req:binding(hash, Req) of
        undefined ->
            {<<"Path required">>, Req, State};
        Hash0 ->
            Hash = binary_to_list(Hash0),
            {cat(list_to_binary(Hash), <<"">>), Req, State}
    end;
to_json(Req, #{public_key := AeAccount} = State) ->
    Reports =
        case cowboy_req:match_qs([{schedule_id, [], none}], Req) of
            #{schedule_id := none} ->
                do_query(#{public_key => AeAccount});
            #{schedule_id := ScheduleId} ->
                do_query(#{public_key => AeAccount, schedule_id => ScheduleId})
        end,
    {jsx:encode(Reports), Req, State};
to_json(Req, #{hash := Hash0} = State) ->
    {jsx:encode(get_reports(Req, Hash0)), Req, State}.

get_reports(Req, Hash) ->
    case cowboy_req:binding(path, Req) of
        undefined ->
            ls(list_to_binary(string:join([binary_to_list(Hash), "reports"], "/")));
        Path ->
            Path0 = string:join(["reports", binary_to_list(Path)], "/"),
            ?LOG_DEBUG(" cat hash ~p", [Hash]),
            cat(Hash, Path0)
    end.

get_record(Hash) ->
    case damage_ipfs:cat(Hash) of
        {ok, Record} -> Record;
        notfound -> none
    end.

do_query_base(Fun, Index, Args, AeAccount) when is_list(AeAccount) ->
    do_query_base(Fun, Index, Args, list_to_binary(AeAccount));
do_query_base(_Fun, Index, Args, AeAccount) ->
    Args0 = [?RUNRECORDS_BUCKET, Index] ++ Args ++ [[{max_results, 30}]],
    ?LOG_DEBUG("get reports query ~p", [Args0]),
    damage_ae:get_reports(AeAccount).

since_seconds(hours, Value) -> Value * 3600;
since_seconds(hour, Value) -> Value * 3600;
since_seconds(secs, Value) -> Value;
since_seconds(seconds, Value) -> Value;
since_seconds(day, Value) -> Value * 3600 * 24;
since_seconds(days, Value) -> Value * 3600 * 24;
since_seconds(week, Value) -> Value * 3600 * 24 * 7;
since_seconds(weeks, Value) -> Value * 3600 * 24 * 7.

range_query(StartDateTime0, EndDateTime0, Prefix, AeAccount) ->
    StartDateTime = list_to_integer(Prefix ++ integer_to_list(StartDateTime0)),
    EndDateTime = list_to_integer(Prefix ++ integer_to_list(EndDateTime0)),
    ?LOG_DEBUG("Since ~p to ~p", [StartDateTime, EndDateTime]),
    do_query_base(
        get_index_range,
        {integer_index, "result_status"},
        [StartDateTime, EndDateTime],
        AeAccount
    ).

do_query(#{public_key := AeAccount, since := Since0, status := Status}) ->
    Since = binary_to_list(Since0),
    case
        re:run(
            Since,
            "([0-9]+)(hours|hour|secs|seconds|day|days|week|weeks)",
            [{capture, [1, 2]}]
        )
    of
        {match, [{0, End}, {UnitStart, UnitEnd}]} ->
            StartDateTime0 =
                date_util:epoch() -
                    since_seconds(
                        list_to_atom(string:substr(Since, UnitStart + 1, UnitEnd)),
                        list_to_integer(string:substr(Since, 1, End))
                    ),
            EndDateTime0 = date_util:epoch(),
            case Status of
                <<"fail">> ->
                    range_query(
                        StartDateTime0,
                        EndDateTime0,
                        ?RESULT_STATUS_PREFIX_FAIL,
                        AeAccount
                    );
                <<"success">> ->
                    range_query(
                        StartDateTime0,
                        EndDateTime0,
                        ?RESULT_STATUS_PREFIX_SUCCESS,
                        AeAccount
                    )
            end;
        Other ->
            ?LOG_DEBUG("Invalid query ~p", [Other]),
            <<"Invalid query.">>
    end;
do_query(#{public_key := AeAccount, since := Since0}) ->
    Since = binary_to_list(Since0),
    case
        re:run(
            Since,
            "([0-9]+)(hours|hour|secs|seconds|day|days|week|weeks)",
            [{capture, [1, 2]}]
        )
    of
        {match, [{0, End}, {UnitStart, UnitEnd}]} ->
            StartDateTime =
                date_util:epoch() -
                    since_seconds(
                        list_to_atom(string:substr(Since, UnitStart + 1, UnitEnd)),
                        list_to_integer(string:substr(Since, 1, End))
                    ),
            EndDateTime = date_util:epoch(),
            ?LOG_DEBUG("Since ~p", [StartDateTime]),
            do_query_base(
                get_index_range,
                {integer_index, "created"},
                [StartDateTime, EndDateTime],
                AeAccount
            );
        Other ->
            ?LOG_DEBUG("Invalid query ~p", [Other]),
            <<"Invalid query.">>
    end;
do_query(#{public_key := AeAccount, schedule_id := ScheduleId}) ->
    do_query_base(
        get_index,
        {binary_index, "schedule_id"},
        [ScheduleId],
        AeAccount
    );
do_query(#{public_key := AeAccount}) ->
    case damage_ae:get_reports(AeAccount) of
        [] ->
            #{results => [], status => <<"ok">>, length => 0};
        Found ->
            Results =
                lists:filter(
                    fun
                        (none) -> false;
                        (_) -> true
                    end,
                    [get_record(X) || X <- Found]
                ),
            #{results => Results, status => <<"ok">>, length => length(Results)}
    end.

from_json(Req, #{public_key := AeAccount} = State) ->
    {ok, Data, _Req2} = cowboy_req:read_body(Req),
    {Status, Resp0} =
        case catch jsx:decode(Data, [{labels, atom}, return_maps]) of
            {'EXIT', {badarg, Trace}} ->
                logger:error("json decoding failed ~p err: ~p.", [Data, Trace]),
                {400, <<"Json decoding failed.">>};
            PostData ->
                QueryData = maps:merge(PostData, #{public_key => AeAccount}),
                ?LOG_DEBUG("Query data ~p", [QueryData]),
                {200, do_query(QueryData)}
        end,
    Resp = cowboy_req:set_resp_body(jsx:encode(Resp0), Req),
    cowboy_req:reply(Status, Resp),
    {stop, Resp, State}.

ls(Hash) ->
    {
        ok,
        [#{<<"Objects">> := [#{<<"Hash">> := Hash, <<"Links">> := Links} | _Rest]}]
    } = damage_ipfs:ls(Hash),
    logger:info("get ipfs hash ~p ", [Hash]),
    [maps:get(<<"Name">>, M) || M <- Links].

cat(Hash, Path) ->
    {ok, Data} =
        damage_ipfs:cat(
            list_to_binary(string:join([binary_to_list(Hash), Path], "/"))
        ),
    logger:info("get ipfs hash ~p ", [Hash]),
    Data.
test() ->
    {
        ok,
        [#{<<"Objects">> := [#{<<"Hash">> := Hash, <<"Links">> := Links} | Rest]}]
    } = damage_ipfs:test(),
    logger:info("list ipfs directory ~p ~p ~p", [Hash, Links, Rest]).
