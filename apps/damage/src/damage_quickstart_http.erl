%% Copyright (c) DamageBDD. Licensed under Apache-2.0.
%% Small opt-in onboarding HTTP surface. Never calls the paid runner without auth.
-module(damage_quickstart_http).

-export([init/2]).

-define(REQUEST_TIMEOUT, 5000).
-define(BODY_LIMIT, 4096).

init(Req, Opts) ->
    Action = maps:get(action, Opts, undefined),
    Method = cowboy_req:method(Req),
    Req1 =
        case application:get_env(damage, quickstart_enabled, false) of
            true -> dispatch(Action, Method, Req);
            _ -> json_reply(503, #{error => <<"quickstart_disabled">>}, Req)
        end,
    {ok, Req1, Opts}.

dispatch(generate, <<"POST">>, Req) ->
    with_json(Req, fun(Body, Req1) ->
        case damage_quickstart:generate(maps:get(<<"url">>, Body, undefined)) of
            {ok, Generated} ->
                %% Pure proposal generation stays available without a trial grant.
                case trial_possible(Generated) of
                    false ->
                        json_reply(
                            200,
                            Generated#{
                                mode => <<"proposal">>,
                                trial_available => false
                            },
                            Req1
                        );
                    true ->
                        case peer_key(Req1) of
                            {ok, PeerHash} ->
                                case damage_quickstart_store:issue_session(PeerHash) of
                                    {ok, Session} ->
                                        Secure = application:get_env(
                                            damage,
                                            quickstart_cookie_secure,
                                            true
                                        ),
                                        Req2 = cowboy_req:set_resp_cookie(
                                            <<"quickstart_sid">>,
                                            Session,
                                            Req1,
                                            #{
                                                path => <<"/">>,
                                                max_age => 86400,
                                                http_only => true,
                                                same_site => lax,
                                                secure => Secure
                                            }
                                        ),
                                        json_reply(
                                            200,
                                            Generated#{
                                                mode => <<"proposal">>,
                                                trial_available => true
                                            },
                                            Req2
                                        );
                                    {error, Why} ->
                                        json_reply(429, #{error => Why}, Req1)
                                end;
                            {error, _} ->
                                json_reply(
                                    200,
                                    Generated#{
                                        mode => <<"proposal">>,
                                        trial_available => false
                                    },
                                    Req1
                                )
                        end
                end;
            {error, Reason} ->
                json_reply(422, #{error => Reason}, Req1)
        end
    end);
dispatch(run, <<"POST">>, Req) ->
    with_json(Req, fun(Body, Req1) ->
        case damage_quickstart:generate(maps:get(<<"url">>, Body, undefined)) of
            {error, Why} ->
                json_reply(422, #{error => Why}, Req1);
            {ok, Generated} ->
                case run_preflight(Generated, Req1) of
                    {ok, Session, PeerHash} ->
                        case damage_quickstart_store:reserve(Session, PeerHash) of
                            {ok, Lease} ->
                                Reply =
                                    try
                                        execute_trial(Generated)
                                    catch
                                        _:_ ->
                                            #{
                                                passed => false,
                                                error => <<"trial_execution_failed">>
                                            }
                                    after
                                        damage_quickstart_store:release(Lease)
                                    end,
                                Report = report_data(Generated, Reply),
                                case damage_quickstart_store:store_report(Report) of
                                    {ok, Id} ->
                                        Url = <<"/try/report/", Id/binary>>,
                                        json_reply(200, Report#{report_url => Url}, Req1);
                                    _ ->
                                        json_reply(
                                            503,
                                            #{error => <<"report_persistence_failed">>},
                                            Req1
                                        )
                                end;
                            {error, Why} ->
                                Status =
                                    case Why of
                                        busy -> 503;
                                        rate_limited -> 429;
                                        _ -> 403
                                    end,
                                json_reply(Status, #{error => Why}, Req1)
                        end;
                    {error, Why} ->
                        json_reply(403, #{error => Why}, Req1)
                end
        end
    end);
dispatch(report, <<"GET">>, Req) ->
    Id = cowboy_req:binding(id, Req, <<>>),
    case valid_report_id(Id) of
        false ->
            html_reply(404, <<"Report not found">>, Req);
        true ->
            case damage_quickstart_store:get_report(Id) of
                {ok, Report} -> html_reply(200, report_html(Report), Req);
                _ -> html_reply(404, <<"Report expired or not found">>, Req)
            end
    end;
dispatch(_, _, Req) ->
    cowboy_req:reply(405, #{<<"allow">> => <<"GET, POST">>}, <<>>, Req).

with_json(Req, Callback) ->
    ContentType = cowboy_req:header(<<"content-type">>, Req, <<>>),
    case binary:match(ContentType, <<"application/json">>) of
        {0, _} ->
            case cowboy_req:read_body(Req, #{length => ?BODY_LIMIT, period => 5000}) of
                {ok, Data, Req1} when byte_size(Data) =< ?BODY_LIMIT ->
                    try jsx:decode(Data, [return_maps]) of
                        Body when is_map(Body) -> Callback(Body, Req1);
                        _ -> json_reply(400, #{error => <<"object_required">>}, Req1)
                    catch
                        _:_ -> json_reply(400, #{error => <<"invalid_json">>}, Req1)
                    end;
                {more, _, Req1} ->
                    json_reply(413, #{error => <<"body_too_large">>}, Req1);
                _ ->
                    json_reply(400, #{error => <<"invalid_body">>}, Req)
            end;
        _ ->
            json_reply(415, #{error => <<"json_content_type_required">>}, Req)
    end.

trial_possible(Generated) ->
    application:get_env(damage, quickstart_trial_enabled, false) =:= true andalso
        damage_quickstart:trial_target_allowed(Generated).

run_preflight(Generated, Req) ->
    case trial_possible(Generated) of
        false ->
            {error, target_not_approved_for_free_run};
        true ->
            Cookie = cowboy_req:parse_cookies(Req),
            Session = proplists:get_value(<<"quickstart_sid">>, Cookie, <<>>),
            case peer_key(Req) of
                {ok, PeerHash} -> {ok, Session, PeerHash};
                Error -> Error
            end
    end.

peer_key(Req) ->
    case application:get_env(damage, quickstart_quota_secret) of
        {ok, Secret} when is_binary(Secret), byte_size(Secret) >= 32 ->
            {PeerIp, _Port} = cowboy_req:peer(Req),
            {ok,
                lowercase_hex(
                    crypto:mac(
                        hmac,
                        sha256,
                        Secret,
                        term_to_binary(PeerIp)
                    )
                )};
        _ ->
            {error, quota_secret_not_configured}
    end.

%% Free verification observes only HTTP status. It never follows redirects,
%% sends credentials, accepts a body or downloads a response body.
%% Connect to a vetted IP directly, with original hostname for SNI and Host.
execute_trial(#{host := Host, path := Path}) ->
    Started = erlang:monotonic_time(millisecond),
    Result = resolve_and_get(Host, Path),
    Duration = erlang:monotonic_time(millisecond) - Started,
    case Result of
        {ok, Status} ->
            #{
                passed => Status =:= 200,
                observed_status => Status,
                elapsed_ms => Duration
            };
        {error, Reason} ->
            #{passed => false, error => Reason, elapsed_ms => Duration}
    end.

resolve_and_get(Host, Path) ->
    case inet:getaddrs(binary_to_list(Host), inet) of
        {ok, Addresses} when Addresses =/= [] ->
            case lists:all(fun damage_quickstart:public_ipv4/1, Addresses) of
                true -> request_pinned(hd(Addresses), Host, Path);
                false -> {error, non_public_dns_result}
            end;
        _ ->
            {error, host_resolution_failed}
    end.

request_pinned(IP, Host, Path) ->
    IPString = inet:ntoa(IP),
    Opts = #{
        transport => tls,
        protocols => [http],
        connect_timeout => ?REQUEST_TIMEOUT,
        tls_opts => damage_gun:tls_opts(Host)
    },
    case gun:open(IPString, 443, Opts) of
        {ok, ConnPid} ->
            try
                case gun:await_up(ConnPid, ?REQUEST_TIMEOUT) of
                    {ok, http} ->
                        Ref = gun:get(
                            ConnPid,
                            Path,
                            [
                                {<<"host">>, Host},
                                {<<"user-agent">>, <<"DamageBDD-quickstart/1.0">>},
                                {<<"accept">>, <<"*/*">>}
                            ]
                        ),
                        case gun:await(ConnPid, Ref, ?REQUEST_TIMEOUT) of
                            {response, _, Status, _Headers} when is_integer(Status) ->
                                _ = gun:cancel(ConnPid, Ref),
                                {ok, Status};
                            _ ->
                                {error, request_failed}
                        end;
                    _ ->
                        {error, tls_connection_failed}
                end
            after
                gun:close(ConnPid)
            end;
        _ ->
            {error, connection_failed}
    end.

report_data(Generated, Result) ->
    maps:merge(maps:with([url, feature, expected_status], Generated), Result).

valid_report_id(Id) when is_binary(Id), byte_size(Id) =:= 48 ->
    re:run(Id, <<"^[0-9a-f]{48}$">>, [{capture, none}]) =:= match;
valid_report_id(_) ->
    false.

report_html(R) ->
    Status =
        case maps:get(passed, R, false) of
            true -> <<"PASS">>;
            false -> <<"FAIL">>
        end,
    Description =
        case maps:find(observed_status, R) of
            {ok, Code} -> integer_to_binary(Code);
            error -> as_binary(maps:get(error, R, <<"request_failed">>))
        end,
    iolist_to_binary([
        <<"<!doctype html><html lang='en'><meta charset='utf-8'>">>,
        <<"<meta name='viewport' content='width=device-width,initial-scale=1'>">>,
        <<"<title>DamageBDD verification report</title>">>,
        <<"<style>body{font:16px system-ui;max-width:760px;margin:6vh auto;">>,
        <<"padding:1rem;color:#172132}pre{white-space:pre-wrap;overflow-wrap:anywhere;">>,
        <<"background:#f1f4f8;padding:1.2rem;border-radius:12px}h1{font-size:1.6rem}">>,
        <<"small{color:#5c6977}</style>">>,
        <<"<main><h1>DamageBDD · First verification</h1><h2>">>,
        Status,
        <<"</h2><p>Target: ">>,
        esc(maps:get(url, R)),
        <<"</p>">>,
        <<"<p>Expected HTTP status: 200<br>Observed: ">>,
        esc(Description),
        <<"</p>">>,
        <<"<p>Elapsed: ">>,
        integer_to_binary(maps:get(elapsed_ms, R, 0)),
        <<" ms</p><p><small>UTC Unix time: ">>,
        integer_to_binary(maps:get(created_at, R)),
        <<" · Expires after 24 hours. Link access is bearer access.</small></p>">>,
        <<"<h3>Generated acceptance scenario</h3><pre>">>,
        esc(maps:get(feature, R)),
        <<"</pre>">>,
        <<"<small>This is a bounded HTTP status check, not a full paid DamageBDD execution.">>,
        <<" No response bodies or credentials were stored.</small></main></html>">>
    ]).

esc(Data) ->
    B = as_binary(Data),
    %% Escape ampersands first, then remaining HTML metacharacters.
    S1 = binary:replace(B, <<"&">>, <<"&amp;">>, [global]),
    S2 = binary:replace(S1, <<"<">>, <<"&lt;">>, [global]),
    S3 = binary:replace(S2, <<">">>, <<"&gt;">>, [global]),
    S4 = binary:replace(S3, <<"\"">>, <<"&quot;">>, [global]),
    binary:replace(S4, <<"'">>, <<"&#39;">>, [global]).

as_binary(V) when is_binary(V) -> V;
as_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
as_binary(V) when is_list(V) -> unicode:characters_to_binary(V).

lowercase_hex(Bytes) ->
    list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bytes)))).

json_reply(Code, Data, Req) ->
    cowboy_req:reply(
        Code,
        #{
            <<"content-type">> => <<"application/json; charset=utf-8">>,
            <<"cache-control">> => <<"no-store">>,
            <<"x-content-type-options">> => <<"nosniff">>,
            <<"referrer-policy">> => <<"no-referrer">>
        },
        jsx:encode(Data),
        Req
    ).

html_reply(Code, Html, Req) ->
    cowboy_req:reply(
        Code,
        #{
            <<"content-type">> => <<"text/html; charset=utf-8">>,
            <<"cache-control">> => <<"no-store">>,
            <<"x-content-type-options">> => <<"nosniff">>,
            <<"referrer-policy">> => <<"no-referrer">>,
            <<"content-security-policy">> =>
                <<"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'">>
        },
        Html,
        Req
    ).
