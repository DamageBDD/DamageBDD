%%--------------------------------------------------------------------
%% Operator-friendly REST surface for the Wikimedia visibility corpus.
%%
%% Durable controls and SSE progress are shared with /ecai/index-jobs. This
%% handler provides concise source discovery, enqueue, search and health APIs.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_http).

-export([
    init/2,
    trails/0,
    is_authorized/2,
    allowed_methods/2,
    content_types_provided/2,
    content_types_accepted/2,
    to_json/2,
    from_json/2
]).

-define(JSON, <<"application/json">>).
-define(TRAILS_TAG, ["ECAI Wikimedia Index"]).
-define(MAX_BODY_BYTES, 1048576).

trails() ->
    [
        get_trail("/ecai/wikimedia/sources", sources),
        get_trail("/ecai/wikimedia/plan", plan),
        get_trail("/ecai/wikimedia/search", search),
        get_trail("/ecai/wikimedia/doctor", doctor),
        trails:trail(
            "/ecai/wikimedia/index",
            ?MODULE,
            #{action => index},
            #{post => #{tags => ?TRAILS_TAG, produces => ["application/json"]}}
        )
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

allowed_methods(Req, #{action := index} = State) ->
    {[<<"POST">>], Req, State};
allowed_methods(Req, State) ->
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, to_json}], Req, State}.

content_types_accepted(Req, #{action := index} = State) ->
    {[{{<<"application">>, <<"json">>, '*'}, from_json}], Req, State};
content_types_accepted(Req, State) ->
    {[], Req, State}.

to_json(Req0, #{action := sources} = State) ->
    Query = maps:from_list(cowboy_req:parse_qs(Req0)),
    Opts = source_options(Query),
    case safe_call(fun() -> ecai_wikimedia_catalog:list_sources(Opts) end) of
        {ok, {ok, Result}} -> reply_json(Req0, 200, #{ok => true, sources => Result}, State);
        {ok, {error, Reason}} -> reply_error(Req0, 422, Reason, State);
        {error, Reason} -> reply_error(Req0, 503, Reason, State)
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
                    case
                        safe_call(fun() ->
                            ecai_wikimedia_search:search(Text, Opts)
                        end)
                    of
                        {ok, {ok, Result}} ->
                            reply_json(
                                Req0,
                                200,
                                #{ok => true, search => Result},
                                State
                            );
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
        {ok, Result} -> reply_json(Req0, 200, #{ok => true, doctor => Result}, State);
        {error, Reason} -> reply_error(Req0, 503, Reason, State)
    end;
to_json(Req0, State) ->
    reply_error(Req0, 404, not_found, State).

from_json(Req0, #{action := index} = State) ->
    case read_json_map(Req0) of
        {ok, Body, Req1} ->
            case build_index_spec(Body) of
                {ok, Spec0} ->
                    Spec = bind_authenticated_owner(Spec0, State),
                    IdempotencyKey =
                        case
                            cowboy_req:header(
                                <<"idempotency-key">>,
                                Req1,
                                <<>>
                            )
                        of
                            <<>> -> default_idempotency_key(Spec);
                            Value -> Value
                        end,
                    case
                        safe_call(fun() ->
                            ecai_index_jobs_srv:enqueue(
                                Spec,
                                #{idempotency_key => IdempotencyKey}
                            )
                        end)
                    of
                        {ok, {ok, Job}} ->
                            JobId = maps:get(<<"id">>, Job),
                            reply_json(
                                Req1,
                                202,
                                #{
                                    ok => true,
                                    job => Job,
                                    events => <<
                                        "/ecai/index-jobs/",
                                        JobId/binary,
                                        "/events"
                                    >>,
                                    controls => #{
                                        pause => <<
                                            "/ecai/index-jobs/",
                                            JobId/binary,
                                            "/pause"
                                        >>,
                                        resume => <<
                                            "/ecai/index-jobs/",
                                            JobId/binary,
                                            "/resume"
                                        >>,
                                        cancel => <<
                                            "/ecai/index-jobs/",
                                            JobId/binary,
                                            "/cancel"
                                        >>,
                                        retry => <<
                                            "/ecai/index-jobs/",
                                            JobId/binary,
                                            "/retry"
                                        >>
                                    }
                                },
                                State
                            );
                        {ok, {error, Reason}} ->
                            reply_error(
                                Req1,
                                enqueue_error_code(Reason),
                                Reason,
                                State
                            );
                        {error, Reason} ->
                            reply_error(Req1, 503, Reason, State)
                    end;
                {error, Reason} ->
                    reply_error(Req1, 400, Reason, State)
            end;
        {error, Code, Reason, Req1} ->
            reply_error(Req1, Code, Reason, State)
    end;
from_json(Req0, State) ->
    reply_error(Req0, 404, not_found, State).

source_options(Query) ->
    Base = #{
        project => maps:get(<<"project">>, Query, <<"enwiki">>),
        pageview_project => maps:get(<<"pageview_project">>, Query, <<"en.wikipedia">>)
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

body_overrides(Body) ->
    maps:merge(
        source_override_fields(Body),
        maps:merge(
            raw_override_fields(Body, numeric_override_specs()),
            raw_override_fields(Body, boolean_override_specs())
        )
    ).

build_index_spec(Body) when is_map(Body) ->
    try
        case field(<<"kind">>, Body, undefined) of
            undefined -> {ok, ecai_wikimedia_ops:genesis_spec(body_overrides(Body))};
            _ -> {ok, Body}
        end
    catch
        error:badarg -> {error, invalid_request}
    end;
build_index_spec(_Body) ->
    {error, json_object_required}.

source_override_fields(Map) ->
    lists:foldl(
        fun({External, Internal}, Acc) ->
            case field(External, Map, undefined) of
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
            {<<"owner">>, owner},
            {<<"previous_manifest_cid">>, previous_manifest_cid}
        ]
    ).

strict_override_fields(Map, Specs, Parser) ->
    strict_override_fields(Map, Specs, Parser, #{}).

strict_override_fields(_Map, [], _Parser, Acc) ->
    {ok, Acc};
strict_override_fields(Map, [{External, Internal} | Rest], Parser, Acc) ->
    case field(External, Map, undefined) of
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

raw_override_fields(Map, Specs) ->
    lists:foldl(
        fun({External, Internal}, Acc) ->
            case field(External, Map, undefined) of
                undefined -> Acc;
                Value -> Acc#{Internal => Value}
            end
        end,
        #{},
        Specs
    ).

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

read_json_map(Req0) ->
    case cowboy_req:read_body(Req0, #{length => ?MAX_BODY_BYTES, period => 5000}) of
        {ok, Body, Req1} ->
            try jsx:decode(Body, [return_maps]) of
                Map when is_map(Map) -> {ok, Map, Req1};
                _ -> {error, 400, json_object_required, Req1}
            catch
                error:Reason -> {error, 400, {invalid_json, Reason}, Req1}
            end;
        {more, _Partial, Req1} ->
            {error, 413, payload_too_large, Req1}
    end.

bind_authenticated_owner(Spec, State) ->
    case authenticated_owner(State) of
        undefined -> Spec;
        Owner -> Spec#{<<"owner">> => Owner}
    end.

authenticated_owner(State) ->
    case maps:get(ae_account, State, maps:get(owner, State, undefined)) of
        Bin when is_binary(Bin), byte_size(Bin) > 0 -> Bin;
        List when is_list(List), List =/= [] ->
            try unicode:characters_to_binary(List) of
                Bin when is_binary(Bin), byte_size(Bin) > 0 -> Bin
            catch
                _:_ -> undefined
            end;
        _ ->
            undefined
    end.

default_idempotency_key(Spec) ->
    case ecai_index_job_codec:spec_hash(Spec) of
        {ok, Hash} -> <<"wikimedia-", (ecai_index_job_codec:id_hex(Hash))/binary>>;
        {error, _Reason} -> <<>>
    end.

enqueue_error_code({idempotency_conflict, _Existing, _Requested}) -> 409;
enqueue_error_code({queue_capacity_exceeded, _Current, _Limit}) -> 429;
enqueue_error_code({owner_queue_capacity_exceeded, _Owner, _Current, _Limit}) -> 429;
enqueue_error_code(_Reason) -> 422.

safe_call(Fun) ->
    try Fun() of
        Result -> {ok, Result}
    catch
        exit:Reason -> {error, {service_unavailable, Reason}};
        Class:Reason -> {error, {service_failed, Class, Reason}}
    end.

reply_error(Req, Code, Reason, State) ->
    reply_json(Req, Code, #{ok => false, error => ecai_index_job_codec:externalize(Reason)}, State).

reply_json(Req0, Code, Map, State) ->
    Req1 = cowboy_req:reply(
        Code,
        #{<<"content-type">> => ?JSON},
        jsx:encode(ecai_index_job_codec:externalize(Map)),
        Req0
    ),
    {stop, Req1, State}.

field(Key, Map, Default) when is_binary(Key), is_map(Map) -> maps:get(Key, Map, Default).

normalize_month_input(Value) when is_list(Value) -> Value;
normalize_month_input(Value) when is_binary(Value) -> split_csv(Value);
normalize_month_input(_Value) -> [].

split_csv(Bin) when is_binary(Bin) ->
    [Part || Part <- binary:split(Bin, <<",">>, [global, trim_all]), Part =/= <<>>];
split_csv(List) when is_list(List) -> split_csv(unicode:characters_to_binary(List));
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
