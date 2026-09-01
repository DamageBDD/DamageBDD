%%--------------------------------------------------------------------
%% Wikimedia source discovery and immutable catalog generation.
%%
%% The catalog pins the exact CirrusSearch release, shard URLs and pageview
%% month URLs used by one indexing job. A job never re-resolves "latest" after
%% preparation, so restarts continue from the same source frontier.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_catalog).

-export([
    version/0,
    resolve/1,
    list_sources/1,
    list_cirrus_releases/0,
    list_cirrus_releases/1,
    list_cirrus_shards/2,
    pageview_sources/2,
    default_months/1,
    write/3,
    read/1,
    summary/1
]).

-define(SCHEMA, <<"ecai-wikimedia-catalog/v1">>).
-define(CIRRUS_ROOT, <<"https://dumps.wikimedia.org/other/cirrus_search_index/">>).
-define(PAGEVIEW_ROOT, <<"https://dumps.wikimedia.org/other/pageview_complete/monthly/">>).
-define(DEFAULT_HTTP_MAX, 16777216).

-spec version() -> binary().
version() -> ?SCHEMA.

-spec resolve(map()) -> {ok, map()} | {error, term()}.
resolve(Source0) when is_map(Source0) ->
    case optional_catalog(Source0) of
        {catalog, CatalogRef} -> read(CatalogRef);
        none -> resolve_online(Source0)
    end;
resolve(_Source) ->
    {error, badarg}.

-spec list_sources(map()) -> {ok, map()} | {error, term()}.
list_sources(Opts) when is_map(Opts) ->
    Project = binary_field(project, Opts, <<"enwiki">>),
    PageviewProject = binary_field(pageview_project, Opts, <<"en.wikipedia">>),
    Months = month_list(field(pageview_months, Opts, default_months(12))),
    case list_cirrus_releases(8) of
        {ok, Releases} ->
            {ok, #{
                schema => ?SCHEMA,
                project => Project,
                pageview_project => PageviewProject,
                available_cirrus_releases => Releases,
                requested_pageview_months => Months,
                cirrus_root => ?CIRRUS_ROOT,
                pageview_root => ?PAGEVIEW_ROOT
            }};
        {error, _Reason} = Error ->
            Error
    end;
list_sources(_Opts) ->
    {error, badarg}.

-spec list_cirrus_releases() -> {ok, [binary()]} | {error, term()}.
list_cirrus_releases() ->
    list_cirrus_releases(32).

-spec list_cirrus_releases(pos_integer()) -> {ok, [binary()]} | {error, term()}.
list_cirrus_releases(Limit) when is_integer(Limit), Limit > 0 ->
    case ecai_http_stream:get_binary(?CIRRUS_ROOT, ?DEFAULT_HTTP_MAX) of
        {ok, Html, _Meta} ->
            Releases0 = href_captures(Html, <<"([0-9]{8})/">>),
            Releases = lists:reverse(lists:sort(lists:usort(Releases0))),
            {ok, lists:sublist(Releases, Limit)};
        {error, _Reason} = Error ->
            Error
    end;
list_cirrus_releases(_Limit) ->
    {error, badarg}.

-spec list_cirrus_shards(binary(), binary()) -> {ok, [map()]} | {error, term()}.
list_cirrus_shards(Project0, Release0) ->
    try
        Project = required_token(project, Project0),
        Release = required_release(Release0),
        Directory = cirrus_directory(Project, Release),
        case ecai_http_stream:get_binary(Directory, ?DEFAULT_HTTP_MAX) of
            {ok, Html, _Meta} ->
                case binary:match(Html, <<"_SUCCESS">>) of
                    nomatch ->
                        {error, {cirrus_release_incomplete, Project, Release}};
                    _ ->
                        Pattern = <<"([A-Za-z0-9_.-]+_content-[0-9]{8}-[0-9]{5}\\.json\\.bz2)">>,
                        Names0 = href_captures(Html, Pattern),
                        Names = lists:sort(lists:usort(Names0)),
                        case Names of
                            [] ->
                                {error, {no_cirrus_shards, Project, Release}};
                            _ ->
                                {ok, [
                                    #{
                                        ordinal => Ordinal,
                                        name => Name,
                                        url => <<Directory/binary, Name/binary>>
                                    }
                                 || {Name, Ordinal} <- lists:zip(
                                        Names,
                                        lists:seq(1, length(Names))
                                    )
                                ]}
                        end
                end;
            {error, _Reason} = Error ->
                Error
        end
    catch
        throw:{catalog_error, Reason} -> {error, Reason}
    end.

-spec pageview_sources(binary(), [binary()]) -> {ok, [map()]} | {error, term()}.
pageview_sources(Project0, Months0) ->
    try
        Project = required_token(pageview_project, Project0),
        Months = month_list(Months0),
        pageview_sources_loop(Project, Months, 1, [])
    catch
        throw:{catalog_error, Reason} -> {error, Reason}
    end.

-spec default_months(pos_integer()) -> [binary()].
default_months(Count) when is_integer(Count), Count > 0, Count =< 120 ->
    {{Year, Month, _Day}, _Time} = calendar:universal_time(),
    {LastYear, LastMonth} = previous_month(Year, Month),
    default_months_loop(Count, LastYear, LastMonth, []);
default_months(_Count) ->
    erlang:error(badarg).

-spec write(file:filename_all(), map(), map()) -> {ok, map()} | {error, term()}.
write(BaseDir0, Catalog, Opts) when is_map(Catalog), is_map(Opts) ->
    try
        BaseDir = path_list(BaseDir0),
        Dir = filename:join(BaseDir, "catalog"),
        ok = filelib:ensure_dir(filename:join(Dir, "x")),
        Bytes = jsx:encode(ecai_index_job_codec:externalize(Catalog)),
        Digest = crypto:hash(sha256, ecai_index_job_codec:canonical_binary(Catalog)),
        Path = filename:join(Dir, "wikimedia-catalog.json"),
        ok = atomic_write(Path, Bytes),
        Publish = maps:get(publish_ipfs, Opts, false),
        Cid =
            case Publish of
                true ->
                    case normalize_add_response(damage_ipfs:add({file, Path})) of
                        {ok, Value} ->
                            Value;
                        {error, Reason} ->
                            throw({catalog_error, {catalog_ipfs_publish_failed, Reason}})
                    end;
                false ->
                    null
            end,
        {ok, #{
            path => unicode:characters_to_binary(Path),
            sha256 => ecai_index_job_codec:id_hex(Digest),
            cid => Cid,
            bytes => byte_size(Bytes)
        }}
    catch
        throw:{catalog_error, Reason0} -> {error, Reason0};
        error:badarg -> {error, badarg};
        Class:Reason1:Stacktrace -> {error, {catalog_write_failed, Class, Reason1, Stacktrace}}
    end;
write(_BaseDir, _Catalog, _Opts) ->
    {error, badarg}.

-spec read(binary() | list()) -> {ok, map()} | {error, term()}.
read(Ref0) ->
    try
        Ref = to_binary(Ref0),
        case filelib:is_regular(path_list(Ref)) of
            true ->
                decode_catalog_file(path_list(Ref));
            false ->
                case damage_ipfs:cat_binary(Ref) of
                    {ok, Bytes} -> decode_catalog(Bytes);
                    {error, Reason} -> {error, {catalog_fetch_failed, Ref, Reason}}
                end
        end
    catch
        error:badarg -> {error, badarg}
    end.

-spec summary(map()) -> map().
summary(Catalog) when is_map(Catalog) ->
    #{
        schema => maps:get(schema, Catalog, ?SCHEMA),
        project => maps:get(project, Catalog),
        pageview_project => maps:get(pageview_project, Catalog),
        cirrus_release => maps:get(cirrus_release, Catalog),
        pageview_months => maps:get(pageview_months, Catalog),
        content_shards => length(maps:get(content_shards, Catalog, [])),
        pageview_files => length(maps:get(pageview_sources, Catalog, [])),
        source_count =>
            length(maps:get(content_shards, Catalog, [])) +
            length(maps:get(pageview_sources, Catalog, []))
    }.

resolve_online(Source) ->
    try
        Project = required_token(project, field(project, Source, <<"enwiki">>)),
        PageviewProject = required_token(
            pageview_project,
            field(pageview_project, Source, <<"en.wikipedia">>)
        ),
        Months = month_list(field(pageview_months, Source, default_months(12))),
        ReleaseChoice = field(content_release, Source, <<"latest">>),
        case resolve_release_and_shards(Project, ReleaseChoice) of
            {ok, Release, Shards} ->
                case pageview_sources(PageviewProject, Months) of
                    {ok, Pageviews} ->
                        {ok, #{
                            schema => ?SCHEMA,
                            project => Project,
                            pageview_project => PageviewProject,
                            cirrus_release => Release,
                            content_shards => Shards,
                            pageview_months => Months,
                            pageview_sources => Pageviews
                        }};
                    {error, _Reason} = Error ->
                        Error
                end;
            {error, _Reason} = Error ->
                Error
        end
    catch
        throw:{catalog_error, Reason} -> {error, Reason}
    end.

resolve_release_and_shards(Project, latest) ->
    resolve_release_and_shards(Project, <<"latest">>);
resolve_release_and_shards(Project, <<"latest">>) ->
    case list_cirrus_releases(8) of
        {ok, Releases} -> find_complete_release(Project, Releases);
        {error, _Reason} = Error -> Error
    end;
resolve_release_and_shards(Project, Release0) ->
    try
        Release = required_release(Release0),
        case list_cirrus_shards(Project, Release) of
            {ok, Shards} -> {ok, Release, Shards};
            {error, _Reason} = Error -> Error
        end
    catch
        throw:{catalog_error, Reason} -> {error, Reason}
    end.

find_complete_release(_Project, []) ->
    {error, no_complete_cirrus_release};
find_complete_release(Project, [Release | Rest]) ->
    case list_cirrus_shards(Project, Release) of
        {ok, Shards} -> {ok, Release, Shards};
        {error, _Reason} -> find_complete_release(Project, Rest)
    end.

pageview_sources_loop(_Project, [], _Ordinal, Acc) ->
    {ok, lists:reverse(Acc)};
pageview_sources_loop(Project, [Month | Rest], Ordinal, Acc) ->
    <<Year:4/binary, "-", MonthNo:2/binary>> = Month,
    Compact = <<Year/binary, MonthNo/binary>>,
    Directory = <<?PAGEVIEW_ROOT/binary, Year/binary, "/", Month/binary, "/">>,
    Name = <<"pageviews-", Compact/binary, "-user.bz2">>,
    case ecai_http_stream:get_binary(Directory, ?DEFAULT_HTTP_MAX) of
        {ok, Html, _Meta} ->
            case binary:match(Html, Name) of
                nomatch ->
                    {error, {pageview_source_missing, Month, Name}};
                _ ->
                    Source = #{
                        ordinal => Ordinal,
                        month => Month,
                        name => Name,
                        url => <<Directory/binary, Name/binary>>,
                        project => Project
                    },
                    pageview_sources_loop(Project, Rest, Ordinal + 1, [Source | Acc])
            end;
        {error, Reason} ->
            {error, {pageview_directory_failed, Month, Reason}}
    end.

optional_catalog(Source) ->
    case field(catalog_cid, Source, undefined) of
        undefined ->
            case field(catalog_path, Source, undefined) of
                undefined -> none;
                Path -> {catalog, Path}
            end;
        Cid ->
            {catalog, Cid}
    end.

decode_catalog_file(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> decode_catalog(Bytes);
        {error, Reason} -> {error, {catalog_read_failed, Path, Reason}}
    end.

decode_catalog(Bytes) ->
    try jsx:decode(Bytes, [return_maps]) of
        External when is_map(External) -> normalize_catalog(External);
        _ -> {error, catalog_not_map}
    catch
        error:Reason -> {error, {invalid_catalog_json, Reason}}
    end.

normalize_catalog(Map) ->
    try
        Schema = binary_field(schema, Map, ?SCHEMA),
        case Schema =:= ?SCHEMA of
            true -> ok;
            false -> throw({catalog_error, {unsupported_catalog_schema, Schema}})
        end,
        Project = required_token(project, field(project, Map, undefined)),
        PageviewProject = required_token(
            pageview_project,
            field(pageview_project, Map, undefined)
        ),
        Release = required_release(field(cirrus_release, Map, undefined)),
        Months = month_list(field(pageview_months, Map, [])),
        Shards = normalize_catalog_sources(
            field(content_shards, Map, []),
            content_shard
        ),
        Pageviews = normalize_catalog_sources(
            field(pageview_sources, Map, []),
            pageview_source
        ),
        ok = validate_ordinals(Shards, content_shard),
        ok = validate_ordinals(Pageviews, pageview_source),
        ok = validate_pageview_consistency(Pageviews, PageviewProject, Months),
        {ok, #{
            schema => ?SCHEMA,
            project => Project,
            pageview_project => PageviewProject,
            cirrus_release => Release,
            content_shards => Shards,
            pageview_months => Months,
            pageview_sources => Pageviews
        }}
    catch
        throw:{catalog_error, Reason} -> {error, Reason}
    end.

normalize_catalog_sources(List, Kind) when is_list(List) ->
    [normalize_catalog_source(Item, Kind) || Item <- List];
normalize_catalog_sources(_Other, Kind) ->
    throw({catalog_error, {invalid_catalog_sources, Kind}}).

normalize_catalog_source(Item, content_shard) when is_map(Item) ->
    Name = safe_source_name(content_shard, binary_field(name, Item, <<>>)),
    Url = safe_source_url(content_shard, binary_field(url, Item, <<>>)),
    #{
        ordinal => positive_ordinal(Item),
        name => Name,
        url => Url
    };
normalize_catalog_source(Item, pageview_source) when is_map(Item) ->
    Name = safe_source_name(pageview_source, binary_field(name, Item, <<>>)),
    Url = safe_source_url(pageview_source, binary_field(url, Item, <<>>)),
    #{
        ordinal => positive_ordinal(Item),
        month => required_month(field(month, Item, undefined)),
        name => Name,
        url => Url,
        project => required_token(project, field(project, Item, undefined))
    };
normalize_catalog_source(_Item, Kind) ->
    throw({catalog_error, {invalid_catalog_source, Kind}}).

cirrus_directory(Project, Release) ->
    <<
        ?CIRRUS_ROOT/binary,
        Release/binary,
        "/index_name=",
        Project/binary,
        "_content/"
    >>.

href_captures(Html, Pattern) ->
    Regex = <<"href=[\\\"']", Pattern/binary, "[\\\"']">>,
    case re:run(Html, Regex, [global, {capture, [1], binary}, caseless]) of
        {match, Captures} -> [Value || [Value] <- Captures];
        nomatch -> []
    end.

month_list(Months) when is_list(Months), Months =/= [] ->
    Normalized = [required_month(Month) || Month <- Months],
    Canonical = lists:usort(Normalized),
    case Canonical =:= Normalized of
        true -> Canonical;
        false -> throw({catalog_error, {pageview_months_must_be_unique_and_sorted, Normalized}})
    end;
month_list([]) ->
    throw({catalog_error, {empty_field, pageview_months}});
month_list(_Other) ->
    throw({catalog_error, {invalid_field, pageview_months}}).

required_month(Value0) ->
    Value = to_binary(Value0),
    case re:run(Value, <<"^([0-9]{4})-([0-9]{2})$">>, [{capture, [1, 2], binary}]) of
        {match, [YearBin, MonthBin]} ->
            Year = binary_to_integer(YearBin),
            Month = binary_to_integer(MonthBin),
            case Year >= 2015 andalso Month >= 1 andalso Month =< 12 of
                true -> Value;
                false -> throw({catalog_error, {invalid_month, Value}})
            end;
        _ ->
            throw({catalog_error, {invalid_month, Value}})
    end.

required_release(Value0) ->
    Value = to_binary(Value0),
    case re:run(Value, <<"^[0-9]{8}$">>, [{capture, none}]) of
        match -> Value;
        _ -> throw({catalog_error, {invalid_release, Value}})
    end.

required_token(Name, Value0) ->
    Value = to_binary(Value0),
    case re:run(Value, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}]) of
        match when byte_size(Value) > 0, byte_size(Value) =< 128 -> Value;
        _ -> throw({catalog_error, {invalid_field, Name}})
    end.

positive_ordinal(Item) ->
    case integer_field(ordinal, Item, 0) of
        Value when is_integer(Value), Value > 0 -> Value;
        Other -> throw({catalog_error, {invalid_ordinal, Other}})
    end.

safe_source_name(Kind, Name) when is_binary(Name), byte_size(Name) > 0, byte_size(Name) =< 512 ->
    case
        filename:basename(binary_to_list(Name)) =:= binary_to_list(Name) andalso
            binary:match(Name, <<"..">>) =:= nomatch andalso
            binary:match(Name, <<0>>) =:= nomatch
    of
        true -> validate_source_suffix(Kind, Name);
        false -> throw({catalog_error, {unsafe_source_name, Name}})
    end;
safe_source_name(_Kind, Name) ->
    throw({catalog_error, {unsafe_source_name, Name}}).

validate_source_suffix(content_shard, Name) ->
    case binary:match(Name, <<".json.bz2">>) of
        {_, _} -> Name;
        nomatch -> throw({catalog_error, {invalid_content_shard_name, Name}})
    end;
validate_source_suffix(pageview_source, Name) ->
    case re:run(Name, <<"^pageviews-[0-9]{6}-user\\.bz2$">>, [{capture, none}]) of
        match -> Name;
        _ -> throw({catalog_error, {invalid_pageview_source_name, Name}})
    end.

safe_source_url(Kind, Url) when is_binary(Url), byte_size(Url) > 0, byte_size(Url) =< 4096 ->
    try uri_string:parse(Url) of
        Parsed ->
            Scheme = maps:get(scheme, Parsed, <<>>),
            Host = maps:get(host, Parsed, <<>>),
            case source_host_allowed(Scheme, Host) of
                true ->
                    Path = maps:get(path, Parsed, <<>>),
                    Name = unicode:characters_to_binary(filename:basename(binary_to_list(Path))),
                    _ = safe_source_name(Kind, Name),
                    Url;
                false ->
                    throw({catalog_error, {source_url_not_allowed, Url}})
            end
    catch
        throw:{catalog_error, Reason} -> throw({catalog_error, Reason});
        _:_ -> throw({catalog_error, {invalid_source_url, Url}})
    end;
safe_source_url(_Kind, Url) ->
    throw({catalog_error, {invalid_source_url, Url}}).

source_host_allowed(<<"https">>, <<"dumps.wikimedia.org">>) ->
    true;
source_host_allowed(Scheme, Host) ->
    Allowed0 = application:get_env(ecai, wikimedia_source_allowed_hosts, []),
    Allowed = [to_binary(Value) || Value <- Allowed0],
    Fixture = application:get_env(ecai, wikimedia_fixture_server_enabled, false),
    Loopback = lists:member(Host, [<<"127.0.0.1">>, <<"localhost">>, <<"::1">>]),
    (Scheme =:= <<"https">> andalso lists:member(Host, Allowed)) orelse
        (Fixture =:= true andalso Loopback andalso
            (Scheme =:= <<"http">> orelse Scheme =:= <<"https">>)).

validate_ordinals(Sources, Kind) ->
    Ordinals = [maps:get(ordinal, Source) || Source <- Sources],
    case length(Ordinals) =:= length(lists:usort(Ordinals)) of
        true -> ok;
        false -> throw({catalog_error, {duplicate_source_ordinals, Kind}})
    end.

validate_pageview_consistency(Pageviews, Project, Months) ->
    SourceMonths = [maps:get(month, Source) || Source <- Pageviews],
    case SourceMonths =:= Months of
        true -> ok;
        false -> throw({catalog_error, {pageview_source_window_mismatch, Months, SourceMonths}})
    end,
    case lists:all(fun(Source) -> maps:get(project, Source) =:= Project end, Pageviews) of
        true -> ok;
        false -> throw({catalog_error, {pageview_project_mismatch, Project}})
    end.

default_months_loop(0, _Year, _Month, Acc) ->
    Acc;
default_months_loop(Count, Year, Month, Acc) ->
    Value = iolist_to_binary(io_lib:format("~4..0B-~2..0B", [Year, Month])),
    {PrevYear, PrevMonth} = previous_month(Year, Month),
    default_months_loop(Count - 1, PrevYear, PrevMonth, [Value | Acc]).

previous_month(Year, 1) -> {Year - 1, 12};
previous_month(Year, Month) -> {Year, Month - 1}.

field(Key, Map, Default) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.

binary_field(Key, Map, Default) ->
    to_binary(field(Key, Map, Default)).

integer_field(Key, Map, Default) ->
    case field(Key, Map, Default) of
        Value when is_integer(Value) -> Value;
        Bin when is_binary(Bin) ->
            try
                binary_to_integer(Bin)
            catch
                error:badarg -> Default
            end;
        _ ->
            Default
    end.

to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) -> unicode:characters_to_binary(List);
to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(_Other) -> erlang:error(badarg).

path_list(Bin) when is_binary(Bin), byte_size(Bin) > 0 ->
    unicode:characters_to_list(Bin);
path_list(List) when is_list(List), List =/= [] -> List;
path_list(_Other) ->
    erlang:error(badarg).

atomic_write(Path, Bytes) ->
    Tmp = Path ++ ".tmp",
    case file:open(Tmp, [write, raw, binary]) of
        {ok, Fd} ->
            Result =
                try
                    ok = file:write(Fd, Bytes),
                    file:sync(Fd)
                after
                    ok = file:close(Fd)
                end,
            case Result of
                ok -> file:rename(Tmp, Path);
                {error, _Reason} = Error -> Error
            end;
        {error, Reason} ->
            {error, Reason}
    end.

normalize_add_response({ok, Value}) ->
    normalize_add_response(Value);
normalize_add_response([Value]) ->
    normalize_add_response(Value);
normalize_add_response(#{hash := Value}) ->
    normalize_add_response(Value);
normalize_add_response(#{<<"Hash">> := Value}) ->
    normalize_add_response(Value);
normalize_add_response(#{<<"hash">> := Value}) ->
    normalize_add_response(Value);
normalize_add_response(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> {ok, Bin};
normalize_add_response(List) when is_list(List), List =/= [] ->
    try unicode:characters_to_binary(string:trim(List)) of
        <<>> -> {error, empty_cid};
        Bin -> {ok, Bin}
    catch
        _:_ -> {error, invalid_cid}
    end;
normalize_add_response({error, _Reason} = Error) ->
    Error;
normalize_add_response(Other) ->
    {error, {invalid_ipfs_add_response, Other}}.
