%%--------------------------------------------------------------------
%% Read-only operator REST surface for the Wikimedia visibility corpus.
%% Index execution and lifecycle control live exclusively under
%% /ecai/index-jobs.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_http).

-export([
    init/2,
    trails/0,
    is_authorized/2,
    allowed_methods/2,
    content_types_provided/2,
    to_json/2
]).

-define(JSON, <<"application/json">>).
-define(TRAILS_TAG, ["ECAI Wikimedia Index"]).

trails() ->
    [
        get_trail("/ecai/wikimedia/sources", sources),
        get_trail("/ecai/wikimedia/plan", plan),
        get_trail("/ecai/wikimedia/search", search),
        get_trail("/ecai/wikimedia/doctor", doctor)
    ].

get_trail(Path, Action) ->
    trails:trail(
        Path,
        ?MODULE,
        #{action => Action},
        #{get => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
    ).

init(Req, State) ->
    {cowboy_rest, Req, State}.

is_authorized(Req, State) ->
    damage_http:is_authorized(Req, State).

allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

to_json(Req0, #{action := sources} = State) ->
    Query = maps:from_list(cowboy_req:parse_qs(Req0)),
    Opts = source_options(Query),
    case safe_call(fun() -> ecai_wikimedia_catalog:list_sources(Opts) end) of
        {ok, {ok, Result}} ->
            reply_json(Req0, 200, #{ok => true, sources => Result}, State);
        {ok, {error, Reason}} ->
            reply_error(Req0, 422, Reason, State);
        {error, Reason} ->
            reply_error(Req0, 503, Reason, State)
    end;
to_json(Req0, #{action := plan} = State) ->
    Query = maps:from_list(cowboy_req:parse_qs(Req0)),
    case simple_overrides(Query) of
        {ok, Overrides} ->
            case safe_call(fun() -> ecai_wikimedia_ops:plan(Overrides) end) of
                {ok, {ok, Plan}} ->
                    reply_json(Req0, 200, #{ok => true, plan => Plan}, State);
                {ok, {error, Reason}} ->
                    reply_error(Req0, 422, Reason, State);
                {error, Reason} ->
                    reply_error(Req0, 503, Reason, State)
            end;
        {error, Reason} ->
            reply_error(Req0, 400, Reason, State)
    end;
to_json(Req0, #{action := search} = State) ->
    Query = maps:from_list(cowboy_req:parse_qs(Req0)),
    case maps:get(<<"q">>, Query, <<>>) of
        <<>> ->
            reply_error(Req0, 400, missing_query, State);
        Text ->
            case search_options(Query) of
                {ok, Opts} ->
                    case safe_call(fun() -> ecai_wikimedia_search:search(Text, Opts) end) of
                        {ok, {ok, Result}} ->
                            reply_json(Req0, 200, #{ok => true, search => Result}, State);
                        {ok, {error, Reason}} ->
                            reply_error(Req0, 422, Reason, State);
                        {error, Reason} ->
                            reply_error(Req0, 503, Reason, State)
                    end;
                {error, Reason} ->
                    reply_error(Req0, 400, Reason, State)
            end
    end;
to_json(Req0, #{action := doctor} = State) ->
    case safe_call(fun ecai_wikimedia_ops:doctor/0) of
        {ok, Result} ->
            reply_json(Req0, 200, #{ok => true, doctor => Result}, State);
        {error, Reason} ->
            reply_error(Req0, 503, Reason, State)
    end;
to_json(Req0, State) ->
    reply_error(Req0, 404, not_found, State).

%% No work is enqueued here anymore. The UI builds the normalized job spec and
%% submits it to POST /ecai/index-jobs, which is the single lifecycle API.
source_options(Query) ->
    Base = #{
        project => maps:get(<<"project">>, Query, <<"enwiki">>),
        pageview_project => maps:get(
            <<"pageview_project">>,
            Query,
            <<"en.wikipedia">>
        )
    },
    case maps:get(<<"months">>, Query, undefined) of
        undefined -> Base;
        Value -> Base#{pageview_months => split_csv(Value)}
    end.

simple_overrides(Query) ->
    Source = source_override_fields(Query),
    case strict_override_fields(Query, numeric_override_specs(), fun parse_integer/1) of
        {ok, Numeric} ->
            case
                strict_override_fields(
                    Query,
                    boolean_override_specs(),
                    fun parse_boolean/1
                )
            of
                {ok, Boolean} ->
                    {ok, maps:merge(Source, maps:merge(Numeric, Boolean))};
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

source_override_fields(Map) ->
    lists:foldl(
        fun({External, Internal}, Acc) ->
            case maps:get(External, Map, undefined) of
                undefined ->
                    Acc;
                Value when
                    External =:= <<"pageview_months">>;
                    External =:= <<"months">>
                ->
                    Acc#{pageview_months => normalize_month_input(Value)};
                Value ->
                    Acc#{Internal => Value}
            end
        end,
        #{},
        [
            {<<"project">>, project},
            {<<"pageview_project">>, pageview_project},
            {<<"content_release">>, content_release},
            {<<"pageview_months">>, pageview_months},
            {<<"months">>, pageview_months},
            {<<"index_id">>, index_id},
            {<<"namespace">>, namespace},
            {<<"base_dir">>, base_dir},
            {<<"previous_manifest_cid">>, previous_manifest_cid}
        ]
    ).

strict_override_fields(Map, Specs, Parser) ->
    strict_override_fields(Map, Specs, Parser, #{}).

strict_override_fields(_Map, [], _Parser, Acc) ->
    {ok, Acc};
strict_override_fields(Map, [{External, Internal} | Rest], Parser, Acc) ->
    case maps:get(External, Map, undefined) of
        undefined ->
            strict_override_fields(Map, Rest, Parser, Acc);
        RawValue ->
            case Parser(RawValue) of
                {ok, Value} ->
                    strict_override_fields(
                        Map,
                        Rest,
                        Parser,
                        Acc#{Internal => Value}
                    );
                error ->
                    {error, {invalid_parameter, External, RawValue}}
            end
    end.

numeric_override_specs() ->
    [
        {<<"limit">>, limit},
        {<<"minimum_active_months">>, minimum_active_months},
        {<<"selection_shards">>, selection_shards},
        {<<"oversample_percent">>, oversample_percent},
        {<<"partition_buffer_bytes">>, partition_buffer_bytes},
        {<<"abstract_max_bytes">>, abstract_max_bytes},
        {<<"cirrus_max_line_bytes">>, cirrus_max_line_bytes},
        {<<"index_chunk_lines">>, index_chunk_lines},
        {<<"priority">>, priority},
        {<<"max_retries">>, max_retries}
    ].

boolean_override_specs() ->
    [
        {<<"publish_ipfs">>, publish_ipfs},
        {<<"publish_activity_ipfs">>, publish_activity_ipfs},
        {<<"publish_extracted_ipfs">>, publish_extracted_ipfs},
        {<<"keep_downloads">>, keep_downloads},
        {<<"keep_intermediates">>, keep_intermediates}
    ].

search_options(Query) ->
    NumericSpecs = [
        {<<"limit">>, limit},
        {<<"minimum_pageviews">>, minimum_pageviews},
        {<<"maximum_rank">>, maximum_rank}
    ],
    case strict_override_fields(Query, NumericSpecs, fun parse_integer/1) of
        {ok, Numeric0} ->
            Numeric = maps:merge(
                #{limit => 25, minimum_pageviews => 0},
                Numeric0
            ),
            case
                strict_override_fields(
                    Query,
                    [
                        {<<"has_wikidata">>, has_wikidata},
                        {<<"dedupe_entities">>, dedupe_entities}
                    ],
                    fun parse_boolean/1
                )
            of
                {ok, Boolean} ->
                    Base = maps:merge(Numeric, Boolean),
                    {ok,
                        optional_put(
                            language,
                            maps:get(<<"language">>, Query, undefined),
                            Base
                        )};
                {error, _Reason} = Error ->
                    Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

safe_call(Fun) ->
    try Fun() of
        Result -> {ok, Result}
    catch
        exit:Reason -> {error, {service_unavailable, Reason}};
        Class:Reason -> {error, {service_failed, Class, Reason}}
    end.

reply_error(Req, Code, Reason, State) ->
    reply_json(
        Req,
        Code,
        #{ok => false, error => ecai_index_job_codec:externalize(Reason)},
        State
    ).

reply_json(Req0, Code, Map, State) ->
    Req1 = cowboy_req:reply(
        Code,
        #{<<"content-type">> => ?JSON},
        jsx:encode(ecai_index_job_codec:externalize(Map)),
        Req0
    ),
    {stop, Req1, State}.

normalize_month_input(Value) when is_list(Value) -> Value;
normalize_month_input(Value) when is_binary(Value) -> split_csv(Value);
normalize_month_input(_Value) -> [].

split_csv(Bin) when is_binary(Bin) ->
    [Part || Part <- binary:split(Bin, <<",">>, [global, trim_all]), Part =/= <<>>];
split_csv(List) when is_list(List) ->
    split_csv(unicode:characters_to_binary(List));
split_csv(_Other) ->
    [].

parse_integer(Value) when is_integer(Value) -> {ok, Value};
parse_integer(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        error:badarg -> error
    end;
parse_integer(_Value) ->
    error.

parse_boolean(true) -> {ok, true};
parse_boolean(false) -> {ok, false};
parse_boolean(<<"true">>) -> {ok, true};
parse_boolean(<<"false">>) -> {ok, false};
parse_boolean(<<"1">>) -> {ok, true};
parse_boolean(<<"0">>) -> {ok, false};
parse_boolean(_) -> error.

optional_put(_Key, undefined, Map) -> Map;
optional_put(Key, Value, Map) -> Map#{Key => Value}.
