-module(erm_http).

-vsn("0.1.0").

-include_lib("eunit/include/eunit.hrl").

-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-export([init/2]).
-export([content_types_provided/2]).
-export([to_json/2, to_html/2, from_form/2]).
-export([from_json/2, allowed_methods/2, is_authorized/2]).
-export([content_types_accepted/2]).
-export([trails/0]).

-include_lib("kernel/include/logger.hrl").

-include_lib("kernel/include/logger.hrl").
-define(DEFAULT_ORG, "calendar.org").
-define(TRAILS_TAG, ["Erm"]).

trails() ->
    [
        trails:trail(
            "/erm/list_windows",
            erm_http,
            #{action => list_windows},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "List windows.",
                    produces => ["application/json"],
                    parameters => []
                }
            }
        ),
        trails:trail(
            "/erm/apps/:app/[:action]",
            erm_http,
            #{action => app},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Interact with app adapters.",
                    produces => ["application/json"],
                    parameters => []
                }
            }
        ),
        trails:trail(
            "/erm/volume/",
            erm_http,
            #{action => volume},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Volume control.",
                    produces => ["application/json"],
                    parameters => []
                }
            }
        ),
        %% NEW: schedule_call
        trails:trail(
            "/erm/schedule_call/:duration",
            erm_http,
            #{action => schedule_call},
            #{
                get => #{
                    tags => ?TRAILS_TAG,
                    description => "Serve booking form or JSON schema for call scheduling.",
                    produces => ["application/json", "text/html"],
                    parameters => [
                        #{name => <<"duration">>, in => path, required => true, type => integer},
                        #{name => <<"format">>, in => query, required => false, type => string}
                    ]
                },
                post => #{
                    tags => ?TRAILS_TAG,
                    description => "Create an Org SCHEDULED entry.",
                    consumes => ["application/json", "application/x-www-form-urlencoded"],
                    produces => ["application/json"]
                }
            }
        )
    ].

%% ===== Cowboy REST boilerplate ==============================================

init(Req, Opts) -> {cowboy_rest, Req, Opts}.
is_authorized(Req, State) -> {true, Req, State}.
allowed_methods(Req, State) -> {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

content_types_provided(Req, State) ->
    %% Provide both JSON and HTML so GET can negotiate either.
    {
        [
            {{<<"application">>, <<"json">>, []}, to_json},
            {{<<"text">>, <<"html">>, []}, to_html}
        ],
        Req,
        State
    }.

content_types_accepted(Req, State) ->
    {
        [
            {{<<"application">>, <<"json">>, []}, from_json},
            {{<<"application">>, <<"x-www-form-urlencoded">>, []}, from_form}
        ],
        Req,
        State
    }.

%% ===== GET handlers ==========================================================

to_json(Req, #{action := list_windows} = State) ->
    Windows = x11:list_windows(),
    {jsx:encode(Windows), Req, State};
to_json(Req, #{action := app} = State) ->
    case cowboy_req:binding(app, Req) of
        undefined ->
            {jsx:encode(#{error => <<"app required">>}), Req, State};
        App ->
            Func = cowboy_req:binding(function, Req, <<"show">>),
            AppModule = binary_to_atom(<<"erm_", App/binary>>),
            _ = apply(AppModule, binary_to_atom(Func), []),
            {jsx:encode(#{status => <<"ok">>}), Req, State}
    end;
to_json(Req, #{action := schedule_call} = State) ->
    Duration = parse_duration(Req),
    Schema = #{
        <<"endpoint">> => <<"/erm/schedule_call/", (integer_to_binary(Duration))/binary>>,
        <<"method">> => <<"POST">>,
        <<"accepts">> => [<<"application/json">>, <<"application/x-www-form-urlencoded">>],
        <<"fields">> => #{
            <<"name">> => <<"string">>,
            <<"email">> => <<"string">>,
            <<"start">> => <<"YYYY-MM-DDTHH:MM (local time)">>,
            <<"note">> => <<"string (optional)">>
        },
        <<"writes_to">> => list_to_binary(org_path())
    },
    {jsx:encode(Schema), Req, State}.

to_html(Req, #{action := schedule_call} = State) ->
    %% Allow ?format=html to force HTML in UAs that prefer JSON
    case cowboy_req:qs_val(<<"format">>, Req) of
        {<<"html">>, _} -> ok;
        _ -> ok
    end,
    Dur = parse_duration(Req),
    Html = booking_form_html(Dur),
    {Html, Req, State};
to_html(Req, State) ->
    %% Fallback HTML for other actions (rarely used)
    {<<"<html><body><pre>HTML not available for this endpoint.</pre></body></html>">>, Req, State}.

%% ===== POST handlers =========================================================

from_json(Req, #{action := schedule_call} = State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    case safe_decode_json(Body) of
        {ok, Map} -> persist_booking(Req1, Map, State);
        {error, R} -> {stop, reply_error(400, R, Req1), State}
    end;
from_json(Req, State) ->
    {stop, reply_error(415, <<"Unsupported for this action">>, Req), State}.

from_form(Req, #{action := schedule_call} = State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req),
    case uri_string:dissect_query(Body) of
        {ok, Pairs} ->
            Map = maps:from_list([{list_to_binary(K), list_to_binary(V)} || {K, V} <- Pairs]),
            persist_booking(Req1, Map, State);
        _ ->
            {stop, reply_error(400, <<"Invalid form body">>, Req1), State}
    end;
from_form(Req, State) ->
    {stop, reply_error(415, <<"Unsupported for this action">>, Req), State}.

persist_booking(Req, Fields0, State) ->
    Duration = parse_duration(Req),
    case validate_fields(Fields0) of
        {ok, #{name := Name, email := Email, start := StartIso, note := Note}} ->
            case parse_iso8601(StartIso) of
                {ok, {{Y, Mo, D}, {H, Mi}}} ->
                    End = add_minutes({{Y, Mo, D}, {H, Mi}}, Duration),
                    UUID = gen_uuid(),
                    OrgBin = render_org_entry(
                        Name, Email, Note, {{Y, Mo, D}, {H, Mi}}, End, Duration, UUID
                    ),
                    Path = org_path(),
                    ok = ensure_parent_dir(Path),
                    case file:write_file(Path, OrgBin, [append]) of
                        ok ->
                            Body = jsx:encode(#{
                                status => <<"created">>,
                                id => UUID,
                                duration_minutes => Duration,
                                org_file => list_to_binary(Path)
                            }),
                            {stop,
                                cowboy_req:reply(
                                    201, #{<<"content-type">> => <<"application/json">>}, Body, Req
                                ),
                                State};
                        {error, E} ->
                            ?LOG_ERROR("schedule_call write error: ~p", [E]),
                            {stop, reply_error(500, <<"Failed to write booking">>, Req), State}
                    end;
                {error, _} ->
                    {stop,
                        reply_error(400, <<"Invalid start timestamp (use YYYY-MM-DDTHH:MM)">>, Req),
                        State}
            end;
        {error, Why} ->
            {stop, reply_error(400, Why, Req), State}
    end.

%% ===== Helpers ===============================================================

parse_duration(Req) ->
    case cowboy_req:binding(duration, Req, <<"30">>) of
        B when is_binary(B) ->
            try
                binary_to_integer(B)
            catch
                _:_ -> 30
            end;
        I when is_integer(I) -> I;
        _ ->
            30
    end.

org_path() ->
    case application:get_env(erm, org_calendar_path) of
        {ok, Path} when is_list(Path); is_binary(Path) -> to_list(Path);
        _ -> ?DEFAULT_ORG
    end.
ensure_parent_dir(Path) ->
    Dir = filename:dirname(Path),
    %% ensure_dir/1 expects a trailing slash-friendly path; join a token to satisfy ensure_dir
    ok = damage_utils:ensure_dir(Dir ++ "/"),
    ok.

validate_fields(Map0) ->
    %% Accept <<"name">>, <<"email">>, <<"start">>, optional <<"note">>
    Need = [<<"name">>, <<"email">>, <<"start">>],
    Missing = [K || K <- Need, not maps:is_key(K, Map0) orelse is_blank(maps:get(K, Map0))],
    case Missing of
        [] ->
            Note = maps:get(<<"note">>, Map0, <<>>),
            {ok, #{
                name => maps:get(<<"name">>, Map0),
                email => maps:get(<<"email">>, Map0),
                start => maps:get(<<"start">>, Map0),
                note => Note
            }};
        _ ->
            {error, iolist_to_binary([<<"Missing fields: ">>, lists:join(<<", ">>, Missing)])}
    end.

is_blank(<<>>) -> true;
is_blank(B) when is_binary(B) -> re:run(B, <<"^\\s*$">>) =/= nomatch.

safe_decode_json(Bin) ->
    try
        {ok, jsx:decode(Bin, [return_maps])}
    catch
        _:_ -> {error, <<"Invalid JSON">>}
    end.

reply_error(Code, Msg, Req) ->
    cowboy_req:reply(
        Code,
        #{<<"content-type">> => <<"application/json">>},
        jsx:encode(#{error => Msg}),
        Req
    ).

%% --- Org entry via your loader (bbmustache) ---
render_org_entry(
    NameB,
    EmailB,
    NoteB,
    {{Y, Mo, D}, {H, Mi}},
    {EndDate, {EH, EM}},
    DurationMin,
    UUID
) ->
    Day = day_name(Y, Mo, D),
    {EY, EMo, ED} = EndDate,

    %% Build timestamp text using damage_utils:strf/2 (not io_lib)
    TimestampStr =
        case {Y, Mo, D} =:= {EY, EMo, ED} of
            true ->
                damage_utils:strf(
                    "<~4..0B-~2..0B-~2..0B ~s ~2..0B:~2..0B-~2..0B:~2..0B>",
                    [Y, Mo, D, Day, H, Mi, EH, EM]
                );
            false ->
                damage_utils:strf(
                    "<~4..0B-~2..0B-~2..0B ~s ~2..0B:~2..0B>--<~4..0B-~2..0B-~2..0B ~s ~2..0B:~2..0B>",
                    [Y, Mo, D, Day, H, Mi, EY, EMo, ED, day_name(EY, EMo, ED), EH, EM]
                )
        end,

    Context = #{
        name => ensure_bin(NameB),
        email => ensure_bin(EmailB),
        note => ensure_bin(NoteB),
        duration_min => integer_to_binary(DurationMin),
        uuid => UUID,
        timestamp => list_to_binary(TimestampStr)
    },
    damage_utils:load_template("schedule_org.mustache", Context).

%% --- HTML via your loader (bbmustache) ---
booking_form_html(DurationMin) ->
    Context = #{duration => integer_to_binary(DurationMin)},
    damage_utils:load_template("schedule_form.mustache", Context).

%% ---- time utils -------------------------------------------------------------

parse_iso8601(Bin) ->
    Re = <<"^(\\d{4})-(\\d{2})-(\\d{2})[T\\s](\\d{2}):(\\d{2})">>,
    case re:run(Bin, Re, [{capture, all_but_first, list}]) of
        {match, [YS, MS, DS, HS, MiS]} ->
            {ok,
                {{list_to_integer(YS), list_to_integer(MS), list_to_integer(DS)}, {
                    list_to_integer(HS), list_to_integer(MiS)
                }}};
        nomatch ->
            {error, invalid}
    end.

add_minutes({{Y, Mo, D}, {H, Mi}}, Minutes) ->
    Base = calendar:datetime_to_gregorian_seconds({{Y, Mo, D}, {H, Mi, 0}}),
    {{EY, EMo, ED}, {EH, EM, _}} = calendar:gregorian_seconds_to_datetime(Base + Minutes * 60),
    {{EY, EMo, ED}, {EH, EM}}.

%% ---- day name helpers (use lists, not binaries) ----------------------------
day_name(Y, Mo, D) ->
    W = calendar:day_of_the_week(Y, Mo, D),
    to_title(element(W, {mon, tue, wed, thu, fri, sat, sun})).

to_title(A) ->
    %% "mon" -> "Mon" (list)
    S = atom_to_list(A),
    Upper = hd(string:to_upper([hd(S)])),
    [Upper | tl(S)].

ensure_bin(B) when is_binary(B) -> B;
ensure_bin(L) when is_list(L) -> list_to_binary(L);
ensure_bin(I) when is_integer(I) -> integer_to_binary(I).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

gen_uuid() ->
    <<A:32, B:16, C0:16, D0:16, E:48>> = crypto:strong_rand_bytes(16),
    %% version 4
    C = (C0 band 16#0fff) bor 16#4000,
    %% variant 10xx
    D = (D0 band 16#3fff) bor 16#8000,
    list_to_binary(
        io_lib:format(
            "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
            [A, B, C, D, E]
        )
    ).
