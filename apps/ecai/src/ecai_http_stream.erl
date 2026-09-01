%%--------------------------------------------------------------------
%% Resumable, bounded HTTP(S) reads for large public corpus files.
%%
%% This module uses Gun, which is already an ECAI application dependency.
%% Downloads are written to DestPath ++ ".part" and atomically renamed only
%% after a complete response has been received and synced. A surviving partial
%% file is resumed with an HTTP Range request on the next attempt.
%%--------------------------------------------------------------------
-module(ecai_http_stream).

-export([
    get_binary/2,
    get_binary/3,
    download/2,
    download/3,
    parse_url/1,
    default_user_agent/0
]).

-define(DEFAULT_TIMEOUT_MS, 60000).
-define(DEFAULT_MAX_REDIRECTS, 5).
-define(DEFAULT_SYNC_BYTES, 67108864).
-define(DEFAULT_MAX_BINARY_BYTES, 16777216).

-type progress_fun() :: fun((map()) -> any()).

-spec default_user_agent() -> binary().
default_user_agent() ->
    application:get_env(
        ecai,
        wikimedia_user_agent,
        <<"DamageBDD-ECAI/1.0 (https://damagebdd.com; contact: operator@damagebdd.com)">>
    ).

-spec get_binary(binary() | list(), pos_integer()) ->
    {ok, binary(), map()} | {error, term()}.
get_binary(Url, MaxBytes) ->
    get_binary(Url, MaxBytes, #{}).

-spec get_binary(binary() | list(), pos_integer(), map()) ->
    {ok, binary(), map()} | {error, term()}.
get_binary(Url0, MaxBytes, Opts) when
    is_integer(MaxBytes),
    MaxBytes > 0,
    is_map(Opts)
->
    case parse_url(Url0) of
        {ok, Url} ->
            request_binary(
                Url, MaxBytes, Opts, maps:get(max_redirects, Opts, ?DEFAULT_MAX_REDIRECTS)
            );
        {error, _Reason} = Error ->
            Error
    end;
get_binary(_Url, _MaxBytes, _Opts) ->
    {error, badarg}.

-spec download(binary() | list(), file:filename_all()) ->
    {ok, map()} | {error, term()}.
download(Url, DestPath) ->
    download(Url, DestPath, #{}).

-spec download(binary() | list(), file:filename_all(), map()) ->
    {ok, map()} | {error, term()}.
download(Url0, DestPath0, Opts) when is_map(Opts) ->
    try
        DestPath = path_list(DestPath0),
        case parse_url(Url0) of
            {ok, Url} ->
                case filelib:is_regular(DestPath) of
                    true ->
                        case cached_source_matches(Url, DestPath) of
                            true ->
                                {ok, file_info_result(Url, DestPath, cached)};
                            false ->
                                {error,
                                    {cached_source_mismatch,
                                        unicode:characters_to_binary(DestPath)}}
                        end;
                    false ->
                        ok = filelib:ensure_dir(DestPath),
                        download_url(
                            Url,
                            DestPath,
                            Opts,
                            maps:get(max_redirects, Opts, ?DEFAULT_MAX_REDIRECTS)
                        )
                end;
            {error, _Reason} = Error ->
                Error
        end
    catch
        error:badarg -> {error, badarg};
        Class:Reason:Stacktrace -> {error, {http_download_failed, Class, Reason, Stacktrace}}
    end;
download(_Url, _DestPath, _Opts) ->
    {error, badarg}.

-spec parse_url(binary() | list()) -> {ok, map()} | {error, term()}.
parse_url(Url0) ->
    try
        UrlBin = to_binary(Url0),
        Parsed0 = uri_string:parse(UrlBin),
        Scheme = lower_binary(maps:get(scheme, Parsed0, <<>>)),
        Host = maps:get(host, Parsed0, undefined),
        case {Scheme, Host} of
            {<<"http">>, H} when is_binary(H), byte_size(H) > 0 ->
                {ok, normalize_parsed_url(UrlBin, Parsed0, 80, tcp)};
            {<<"https">>, H} when is_binary(H), byte_size(H) > 0 ->
                {ok, normalize_parsed_url(UrlBin, Parsed0, 443, tls)};
            _ ->
                {error, {unsupported_url, UrlBin}}
        end
    catch
        _Class:_Reason -> {error, {invalid_url, Url0}}
    end.

normalize_parsed_url(Original, Parsed, DefaultPort, Transport) ->
    Path0 = maps:get(path, Parsed, <<"/">>),
    Path1 =
        case Path0 of
            <<>> -> <<"/">>;
            _ -> Path0
        end,
    Query = maps:get(query, Parsed, undefined),
    Target =
        case Query of
            undefined -> Path1;
            <<>> -> Path1;
            _ -> <<Path1/binary, "?", Query/binary>>
        end,
    #{
        original => Original,
        scheme => lower_binary(maps:get(scheme, Parsed)),
        host => maps:get(host, Parsed),
        port => maps:get(port, Parsed, DefaultPort),
        transport => Transport,
        target => Target
    }.

request_binary(Url, MaxBytes, Opts, RedirectsLeft) ->
    Timeout = positive_opt(timeout_ms, Opts, ?DEFAULT_TIMEOUT_MS),
    Headers = request_headers(Opts, []),
    case open_connection(Url, Timeout) of
        {ok, ConnPid} ->
            try
                StreamRef = gun:get(ConnPid, maps:get(target, Url), Headers),
                case await_response(ConnPid, StreamRef, Timeout) of
                    {ok, Status, RespHeaders, fin} when Status >= 200, Status < 300 ->
                        {ok, <<>>, response_meta(Url, Status, RespHeaders, 0)};
                    {ok, Status, RespHeaders, nofin} when Status >= 200, Status < 300 ->
                        case collect_body(ConnPid, StreamRef, Timeout, MaxBytes, [], 0) of
                            {ok, Body, Count} ->
                                {ok, Body, response_meta(Url, Status, RespHeaders, Count)};
                            {error, _Reason} = Error ->
                                Error
                        end;
                    {ok, Status, RespHeaders, FinState} ->
                        case is_redirect(Status) of
                            true ->
                                follow_binary_redirect(
                                    Url,
                                    RespHeaders,
                                    MaxBytes,
                                    Opts,
                                    RedirectsLeft
                                );
                            false ->
                                {error, {
                                    http_status,
                                    Status,
                                    response_meta(Url, Status, RespHeaders, 0),
                                    FinState
                                }}
                        end;
                    {error, _Reason} = Error ->
                        Error
                end
            after
                safe_shutdown(ConnPid)
            end;
        {error, _Reason} = Error ->
            Error
    end.

follow_binary_redirect(_Url, _Headers, _MaxBytes, _Opts, RedirectsLeft) when RedirectsLeft =< 0 ->
    {error, too_many_redirects};
follow_binary_redirect(Url, Headers, MaxBytes, Opts, RedirectsLeft) ->
    case header_value(<<"location">>, Headers) of
        undefined ->
            {error, redirect_without_location};
        Location ->
            case resolve_location(Url, Location) of
                {ok, NextUrl} -> request_binary(NextUrl, MaxBytes, Opts, RedirectsLeft - 1);
                {error, _Reason} = Error -> Error
            end
    end.

collect_body(ConnPid, StreamRef, Timeout, MaxBytes, Acc, Count) ->
    receive
        {gun_data, ConnPid, StreamRef, nofin, Data} when is_binary(Data) ->
            NewCount = Count + byte_size(Data),
            case NewCount =< MaxBytes of
                true -> collect_body(ConnPid, StreamRef, Timeout, MaxBytes, [Data | Acc], NewCount);
                false -> {error, {response_too_large, NewCount, MaxBytes}}
            end;
        {gun_data, ConnPid, StreamRef, fin, Data} when is_binary(Data) ->
            NewCount = Count + byte_size(Data),
            case NewCount =< MaxBytes of
                true -> {ok, iolist_to_binary(lists:reverse([Data | Acc])), NewCount};
                false -> {error, {response_too_large, NewCount, MaxBytes}}
            end;
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {http_stream_error, Reason}};
        {gun_down, ConnPid, _Protocol, Reason, _KilledStreams} ->
            {error, {http_connection_down, Reason}};
        {gun_down, ConnPid, _Protocol, Reason, _KilledStreams, _UnprocessedStreams} ->
            {error, {http_connection_down, Reason}}
    after Timeout ->
        {error, http_timeout}
    end.

download_url(Url, DestPath, Opts, RedirectsLeft) ->
    PartPath = DestPath ++ ".part",
    ok = prepare_partial_for_url(Url, PartPath),
    Existing = file_size_or_zero(PartPath),
    Timeout = positive_opt(timeout_ms, Opts, ?DEFAULT_TIMEOUT_MS),
    RangeHeaders =
        case Existing of
            0 ->
                [];
            _ ->
                Range = {<<"range">>, <<"bytes=", (integer_to_binary(Existing))/binary, "-">>},
                case resume_validator(PartPath) of
                    undefined -> [Range];
                    Validator -> [Range, {<<"if-range">>, Validator}]
                end
        end,
    Headers = request_headers(Opts, RangeHeaders),
    case open_connection(Url, Timeout) of
        {ok, ConnPid} ->
            try
                StreamRef = gun:get(ConnPid, maps:get(target, Url), Headers),
                case await_response(ConnPid, StreamRef, Timeout) of
                    {ok, 416, RespHeaders, _FinState} when Existing > 0 ->
                        %% A 416 commonly means the local partial file already
                        %% equals the remote object. Only promote it when the
                        %% server provides a matching total size.
                        case range_total(RespHeaders) of
                            Existing ->
                                promote_part(
                                    Url,
                                    PartPath,
                                    DestPath,
                                    416,
                                    RespHeaders,
                                    Existing,
                                    Existing
                                );
                            _ ->
                                {error, {range_not_satisfiable, Existing}}
                        end;
                    {ok, Status, RespHeaders, FinState} when Status >= 200, Status < 300 ->
                        case validated_download_offset(Existing, Status, RespHeaders) of
                            {ok, Offset} ->
                                Mode =
                                    case Offset of
                                        0 -> [write, raw, binary];
                                        _ -> [append, raw, binary]
                                    end,
                                case file:open(PartPath, Mode) of
                                    {ok, Fd} ->
                                        try
                                            ok = write_resume_metadata(
                                                PartPath,
                                                Url,
                                                RespHeaders
                                            ),
                                            Total = response_total(
                                                Status,
                                                RespHeaders,
                                                Offset
                                            ),
                                            case FinState of
                                                fin ->
                                                    ok = file:sync(Fd),
                                                    promote_part(
                                                        Url,
                                                        PartPath,
                                                        DestPath,
                                                        Status,
                                                        RespHeaders,
                                                        Offset,
                                                        Total
                                                    );
                                                nofin ->
                                                    stream_to_file(
                                                        ConnPid,
                                                        StreamRef,
                                                        Fd,
                                                        Url,
                                                        PartPath,
                                                        DestPath,
                                                        Status,
                                                        RespHeaders,
                                                        Offset,
                                                        Total,
                                                        Opts,
                                                        Timeout
                                                    )
                                            end
                                        after
                                            ok = file:close(Fd)
                                        end;
                                    {error, Reason} ->
                                        {error, {download_open_failed, PartPath, Reason}}
                                end;
                            {error, _Reason} = Error ->
                                Error
                        end;
                    {ok, Status, RespHeaders, FinState} ->
                        case is_redirect(Status) of
                            true ->
                                case redirect_target(Url, RespHeaders, RedirectsLeft) of
                                    {ok, NextUrl} ->
                                        download_url(
                                            NextUrl,
                                            DestPath,
                                            Opts,
                                            RedirectsLeft - 1
                                        );
                                    {error, _Reason} = Error ->
                                        Error
                                end;
                            false ->
                                {error, {
                                    http_status,
                                    Status,
                                    response_meta(Url, Status, RespHeaders, Existing),
                                    FinState
                                }}
                        end;
                    {error, _Reason} = Error ->
                        Error
                end
            after
                safe_shutdown(ConnPid)
            end;
        {error, _Reason} = Error ->
            Error
    end.

redirect_target(_Url, _Headers, RedirectsLeft) when RedirectsLeft =< 0 ->
    {error, too_many_redirects};
redirect_target(Url, Headers, _RedirectsLeft) ->
    case header_value(<<"location">>, Headers) of
        undefined -> {error, redirect_without_location};
        Location -> resolve_location(Url, Location)
    end.

stream_to_file(
    ConnPid,
    StreamRef,
    Fd,
    Url,
    PartPath,
    DestPath,
    Status,
    RespHeaders,
    Offset,
    Total,
    Opts,
    Timeout
) ->
    SyncBytes = positive_opt(sync_bytes, Opts, ?DEFAULT_SYNC_BYTES),
    ProgressFun = maps:get(progress_fun, Opts, fun(_Progress) -> ok end),
    stream_file_loop(
        ConnPid,
        StreamRef,
        Fd,
        Url,
        PartPath,
        DestPath,
        Status,
        RespHeaders,
        Offset,
        Total,
        Offset,
        SyncBytes,
        ProgressFun,
        Timeout
    ).

stream_file_loop(
    ConnPid,
    StreamRef,
    Fd,
    Url,
    PartPath,
    DestPath,
    Status,
    RespHeaders,
    Count,
    Total,
    LastSync,
    SyncBytes,
    ProgressFun,
    Timeout
) ->
    receive
        {gun_data, ConnPid, StreamRef, Fin, Data} when is_binary(Data) ->
            case file:write(Fd, Data) of
                ok ->
                    Count1 = Count + byte_size(Data),
                    LastSync1 =
                        case Count1 - LastSync >= SyncBytes of
                            true ->
                                ok = file:sync(Fd),
                                Count1;
                            false ->
                                LastSync
                        end,
                    safe_progress(ProgressFun, #{
                        phase => downloading,
                        url => maps:get(original, Url),
                        path => unicode:characters_to_binary(PartPath),
                        bytes_completed => Count1,
                        bytes_total => Total
                    }),
                    case Fin of
                        fin ->
                            ok = file:sync(Fd),
                            promote_part(
                                Url,
                                PartPath,
                                DestPath,
                                Status,
                                RespHeaders,
                                Count1,
                                Total
                            );
                        nofin ->
                            stream_file_loop(
                                ConnPid,
                                StreamRef,
                                Fd,
                                Url,
                                PartPath,
                                DestPath,
                                Status,
                                RespHeaders,
                                Count1,
                                Total,
                                LastSync1,
                                SyncBytes,
                                ProgressFun,
                                Timeout
                            )
                    end;
                {error, Reason} ->
                    {error, {download_write_failed, PartPath, Reason}}
            end;
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {http_stream_error, Reason}};
        {gun_down, ConnPid, _Protocol, Reason, _KilledStreams} ->
            {error, {http_connection_down, Reason}};
        {gun_down, ConnPid, _Protocol, Reason, _KilledStreams, _UnprocessedStreams} ->
            {error, {http_connection_down, Reason}}
    after Timeout ->
        {error, http_timeout}
    end.

promote_part(Url, PartPath, DestPath, Status, RespHeaders, Count, Total) ->
    case total_matches(Count, Total) of
        false ->
            {error, {download_size_mismatch, Count, Total}};
        true ->
            case file:rename(PartPath, DestPath) of
                ok ->
                    _ = file:delete(resume_meta_path(PartPath)),
                    ok = write_final_source_metadata(DestPath, Url, RespHeaders, Count),
                    Meta0 = response_meta(Url, Status, RespHeaders, Count),
                    {ok, Meta0#{
                        path => unicode:characters_to_binary(DestPath)
                    }};
                {error, Reason} ->
                    {error, {download_rename_failed, PartPath, DestPath, Reason}}
            end
    end.

validated_download_offset(Existing, 206, Headers) ->
    case range_start(Headers) of
        Existing -> {ok, Existing};
        undefined -> {error, {missing_content_range, Existing}};
        Other -> {error, {range_start_mismatch, Existing, Other}}
    end;
validated_download_offset(_Existing, 200, _Headers) ->
    {ok, 0};
validated_download_offset(_Existing, Status, _Headers) ->
    {error, {unsupported_success_status, Status}}.

range_start(Headers) ->
    case header_value(<<"content-range">>, Headers) of
        undefined ->
            undefined;
        Value ->
            case
                re:run(
                    Value,
                    <<"^bytes[ ]+([0-9]+)-[0-9]+/[0-9*]+$">>,
                    [{capture, [1], binary}, caseless]
                )
            of
                {match, [StartBin]} -> binary_to_integer(StartBin);
                _ -> undefined
            end
    end.

total_matches(_Count, undefined) -> true;
total_matches(Count, Count) -> true;
total_matches(_Count, _Total) -> false.

resume_meta_path(PartPath) -> PartPath ++ ".meta.json".
final_source_meta_path(DestPath) -> DestPath ++ ".source.json".

prepare_partial_for_url(Url, PartPath) ->
    RequestedUrl = maps:get(original, Url),
    case file:read_file(resume_meta_path(PartPath)) of
        {ok, Bytes} ->
            case metadata_url(Bytes) of
                {ok, RequestedUrl} ->
                    ok;
                {ok, _Other} ->
                    _ = file:delete(PartPath),
                    _ = file:delete(resume_meta_path(PartPath)),
                    ok;
                error ->
                    _ = file:delete(PartPath),
                    _ = file:delete(resume_meta_path(PartPath)),
                    ok
            end;
        {error, enoent} ->
            case filelib:is_regular(PartPath) of
                true ->
                    _ = file:delete(PartPath),
                    ok;
                false ->
                    ok
            end;
        {error, Reason} ->
            {error, {resume_metadata_read_failed, Reason}}
    end.

cached_source_matches(Url, DestPath) ->
    case file:read_file(final_source_meta_path(DestPath)) of
        {ok, Bytes} ->
            case metadata_url(Bytes) of
                {ok, Requested} -> Requested =:= maps:get(original, Url);
                error -> false
            end;
        {error, _} ->
            false
    end.

metadata_url(Bytes) ->
    try jsx:decode(Bytes, [return_maps]) of
        Map when is_map(Map) ->
            case maps:get(<<"url">>, Map, undefined) of
                Url when is_binary(Url), byte_size(Url) > 0 -> {ok, Url};
                _ -> error
            end;
        _ ->
            error
    catch
        _:_ -> error
    end.

write_final_source_metadata(DestPath, Url, Headers, Count) ->
    Meta = ecai_index_job_codec:externalize(#{
        url => maps:get(original, Url),
        etag => header_value(<<"etag">>, Headers),
        last_modified => header_value(<<"last-modified">>, Headers),
        bytes => Count
    }),
    atomic_write(final_source_meta_path(DestPath), jsx:encode(Meta)).

resume_validator(PartPath) ->
    case file:read_file(resume_meta_path(PartPath)) of
        {ok, Bytes} ->
            try jsx:decode(Bytes, [return_maps]) of
                Map when is_map(Map) ->
                    case maps:get(<<"etag">>, Map, null) of
                        Etag when is_binary(Etag), byte_size(Etag) > 0 -> Etag;
                        _ ->
                            case maps:get(<<"last_modified">>, Map, null) of
                                Last when is_binary(Last), byte_size(Last) > 0 -> Last;
                                _ -> undefined
                            end
                    end;
                _ ->
                    undefined
            catch
                _:_ -> undefined
            end;
        {error, _Reason} ->
            undefined
    end.

write_resume_metadata(PartPath, Url, Headers) ->
    Meta = ecai_index_job_codec:externalize(#{
        url => maps:get(original, Url),
        etag => header_value(<<"etag">>, Headers),
        last_modified => header_value(<<"last-modified">>, Headers)
    }),
    atomic_write(resume_meta_path(PartPath), jsx:encode(Meta)).

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

open_connection(Url, Timeout) ->
    Host = binary_to_list(maps:get(host, Url)),
    Port = maps:get(port, Url),
    GunOpts0 = #{protocols => [http2, http]},
    GunOpts =
        case maps:get(transport, Url) of
            tls -> GunOpts0#{transport => tls};
            tcp -> GunOpts0
        end,
    case gun:open(Host, Port, GunOpts) of
        {ok, ConnPid} ->
            case gun:await_up(ConnPid, Timeout) of
                {ok, _Protocol} ->
                    {ok, ConnPid};
                {error, Reason} ->
                    safe_shutdown(ConnPid),
                    {error, {http_connect_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {http_open_failed, Reason}}
    end.

await_response(ConnPid, StreamRef, Timeout) ->
    receive
        {gun_response, ConnPid, StreamRef, Fin, Status, Headers} ->
            {ok, Status, normalize_headers(Headers), Fin};
        {gun_error, ConnPid, StreamRef, Reason} ->
            {error, {http_stream_error, Reason}};
        {gun_down, ConnPid, _Protocol, Reason, _KilledStreams} ->
            {error, {http_connection_down, Reason}};
        {gun_down, ConnPid, _Protocol, Reason, _KilledStreams, _UnprocessedStreams} ->
            {error, {http_connection_down, Reason}}
    after Timeout ->
        {error, http_timeout}
    end.

request_headers(Opts, Extra) ->
    UserAgent = maps:get(user_agent, Opts, default_user_agent()),
    Accept = maps:get(accept, Opts, <<"*/*">>),
    [{<<"user-agent">>, to_binary(UserAgent)}, {<<"accept">>, to_binary(Accept)} | Extra].

response_meta(Url, Status, Headers, Bytes) ->
    #{
        url => maps:get(original, Url),
        status => Status,
        bytes => Bytes,
        etag => header_value(<<"etag">>, Headers),
        last_modified => header_value(<<"last-modified">>, Headers),
        content_type => header_value(<<"content-type">>, Headers),
        content_length => integer_header(<<"content-length">>, Headers),
        content_range => header_value(<<"content-range">>, Headers)
    }.

response_total(206, Headers, _Offset) ->
    range_total(Headers);
response_total(_Status, Headers, Offset) ->
    case integer_header(<<"content-length">>, Headers) of
        undefined -> undefined;
        Length -> Offset + Length
    end.

range_total(Headers) ->
    case header_value(<<"content-range">>, Headers) of
        undefined ->
            undefined;
        Value ->
            case re:run(Value, <<"/([0-9]+)$">>, [{capture, [1], binary}]) of
                {match, [TotalBin]} -> binary_to_integer(TotalBin);
                _ -> undefined
            end
    end.

integer_header(Name, Headers) ->
    case header_value(Name, Headers) of
        undefined ->
            undefined;
        Bin ->
            try binary_to_integer(Bin) of
                Value -> Value
            catch
                error:badarg -> undefined
            end
    end.

header_value(Name0, Headers) ->
    Name = lower_binary(Name0),
    case lists:keyfind(Name, 1, Headers) of
        {Name, Value} -> Value;
        false -> undefined
    end.

normalize_headers(Headers) ->
    [{lower_binary(to_binary(Name)), to_binary(Value)} || {Name, Value} <- Headers].

resolve_location(Url, Location0) ->
    Location = to_binary(Location0),
    Base = maps:get(original, Url),
    try uri_string:resolve(Location, Base) of
        Resolved -> parse_url(Resolved)
    catch
        _Class:_Reason -> {error, {invalid_redirect, Location}}
    end.

is_redirect(301) -> true;
is_redirect(302) -> true;
is_redirect(303) -> true;
is_redirect(307) -> true;
is_redirect(308) -> true;
is_redirect(_) -> false.

-spec safe_progress(progress_fun() | term(), map()) -> ok.
safe_progress(Fun, Progress) when is_function(Fun, 1) ->
    try Fun(Progress) of
        _ -> ok
    catch
        _:_ -> ok
    end;
safe_progress(_Other, _Progress) ->
    ok.

safe_shutdown(ConnPid) ->
    try gun:shutdown(ConnPid) of
        _ -> ok
    catch
        _:_ -> ok
    end.

positive_opt(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        Value when is_integer(Value), Value > 0 -> Value;
        _ -> Default
    end.

file_size_or_zero(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} -> element(2, Info);
        {error, enoent} -> 0;
        {error, _Reason} -> 0
    end.

file_info_result(Url, Path, Source) ->
    #{
        url => maps:get(original, Url),
        path => unicode:characters_to_binary(Path),
        bytes => file_size_or_zero(Path),
        source => Source
    }.

path_list(Bin) when is_binary(Bin) -> unicode:characters_to_list(Bin);
path_list(List) when is_list(List), List =/= [] -> List;
path_list(_Other) -> erlang:error(badarg).

to_binary(Bin) when is_binary(Bin) -> Bin;
to_binary(List) when is_list(List) -> unicode:characters_to_binary(List);
to_binary(Atom) when is_atom(Atom) -> atom_to_binary(Atom, utf8);
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(_Other) -> erlang:error(badarg).

lower_binary(Bin) ->
    unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(Bin))).
