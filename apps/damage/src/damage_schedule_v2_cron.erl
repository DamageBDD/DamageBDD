-module(damage_schedule_v2_cron).

-export([parse/1, next_after/2, occurrences/3, matches/2, human/1]).

-define(UNIX_EPOCH_GREGORIAN, 62167219200).
-define(MAX_SCAN_MINUTES, 60 * 24 * 366 * 2).
-define(MAX_OCCURRENCES, 100000).


-spec parse(binary() | string()) -> {ok, map()} | {error, term()}.
parse(Cron0) ->
    Cron = string:trim(to_list(Cron0)),
    case string:tokens(Cron, " \t") of
        [Min, Hour, Dom, Month, Dow] ->
            with_fields([
                {minute, Min, 0, 59},
                {hour, Hour, 0, 23},
                {day, Dom, 1, 31},
                {month, Month, 1, 12},
                {dow, Dow, 0, 7}
            ]);
        _ ->
            {error, {invalid_cron, Cron}}
    end.

with_fields(Fields) ->
    with_fields(Fields, #{}).

with_fields([], Acc) ->
    {ok, Acc};
with_fields([{Name, Expr, Min, Max} | Rest], Acc) ->
    case parse_field(Expr, Min, Max) of
        {ok, Values} -> with_fields(Rest, maps:put(Name, Values, Acc));
        {error, Why} -> {error, {Name, Why}}
    end.

parse_field("*", Min, Max) ->
    {ok, lists:seq(Min, Max)};
parse_field(Expr, Min, Max) ->
    Parts = string:tokens(Expr, ","),
    try
        Values0 = lists:append([parse_part(P, Min, Max) || P <- Parts]),
        Values1 = lists:usort([normalize_dow(V, Min, Max) || V <- Values0]),
        case lists:all(fun(V) -> V >= Min andalso V =< Max end, Values1) of
            true -> {ok, Values1};
            false -> {error, out_of_range}
        end
    catch
        throw:Reason -> {error, Reason};
        error:Reason -> {error, Reason}
    end.

parse_part(Part, Min, Max) ->
    case string:split(Part, "/", all) of
        [Base, Step0] ->
            Step = parse_int(Step0),
            case Step > 0 of
                true -> take_step(parse_base(Base, Min, Max), Step);
                false -> throw(invalid_step)
            end;
        [Base] ->
            parse_base(Base, Min, Max);
        _ ->
            throw(invalid_field)
    end.

parse_base("*", Min, Max) ->
    lists:seq(Min, Max);
parse_base(Base, _Min, _Max) ->
    case string:split(Base, "-", all) of
        [A0, B0] ->
            A = parse_int(A0),
            B = parse_int(B0),
            case A =< B of
                true -> lists:seq(A, B);
                false -> throw(invalid_range)
            end;
        [V0] -> [parse_int(V0)];
        _ -> throw(invalid_range)
    end.

take_step(Values, Step) ->
    take_step(Values, Step, 0, []).

take_step([], _Step, _I, Acc) -> lists:reverse(Acc);
take_step([V | Rest], Step, I, Acc) ->
    case I rem Step of
        0 -> take_step(Rest, Step, I + 1, [V | Acc]);
        _ -> take_step(Rest, Step, I + 1, Acc)
    end.

normalize_dow(7, 0, 7) -> 0;
normalize_dow(V, _Min, _Max) -> V.

parse_int(S) ->
    try list_to_integer(S) of
        I -> I
    catch
        _:_ -> throw({invalid_integer, S})
    end.

-spec next_after(binary() | string(), integer()) -> {ok, integer()} | {error, term()}.
next_after(Cron, AfterEpoch) when is_integer(AfterEpoch) ->
    case parse(Cron) of
        {ok, Parsed} ->
            Start = ((AfterEpoch div 60) + 1) * 60,
            scan_next(Parsed, Start, ?MAX_SCAN_MINUTES);
        Error -> Error
    end.

scan_next(_Parsed, _Epoch, 0) ->
    {error, no_occurrence_in_scan_window};
scan_next(Parsed, Epoch, Left) ->
    case matches(Parsed, Epoch) of
        true -> {ok, Epoch};
        false -> scan_next(Parsed, Epoch + 60, Left - 1)
    end.

-spec occurrences(binary() | string(), integer(), integer()) -> {ok, [integer()]} | {error, term()}.
occurrences(Cron, FromEpoch, ToEpoch) when is_integer(FromEpoch), is_integer(ToEpoch) ->
    case FromEpoch =< ToEpoch of
        false -> {error, invalid_range};
        true -> occurrences0(Cron, FromEpoch - 1, ToEpoch, [], 0)
    end.

occurrences0(_Cron, _Cursor, _To, _Acc, N) when N >= ?MAX_OCCURRENCES ->
    {error, too_many_occurrences};
occurrences0(Cron, Cursor, To, Acc, N) ->
    case next_after(Cron, Cursor) of
        {ok, Next} when Next =< To ->
            occurrences0(Cron, Next, To, [Next | Acc], N + 1);
        {ok, _Next} ->
            {ok, lists:reverse(Acc)};
        {error, no_occurrence_in_scan_window} ->
            {ok, lists:reverse(Acc)};
        Error -> Error
    end.

-spec matches(map(), integer()) -> boolean().
matches(Parsed, Epoch) when is_map(Parsed), is_integer(Epoch) ->
    {{Year, Month, Day}, {Hour, Minute, _Second}} = epoch_to_datetime(Epoch),
    _ = Year,
    Dow0 = calendar:day_of_the_week({Year, Month, Day}),
    Dow = case Dow0 of 7 -> 0; N -> N end,
    member(Minute, maps:get(minute, Parsed)) andalso
        member(Hour, maps:get(hour, Parsed)) andalso
        member(Day, maps:get(day, Parsed)) andalso
        member(Month, maps:get(month, Parsed)) andalso
        member(Dow, maps:get(dow, Parsed)).

member(V, Values) -> lists:member(V, Values).

-spec human(binary() | string()) -> binary().
human(Cron0) ->
    Cron = to_list(Cron0),
    case string:tokens(Cron, " \t") of
        ["*/15", "*", "*", "*", "*"] -> <<"Every 15 minutes">>;
        ["*/30", "*", "*", "*", "*"] -> <<"Every 30 minutes">>;
        [Min, "*", "*", "*", "*"] ->
            list_to_binary(io_lib:format("Every hour at :~2..0B UTC", [parse_int_safe(Min, 0)]));
        [Min, Hour, "*", "*", "*"] ->
            list_to_binary(
                io_lib:format("Daily at ~2..0B:~2..0B UTC", [parse_int_safe(Hour, 0), parse_int_safe(Min, 0)])
            );
        [Min, Hour, "*", "*", "1-5"] ->
            list_to_binary(
                io_lib:format("Weekdays at ~2..0B:~2..0B UTC", [parse_int_safe(Hour, 0), parse_int_safe(Min, 0)])
            );
        _ -> to_bin(Cron0)
    end.

parse_int_safe(S, Default) ->
    try list_to_integer(S) catch _:_ -> Default end.

epoch_to_datetime(Epoch) ->
    calendar:gregorian_seconds_to_datetime(Epoch + ?UNIX_EPOCH_GREGORIAN).

to_list(B) when is_binary(B) -> binary_to_list(B);
to_list(L) when is_list(L) -> L.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L).
