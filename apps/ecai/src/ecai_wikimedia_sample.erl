%%--------------------------------------------------------------------
%% ECAI API-backed Wikimedia sample corpus.
%%
%% The managed fixture server remains responsible for discovering and hashing
%% the bundled immutable fixture files. This module republishes only those
%% exact discovered files through the main ECAI HTTP API and rewrites the
%% generated fixture catalog so indexing jobs fetch from the ECAI API rather
%% than from the fixture server's private listener.
%%--------------------------------------------------------------------
-module(ecai_wikimedia_sample).

-export([
    ensure_started/0,
    catalog/0,
    status/0,
    file_entry/1,
    api_base_url/0,
    source_base_url/0,
    source_url_allowed/1
]).

-include_lib("kernel/include/file.hrl").

-define(API_PREFIX, <<"/ecai/wikimedia/sample">>).
-define(SOURCE_PREFIX, <<"/ecai/wikimedia/sample/files/">>).
-define(API_CATALOG_NAME, "wikimedia-api-catalog.json").

-spec ensure_started() -> ok | {error, term()}.
ensure_started() ->
    case whereis(ecai_wikimedia_fixture_server) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            case whereis(ecai_sup) of
                undefined ->
                    {error, wikimedia_fixture_supervisor_not_running};
                _ ->
                    %% The API is the public sample transport. Keep the legacy
                    %% fixture listener ephemeral so it cannot collide with a
                    %% fixed development port and is never embedded in jobs.
                    ecai_wikimedia_fixture_server:start_supervised(
                        ecai_sup,
                        #{port => 0}
                    )
            end
    end.

-spec catalog() -> {ok, binary(), map()} | {error, term()}.
catalog() ->
    case ensure_started() of
        ok -> build_api_catalog();
        {error, _Reason} = Error -> Error
    end.

-spec status() -> {ok, map()} | {error, term()}.
status() ->
    case ensure_started() of
        ok ->
            case ecai_wikimedia_fixture_server:status() of
                Status when is_map(Status) ->
                    {ok, Status#{
                        transport => ecai_api,
                        api_base_url => api_base_url(),
                        source_base_url => source_base_url()
                    }};
                {error, _Reason} = Error ->
                    Error;
                Other ->
                    {error, {invalid_fixture_status, Other}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

-spec file_entry(binary() | list()) -> {ok, map()} | {error, term()}.
file_entry(Name0) ->
    Name = to_binary(Name0),
    case status() of
        {ok, Status} ->
            Files = maps:get(files, Status, []),
            case find_file(Name, Files) of
                {ok, Public} ->
                    FixtureDir = binary_to_list(maps:get(fixture_dir, Status)),
                    Path = filename:join(FixtureDir, binary_to_list(Name)),
                    case file:read_file_info(Path) of
                        {ok, #file_info{type = regular, size = Size}} ->
                            case Size =:= maps:get(size, Public) of
                                true ->
                                    {ok, Public#{
                                        path => Path,
                                        content_type =>
                                            ecai_wikimedia_fixture_handler:content_type(Name)
                                    }};
                                false ->
                                    {error, {fixture_file_size_changed, Name}}
                            end;
                        {ok, #file_info{type = Type}} ->
                            {error, {fixture_file_not_regular, Name, Type}};
                        {error, Reason} ->
                            {error, {fixture_file_unavailable, Name, Reason}}
                    end;
                error ->
                    {error, {unknown_wikimedia_sample_file, Name}}
            end;
        {error, _Reason} = Error ->
            Error
    end.

-spec api_base_url() -> binary().
api_base_url() ->
    Host = api_host(),
    Port = api_port(),
    <<"http://", (format_host(Host))/binary, ":", (integer_to_binary(Port))/binary,
        ?API_PREFIX/binary>>.

-spec source_base_url() -> binary().
source_base_url() ->
    <<(api_base_url())/binary, "/files">>.

%% Exact allow rule used by ecai_wikimedia_catalog. This deliberately does not
%% allow arbitrary loopback HTTP: only this ECAI listener, port and path.
-spec source_url_allowed(map()) -> boolean().
source_url_allowed(Parsed) when is_map(Parsed) ->
    Scheme = maps:get(scheme, Parsed, <<>>),
    Host = maps:get(host, Parsed, <<>>),
    Port = maps:get(port, Parsed, default_port(Scheme)),
    Path = maps:get(path, Parsed, <<>>),
    Scheme =:= <<"http">> andalso
        Host =:= api_host() andalso
        Port =:= api_port() andalso
        has_prefix(Path, ?SOURCE_PREFIX);
source_url_allowed(_Parsed) ->
    false.

build_api_catalog() ->
    case ecai_wikimedia_fixture_server:catalog_path() of
        {ok, RawPath} ->
            case file:read_file(binary_to_list(RawPath)) of
                {ok, Bytes} ->
                    rewrite_and_store_catalog(Bytes);
                {error, Reason} ->
                    {error, {wikimedia_fixture_catalog_read_failed, RawPath, Reason}}
            end;
        {error, Reason} ->
            {error, {wikimedia_fixture_catalog_unavailable, Reason}}
    end.

rewrite_and_store_catalog(Bytes) ->
    try jsx:decode(Bytes, [return_maps]) of
        Raw when is_map(Raw) ->
            Base = source_base_url(),
            Rewritten = Raw#{
                <<"content_shards">> => rewrite_sources(
                    maps:get(<<"content_shards">>, Raw, []),
                    Base
                ),
                <<"pageview_sources">> => rewrite_sources(
                    maps:get(<<"pageview_sources">>, Raw, []),
                    Base
                )
            },
            write_and_validate_catalog(Rewritten);
        _ ->
            {error, wikimedia_fixture_catalog_not_map}
    catch
        error:Reason ->
            {error, {wikimedia_fixture_catalog_invalid_json, Reason}}
    end.

rewrite_sources(Sources, Base) when is_list(Sources) ->
    [
        Source#{
            <<"url">> => <<Base/binary, "/", (maps:get(<<"name">>, Source))/binary>>
        }
     || Source <- Sources
    ].

write_and_validate_catalog(Catalog) ->
    case ecai_wikimedia_fixture_server:status() of
        Status when is_map(Status) ->
            RuntimeDir = binary_to_list(maps:get(runtime_dir, Status)),
            Path = filename:join(RuntimeDir, ?API_CATALOG_NAME),
            Bytes = <<(jsx:encode(Catalog))/binary, "\n">>,
            case atomic_write(Path, Bytes) of
                ok ->
                    PathBin = unicode:characters_to_binary(Path),
                    case ecai_wikimedia_catalog:read(PathBin) of
                        {ok, Normalized} -> {ok, PathBin, Normalized};
                        {error, Reason} -> {error, {wikimedia_api_catalog_invalid, Reason}}
                    end;
                {error, Reason} ->
                    {error, {wikimedia_api_catalog_write_failed, Path, Reason}}
            end;
        {error, _Reason} = Error ->
            Error;
        Other ->
            {error, {invalid_fixture_status, Other}}
    end.

atomic_write(Path, Bytes) ->
    case filelib:ensure_dir(Path) of
        ok ->
            Suffix = integer_to_list(erlang:unique_integer([positive, monotonic])),
            Tmp = Path ++ "." ++ Suffix ++ ".tmp",
            try
                case file:write_file(Tmp, Bytes, [raw, binary, exclusive]) of
                    ok -> file:rename(Tmp, Path);
                    {error, _Reason} = Error -> Error
                end
            after
                _ = file:delete(Tmp)
            end;
        {error, _Reason} = Error -> Error
    end.

find_file(Name, [#{name := Name} = File | _]) -> {ok, File};
find_file(Name, [_ | Rest]) -> find_file(Name, Rest);
find_file(_Name, []) -> error.

api_host() ->
    to_binary(
        application:get_env(
            ecai,
            wikimedia_sample_api_host,
            default_api_host()
        )
    ).

default_api_host() ->
    case application:get_env(ecai, ip, {127, 0, 0, 1}) of
        {0, 0, 0, 0} -> <<"127.0.0.1">>;
        {0, 0, 0, 0, 0, 0, 0, 0} -> <<"::1">>;
        Ip when is_tuple(Ip) -> unicode:characters_to_binary(inet:ntoa(Ip));
        _ -> <<"127.0.0.1">>
    end.

api_port() ->
    application:get_env(ecai, port, 9003).

default_port(<<"http">>) -> 80;
default_port(<<"https">>) -> 443;
default_port(_) -> undefined.

has_prefix(Value, Prefix) when is_binary(Value), is_binary(Prefix) ->
    byte_size(Value) >= byte_size(Prefix) andalso
        binary:part(Value, 0, byte_size(Prefix)) =:= Prefix;
has_prefix(_Value, _Prefix) ->
    false.

format_host(Host) ->
    case binary:match(Host, <<":">>) of
        nomatch -> Host;
        _ -> <<"[", Host/binary, "]">>
    end.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).
