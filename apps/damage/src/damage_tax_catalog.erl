%%% Private, immutable tax report and historical quote catalog.

%%% Identifiers used as path components are derived or strictly validated.
-module(damage_tax_catalog).

-include_lib("kernel/include/file.hrl").

-export([root/0, save_report/2, list_reports/1, download/4,
         save_quote/2, load_quote/1]).

-define(MAX_REPORT_BYTES, 67108864).

root() ->
    Data = application:get_env(damage, tax_data_dir, "/var/lib/damage/tax"),
    filename:join(filename:absname(as_list(Data)), "reports").

-spec save_report(binary(), map()) -> {ok, map()} | {error, term()}.
save_report(Tenant, #{<<"manifest">> := Manifest,
                       <<"manifest_sha256">> := Digest} = Report)
        when is_binary(Tenant), byte_size(Tenant) > 0 ->
    Year = maps:get(<<"tax_year_end">>, Manifest, undefined),
    Entries = maps:get(<<"entries">>, Manifest, undefined),
    case valid_year(Year) andalso valid_digest(Digest) andalso
         is_list(Entries) andalso Entries =/= [] andalso
         damage_tax_canonical:commitment(Manifest) =:= Digest of
        false -> {error, invalid_report_manifest};
        true ->
            Dir = report_dir(Tenant, Year, Digest),
            case ensure_private_dir(Dir) of
                ok ->
                    Path = filename:join(Dir, "report.json"),
                    Bytes = damage_tax_canonical:encode(Report),
                    case write_once(Path, Bytes) of
                        ok ->
                            {ok, metadata(Report)};
                        {error, eexist} ->
                            %% Idempotent re-generation of exactly the same report.
                            case load_report(Tenant, Year, Digest) of
                                {ok, Existing} -> {ok, metadata(Existing)};
                                _ -> {error, existing_report_invalid}
                            end;
                        Error -> Error
                    end;
                Error -> Error
            end
    end;
save_report(_, _) -> {error, invalid_report}.

-spec list_reports(binary()) -> {ok, [map()]} | {error, term()}.
list_reports(Tenant) when is_binary(Tenant), byte_size(Tenant) > 0 ->
    Pattern = filename:join([tenant_dir(Tenant), "FY*", "*", "report.json"]),
    Paths = filelib:wildcard(Pattern),
    Rows = [Meta || Path <- Paths, {ok, Meta} <- [indexed_report(Tenant, Path)]],
    {ok, lists:sort(fun(A, B) ->
        {maps:get(<<"tax_year_end">>, A), maps:get(<<"generated_at">>, A),
         maps:get(<<"manifest_sha256">>, A)} >=
        {maps:get(<<"tax_year_end">>, B), maps:get(<<"generated_at">>, B),
         maps:get(<<"manifest_sha256">>, B)}
    end, Rows)};
list_reports(_) -> {error, invalid_tenant}.

-spec download(binary(), integer(), binary(), atom()) ->
    {ok, binary(), binary(), binary()} | {error, term()}.
download(Tenant, Year, Digest, Format) when is_binary(Tenant),
                                          is_integer(Year), is_binary(Digest) ->
    case load_report(Tenant, Year, Digest) of
        {ok, Report} ->
            Manifest = maps:get(<<"manifest">>, Report),
            case Format of
                json -> {ok, damage_tax_canonical:encode(Manifest),
                         <<"application/json; charset=utf-8">>, <<"tax-manifest.json">>};
                csv -> {ok, damage_tax_report:to_csv(Report),
                        <<"text/csv; charset=utf-8">>, <<"tax-transactions.csv">>};
                sha256 -> {ok, <<Digest/binary, "  tax-manifest.json\n">>,
                           <<"text/plain; charset=utf-8">>, <<"tax-manifest.sha256">>};
                _ -> {error, unsupported_report_format}
            end;
        Error -> Error
    end;
download(_, _, _, _) -> {error, invalid_report_identifier}.

%% Persist an exact price quote only after the raw HTTP witness is in the tax
%% evidence store. No keys or bearer headers appear in either file.
-spec save_quote({binary(), integer()}, map()) -> ok | {error, term()}.
save_quote({Asset, _Hour} = Key, Quote) when is_map(Quote) ->
    Sha = maps:get(<<"archive_sha256">>, Quote, <<>>),
    case valid_quote_key(Key) andalso valid_digest(Sha) andalso
         Sha =:= maps:get(<<"body_sha256">>, Quote, undefined) andalso
         maps:get(<<"asset">>, Quote, undefined) =:= Asset andalso
         lists:member(maps:get(<<"method">>, Quote, undefined),
                      [<<"hour_open">>, <<"daily_historical_snapshot">>]) andalso
         damage_tax_store:evidence_exists(Sha) of
        false -> {error, unverified_price_evidence};
        true ->
            %% Quote key is always the event hour, even if a daily fallback
            %% records a midnight quote timestamp.
            Path = quote_path(Key),
            case ensure_private_dir(filename:dirname(Path)) of
                ok ->
                    case write_once(Path, damage_tax_canonical:encode(Quote)) of
                        ok -> ok;
                        {error, eexist} ->
                            case load_quote(Key) of
                                {ok, Quote} -> ok;
                                {ok, _Different} -> {error, price_quote_revision_conflict};
                                _ -> {error, existing_quote_invalid}
                            end;
                        Err -> Err
                    end;
                Error -> Error
            end
    end;
save_quote(_, _) -> {error, invalid_price_quote}.

-spec load_quote({binary(), integer()}) -> {ok, map()} | not_found | {error, term()}.
load_quote(Key) ->
    case valid_quote_key(Key) of
        false -> {error, invalid_price_key};
        true ->
            case safe_read(quote_path(Key)) of
                {ok, Bytes} ->
                    try
                        Q = jsx:decode(Bytes, [return_maps]),
                        Sha = maps:get(<<"archive_sha256">>, Q),
                        true = valid_digest(Sha) andalso
                               Sha =:= maps:get(<<"body_sha256">>, Q) andalso
                               damage_tax_store:evidence_exists(Sha),
                        {Asset, _Hour} = Key,
                        true = maps:get(<<"asset">>, Q) =:= Asset,
                        {ok, Q}
                    catch _:_ -> {error, price_cache_corrupt} end;
                {error, enoent} -> not_found;
                Error -> Error
            end
    end.

indexed_report(Tenant, Path) ->
    Digest = unicode:characters_to_binary(filename:basename(filename:dirname(Path))),
    YearDir = filename:basename(filename:dirname(filename:dirname(Path))),
    case YearDir of
        "FY" ++ YearString ->
            case string:to_integer(YearString) of
                {Year, ""} ->
                    case load_report(Tenant, Year, Digest) of
                        {ok, Report} -> {ok, metadata(Report)};
                        _ -> {error, corrupt_report}
                    end;
                _ -> {error, invalid_year}
            end;
        _ -> {error, invalid_report_dir}
    end.

load_report(Tenant, Year, Digest) ->
    case valid_year(Year) andalso valid_digest(Digest) andalso
         is_binary(Tenant) andalso byte_size(Tenant) > 0 of
        false -> {error, invalid_report_identifier};
        true ->
            Path = filename:join(report_dir(Tenant, Year, Digest), "report.json"),
            case safe_read(Path) of
                {ok, Bytes} ->
                    try
                        Report = jsx:decode(Bytes, [return_maps]),
                        Manifest = maps:get(<<"manifest">>, Report),
                        Digest = maps:get(<<"manifest_sha256">>, Report),
                        Digest = damage_tax_canonical:commitment(Manifest),
                        Year = maps:get(<<"tax_year_end">>, Manifest),
                        [_ | _] = maps:get(<<"entries">>, Manifest),
                        Review = maps:get(<<"review_required">>, Manifest),
                        true = is_list(Review),
                        true = (maps:get(<<"attestable">>, Report, false) =:=
                                (Review =:= [])),
                        true = (maps:get(<<"evidence_set_sha256">>, Manifest) =:=
                                maps:get(<<"evidence_set_sha256">>, Report)),
                        {ok, Report}
                    catch _:_ -> {error, invalid_report_integrity} end;
                Error -> Error
            end
    end.

metadata(Report) ->
    Manifest = maps:get(<<"manifest">>, Report),
    Summary = maps:get(<<"summary">>, Manifest),
    NeedsReview = length(maps:get(<<"review_required">>, Manifest, [])),
    #{<<"tax_year_end">> => maps:get(<<"tax_year_end">>, Manifest),
      <<"manifest_sha256">> => maps:get(<<"manifest_sha256">>, Report),
      <<"evidence_set_sha256">> => maps:get(<<"evidence_set_sha256">>, Report),
      <<"generated_at">> => maps:get(<<"generated_at">>, Report, 0),
      <<"attestable">> => maps:get(<<"attestable">>, Report, false),
      <<"review_count">> => NeedsReview,
      <<"summary">> => Summary}.

report_dir(Tenant, Year, Digest) ->
    filename:join([tenant_dir(Tenant), "FY" ++ integer_to_list(Year),
                   binary_to_list(Digest)]).
tenant_dir(Tenant) ->
    filename:join(root(), binary_to_list(damage_tax_canonical:sha256_hex(Tenant))).
quote_path({Asset, Hour}) ->
    filename:join([root(), "quotes", binary_to_list(Asset) ++ "-" ++
                   integer_to_list(Hour) ++ ".json"]).

valid_quote_key({Asset, Hour}) ->
    lists:member(Asset, [<<"BTC">>, <<"ETH">>, <<"AE">>]) andalso
    is_integer(Hour) andalso Hour > 0 andalso Hour rem 3600 =:= 0;
valid_quote_key(_) -> false.

valid_year(Y) -> is_integer(Y) andalso Y >= 2009 andalso Y =< 2200.
valid_digest(B) when is_binary(B), byte_size(B) =:= 64 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                        (C >= $a andalso C =< $f) end, binary:bin_to_list(B));
valid_digest(_) -> false.

as_list(B) when is_binary(B) -> binary_to_list(B);
as_list(L) when is_list(L) -> L.

ensure_private_dir(Dir) ->
    case filelib:ensure_dir(filename:join(Dir, ".ready")) of
        ok -> secure_parents(Dir);
        Error -> Error
    end.

%% Restrict the configured tax directory tree; do not descend through symlinks.
secure_parents(Dir) ->
    Data = filename:absname(as_list(application:get_env(
        damage, tax_data_dir, "/var/lib/damage/tax"))),
    Root = root(),
    case verify_dir(Data) of
        ok ->
            case verify_dir(Root) of
                ok -> secure_tail(Root, Dir);
                Error -> Error
            end;
        Error -> Error
    end.
secure_tail(Root, Dir) ->
    Tail = filename:split(filename:absname(Dir)),
    Prefix = filename:split(filename:absname(Root)),
    case lists:prefix(Prefix, Tail) of
        false -> {error, tax_path_outside_root};
        true -> secure_path(Root, lists:nthtail(length(Prefix), Tail))
    end.
secure_path(_, []) -> ok;
secure_path(Base, [Part | Rest]) ->
    Path = filename:join(Base, Part),
    case verify_dir(Path) of
        ok -> secure_path(Path, Rest);
        Error -> Error
    end.
verify_dir(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> file:change_mode(Path, 8#700);
        {ok, _} -> {error, unsafe_tax_directory};
        Error -> Error
    end.

safe_read(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = regular, size = Size}} when Size =< ?MAX_REPORT_BYTES ->
            file:read_file(Path);
        {ok, _} -> {error, unsafe_or_oversized_tax_file};
        Error -> Error
    end.

write_once(Path, Bytes) when is_binary(Bytes), byte_size(Bytes) =< ?MAX_REPORT_BYTES ->
    case file:open(Path, [write, exclusive, binary]) of
        {ok, Io} ->
            Permission = file:change_mode(Path, 8#600),
            Result = case Permission of
                ok -> case file:write(Io, Bytes) of
                    ok -> file:sync(Io);
                    Error -> Error
                end;
                Error -> Error
            end,
            Closed = file:close(Io),
            case {Result, Closed} of
                {ok, ok} -> ok;
                {Error0, _} when Error0 =/= ok -> {error, {report_write_failed, Error0}};
                {_, Error0} -> {error, {report_close_failed, Error0}}
            end;
        Error -> Error
    end;
write_once(_, _) -> {error, report_too_large}.
