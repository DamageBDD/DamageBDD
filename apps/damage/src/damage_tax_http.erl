%%% Node and delegated tax administrators: private tax records and settings.
%%% Standalone Cowboy handler registered using trails; no public IPFS uploads.
-module(damage_tax_http).

-include_lib("kernel/include/logger.hrl").

-export([init/2, trails/0, authorized/2, parse_scope/1, valid_hash/1]).

trails() ->
    [
      trails:trail("/node/admin/tax", ?MODULE, #{action => page},
                   #{get => #{tags => ["Node Administration"],
                             description => "Private tax reporting dashboard"}}),
      trails:trail("/api/node/tax/settings", ?MODULE, #{action => settings},
                   #{get => #{tags => ["Tax Administration"]},
                     post => #{tags => ["Tax Administration"]}}),
      trails:trail("/api/node/tax/reports", ?MODULE, #{action => reports},
                   #{get => #{tags => ["Node Administration"]}}),
      trails:trail("/api/node/tax/jobs", ?MODULE, #{action => jobs},
                   #{get => #{tags => ["Node Administration"]}}),
      trails:trail("/api/node/tax/backfill", ?MODULE, #{action => backfill},
                   #{post => #{tags => ["Node Administration"]}}),
      trails:trail("/api/node/tax/download/:year/:digest/:format",
                   ?MODULE, #{action => download},
                   #{get => #{tags => ["Node Administration"]}})
    ].

init(Req0, #{action := Action} = Opts) ->
    case authorized(Req0, Opts) of
        {ok, Req} -> {ok, execute(Action, Req), Opts};
        {error, Status, Req} ->
            {ok, reply_json(Status, #{error => <<"permission_denied">>}, Req), Opts}
    end.

%% Always resolve roles from the authenticated request, then recheck the
%% operator-controlled allowlist. Wallet-mode and L402 sessions are forbidden.
%% Client-supplied role/tenant hints cannot grant financial admin privileges.
authorized(Req, Opts) ->
    try
        case damage_auth:authenticate(Req, Opts) of
            {ok, State} ->
                case damage_tax_access:allowed(State) of
                    true -> {ok, Req};
                    false -> {error, 403, Req}
                end;
            {anonymous, _State} -> {error, 401, Req};
            {error, _Reason, _State} -> {error, 401, Req}
        end
    catch _:_ -> {error, 401, Req} end.

execute(page, Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case application:get_env(damage, tax_enabled, false) of
                true ->
                    Html = damage_utils:load_template(
                        "ui/dashboard/tax_admin.mustache", #{}),
                    cowboy_req:reply(200, html_headers(), Html, Req);
                _ -> reply_json(503, #{error => <<"tax_reporting_disabled">>}, Req)
            end;
        _ -> method_not_allowed(Req)
    end;
%% Configuration must remain reachable before the tax service is enabled.
execute(settings, Req) -> settings_action(Req);
execute(Action, Req) ->
    case application:get_env(damage, tax_enabled, false) of
        true -> enabled_action(Action, Req);
        _ -> reply_json(503, #{error => <<"tax_reporting_disabled">>}, Req)
    end.

enabled_action(reports, Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            Tenant = application:get_env(damage, tax_cln_owner, undefined),
            Reply = case Tenant of
                T when is_binary(T), byte_size(T) > 0 ->
                    case damage_tax_catalog:list_reports(T) of
                        {ok, Rows} -> {200, #{reports => Rows}};
                        _ -> {503, #{error => <<"tax_catalog_unavailable">>}}
                    end;
                _ -> {409, #{error => <<"tax_cln_owner_not_configured">>}}
            end,
            {Status, Body} = Reply,
            reply_json(Status, Body, Req);
        _ -> method_not_allowed(Req)
    end;
enabled_action(jobs, Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            case whereis(damage_tax_jobs) of
                undefined -> reply_json(503, #{error => <<"tax_job_service_unavailable">>}, Req);
                _ -> reply_json(200, #{job => damage_tax_jobs:status()}, Req)
            end;
        _ -> method_not_allowed(Req)
    end;
enabled_action(backfill, Req) ->
    case cowboy_req:method(Req) of
        <<"POST">> -> do_backfill(Req);
        _ -> method_not_allowed(Req)
    end;
enabled_action(download, Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> -> do_download(Req);
        _ -> method_not_allowed(Req)
    end.

%% Tax-only settings projection. Never call the general-purpose admin
%% settings endpoint on behalf of a tax administrator.
settings_action(Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> ->
            settings_view(Req);
        <<"POST">> ->
            settings_mutation(Req);
        _ -> method_not_allowed(Req)
    end.

settings_view(Req) ->
    try damage_tax_settings:read_view() of
        {ok, View} -> reply_json(200, View, Req);
        {error, _} -> reply_json(503, #{error => <<"tax_settings_unavailable">>}, Req)
    catch _:_ -> reply_json(503, #{error => <<"tax_settings_unavailable">>}, Req) end.

settings_mutation(Req0) ->
    case post_authorized(Req0) of
        false -> reply_json(403, #{error => <<"request_origin_not_allowed">>}, Req0);
        true ->
            case cowboy_req:read_body(Req0, #{length => 8192, period => 3000,
                                                timeout => 5000}) of
                {ok, Body, Req} ->
                    try jsx:decode(Body, [return_maps]) of
                        Json when is_map(Json), map_size(Json) =< 3 ->
                            settings_change(Json, Req);
                        _ -> reply_json(400, #{error => <<"invalid_tax_settings_request">>}, Req)
                    catch _:_ -> reply_json(400, #{error => <<"invalid_json">>}, Req) end;
                {more, _, Req} -> reply_json(413, #{error => <<"request_too_large">>}, Req);
                {error, _, Req} -> reply_json(400, #{error => <<"invalid_body">>}, Req)
            end
    end.

settings_change(#{<<"action">> := <<"save">>, <<"version">> := Version,
                  <<"changes">> := Changes}, Req) when is_binary(Version) ->
    case damage_tax_settings:authorized_changes(Changes) of
        true -> settings_mutation_result(fun() -> damage_settings:save(damage, Changes, Version) end, Req);
        false -> reply_json(403, #{error => <<"tax_fields_only">>}, Req)
    end;
settings_change(#{<<"action">> := <<"reset">>, <<"version">> := Version,
                  <<"keys">> := Keys}, Req) when is_binary(Version) ->
    case damage_tax_settings:authorized_resets(Keys) of
        true -> settings_mutation_result(fun() -> damage_settings:reset(damage, Keys, Version) end, Req);
        false -> reply_json(403, #{error => <<"tax_fields_only">>}, Req)
    end;
settings_change(_, Req) ->
    reply_json(400, #{error => <<"invalid_tax_settings_request">>}, Req).

settings_mutation_result(Fun, Req) ->
    try Fun() of
        {ok, _Status} -> settings_view(Req);
        {error, {conflict, _Version}} ->
            reply_json(409, #{error => <<"config_changed_reload_required">>}, Req);
        {error, {invalid_value, Name, _Reason}} ->
            reply_json(422, #{error => <<"invalid_tax_value">>, field => Name}, Req);
        {error, {invalid_setting_combination, _, _, _}} ->
            reply_json(422, #{error => <<"tax_owner_required_when_enabled">>}, Req);
        {error, {not_editable, _Name}} ->
            reply_json(403, #{error => <<"tax_fields_only">>}, Req);
        {error, _Reason} ->
            reply_json(422, #{error => <<"tax_settings_save_rejected">>}, Req)
    catch _:_ -> reply_json(503, #{error => <<"tax_settings_unavailable">>}, Req) end.

do_backfill(Req0) ->
    case post_authorized(Req0) of
        false -> reply_json(403, #{error => <<"request_origin_not_allowed">>}, Req0);
        true ->
            case cowboy_req:read_body(Req0, #{length => 16384, period => 3000}) of
                {ok, Bytes, Req} ->
                    case parse_scope(Bytes) of
                        {ok, Scope} ->
                            case damage_tax_jobs:backfill(Scope) of
                                {ok, started} ->
                                    reply_json(202, #{status => <<"started">>}, Req);
                                {error, backfill_running} ->
                                    reply_json(409, #{error => <<"backfill_running">>}, Req);
                                {error, _} ->
                                    reply_json(409, #{error => <<"backfill_not_available">>}, Req)
                            end;
                        {error, _} ->
                            reply_json(400, #{error => <<"invalid_backfill_request">>}, Req)
                    end;
                {more, _, Req} ->
                    reply_json(413, #{error => <<"request_too_large">>}, Req);
                {error, _, Req} ->
                    reply_json(400, #{error => <<"invalid_request_body">>}, Req)
            end
    end.

%% Non-simple JSON requests with a private opt-in header prevent browser forms
%% and cross-origin simple requests from submitting a backfill via cookies.
post_authorized(Req) ->
    Header = cowboy_req:header(<<"x-damage-tax-request">>, Req),
    Type = cowboy_req:header(<<"content-type">>, Req, <<>>),
    Site = cowboy_req:header(<<"sec-fetch-site">>, Req, <<"same-origin">>),
    Header =:= <<"1">> andalso
    binary:match(Type, <<"application/json">>) =:= {0, 16} andalso
    (Site =:= <<"same-origin">> orelse Site =:= <<"none">>) andalso
    origin_matches_host(Req).

origin_matches_host(Req) ->
    case cowboy_req:header(<<"origin">>, Req, undefined) of
        undefined -> true;
        <<"null">> -> false;
        Origin ->
            try
                #{host := OriginHost} = uri_string:parse(Origin),
                to_bin(OriginHost) =:= cowboy_req:host(Req)
            catch _:_ -> false end
    end.
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).

parse_scope(Bytes) when is_binary(Bytes), byte_size(Bytes) =< 16384 ->
    try
        Body = jsx:decode(Bytes, [return_maps]),
        case Body of
            #{<<"source">> := <<"journal">>, <<"scope">> := <<"all">>} ->
                {ok, {existing, all}};
            #{<<"source">> := <<"journal">>, <<"year">> := Year}
                when is_integer(Year), Year >= 2009, Year =< 2200 ->
                {ok, {existing, Year}};
            #{<<"scope">> := <<"all">>} -> {ok, all};
            #{<<"year">> := Year} when is_integer(Year), Year >= 2009, Year =< 2200 ->
                {ok, Year};
            _ -> {error, invalid_scope}
        end
    catch _:_ -> {error, invalid_json} end;
parse_scope(_) -> {error, invalid_json}.

do_download(Req) ->
    YearBin = cowboy_req:binding(year, Req, <<>>),
    Digest = cowboy_req:binding(digest, Req, <<>>),
    FmtBin = cowboy_req:binding(format, Req, <<>>),
    case {year(YearBin), valid_hash(Digest), format(FmtBin)} of
        {{ok, Year}, true, {ok, Fmt}} ->
            Tenant = application:get_env(damage, tax_cln_owner, undefined),
            case damage_tax_catalog:download(Tenant, Year, Digest, Fmt) of
                {ok, Bytes, ContentType, Filename} ->
                    Attachment = <<"attachment; filename=\"FY", YearBin/binary,
                                   "-", Filename/binary, "\"">>,
                    H = maps:merge(private_headers(),
                        #{<<"content-type">> => ContentType,
                          <<"content-disposition">> => Attachment}),
                    cowboy_req:reply(200, H, Bytes, Req);
                {error, _} -> reply_json(404, #{error => <<"report_not_found">>}, Req)
            end;
        _ -> reply_json(400, #{error => <<"invalid_download_identifier">>}, Req)
    end.

year(B) when is_binary(B), byte_size(B) =:= 4 ->
    try
        N = binary_to_integer(B),
        case N >= 2009 andalso N =< 2200 of
            true -> {ok, N};
            false -> error
        end
    catch _:_ -> error end;
year(_) -> error.

format(<<"json">>) -> {ok, json};
format(<<"csv">>) -> {ok, csv};
format(<<"sha256">>) -> {ok, sha256};
format(_) -> error.

valid_hash(B) when is_binary(B), byte_size(B) =:= 64 ->
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                        (C >= $a andalso C =< $f) end, binary:bin_to_list(B));
valid_hash(_) -> false.

method_not_allowed(Req) ->
    cowboy_req:reply(405, maps:merge(private_headers(),
        #{<<"allow">> => <<"GET, POST">>}), <<>>, Req).
reply_json(Code, Data, Req) ->
    cowboy_req:reply(Code, maps:merge(private_headers(),
        #{<<"content-type">> => <<"application/json; charset=utf-8">>}),
        jsx:encode(Data), Req).
private_headers() ->
    #{<<"cache-control">> => <<"no-store, private">>,
      <<"pragma">> => <<"no-cache">>,
      <<"x-content-type-options">> => <<"nosniff">>,
      <<"referrer-policy">> => <<"no-referrer">>,
      <<"x-frame-options">> => <<"DENY">>}.
html_headers() ->
    maps:merge(private_headers(),
      #{<<"content-type">> => <<"text/html; charset=utf-8">>,
        <<"content-security-policy">> =>
        <<"default-src 'none'; script-src 'self'; style-src 'self'; "
          "connect-src 'self'; img-src 'self'; base-uri 'none'; "
          "form-action 'self'; frame-ancestors 'none'">>}).
