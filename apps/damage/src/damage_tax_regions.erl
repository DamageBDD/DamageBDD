%%% Country-specific reporting period and fiat metadata. These are accounting
%%% workpaper profiles, NOT tax advice, residency determination or filing rules.
%%% IDs are fixed binaries; never construct atoms from client country codes.
-module(damage_tax_regions).
-export([
    all/0,
    lookup/1,
    valid/1,
    currency/1,
    minor_digits/1,
    default_offset/1,
    default_month/1,
    start_day/2,
    bounds/4,
    year/4
]).

all() ->
    [
        profile(<<"AU">>, <<"Australia">>, <<"AUD">>, 2, 7, 1, 600, false, <<"income_and_cgt">>),
        profile(
            <<"US">>, <<"United States">>, <<"USD">>, 2, 1, 1, 0, true, <<"form_8949_support">>
        ),
        profile(<<"NZ">>, <<"New Zealand">>, <<"NZD">>, 2, 4, 1, 720, false, <<"crypto_income">>),
        profile(<<"IN">>, <<"India">>, <<"INR">>, 2, 4, 1, 330, false, <<"schedule_vda_support">>),
        profile(
            <<"SG">>, <<"Singapore">>, <<"SGD">>, 2, 1, 1, 480, true, <<"digital_token_business">>
        ),
        profile(
            <<"AE">>,
            <<"United Arab Emirates">>,
            <<"AED">>,
            2,
            1,
            1,
            240,
            true,
            <<"corporate_tax_support">>
        ),
        profile(
            <<"GB">>,
            <<"United Kingdom">>,
            <<"GBP">>,
            2,
            4,
            6,
            0,
            true,
            <<"income_and_capital_gains">>
        ),
        profile(
            <<"CH">>, <<"Switzerland">>, <<"CHF">>, 2, 1, 1, 60, true, <<"income_and_holdings">>
        ),
        profile(
            <<"HK">>, <<"Hong Kong">>, <<"HKD">>, 2, 1, 1, 480, true, <<"profits_tax_support">>
        ),
        profile(
            <<"CA">>, <<"Canada">>, <<"CAD">>, 2, 1, 1, 0, true, <<"income_and_capital_gains">>
        ),
        profile(
            <<"PT">>, <<"Portugal">>, <<"EUR">>, 2, 1, 1, 0, true, <<"crypto_income_and_disposals">>
        ),
        profile(<<"JP">>, <<"Japan">>, <<"JPY">>, 0, 1, 1, 540, true, <<"crypto_income">>),
        profile(<<"DE">>, <<"Germany">>, <<"EUR">>, 2, 1, 1, 60, true, <<"income_and_disposals">>)
    ].

profile(Code, Name, Currency, Digits, Month, Day, Offset, Custom, Workpaper) ->
    #{
        <<"code">> => Code,
        <<"name">> => Name,
        <<"currency">> => Currency,
        <<"minor_digits">> => Digits,
        <<"start_month">> => Month,
        <<"start_day">> => Day,
        <<"default_offset_minutes">> => Offset,
        <<"custom_period">> => Custom,
        <<"workpaper">> => Workpaper
    }.

-spec lookup(binary()) -> {ok, map()} | {error, unsupported_tax_jurisdiction}.
lookup(Code) when is_binary(Code) ->
    case [P || #{<<"code">> := C} = P <- all(), C =:= Code] of
        [P] -> {ok, P};
        _ -> {error, unsupported_tax_jurisdiction}
    end;
lookup(_) ->
    {error, unsupported_tax_jurisdiction}.

valid(Code) -> element(1, lookup(Code)) =:= ok.
currency(Code) -> field(Code, <<"currency">>).
minor_digits(Code) -> field(Code, <<"minor_digits">>).
default_offset(Code) -> field(Code, <<"default_offset_minutes">>).
default_month(Code) -> field(Code, <<"start_month">>).

field(Code, Key) ->
    case lookup(Code) of
        {ok, Profile} -> maps:get(Key, Profile);
        Error -> Error
    end.

start_day(Code, Month) ->
    case lookup(Code) of
        {ok, Profile} ->
            case Month =:= maps:get(<<"start_month">>, Profile) of
                true -> maps:get(<<"start_day">>, Profile);
                false -> 1
            end;
        Error ->
            Error
    end.

%% Start-month overrides are allowed only where the profile supports a
%% business/financial-year period. A UK custom start uses day 1, not April 6.
-spec bounds(binary(), integer(), integer(), integer()) ->
    {ok, {integer(), integer()}} | {error, term()}.
bounds(Code, EndYear, Offset, Month) when
    is_integer(EndYear),
    EndYear >= 2009,
    EndYear =< 2200,
    is_integer(Offset),
    Offset >= -720,
    Offset =< 840,
    is_integer(Month),
    Month >= 1,
    Month =< 12
->
    case lookup(Code) of
        {ok, Profile} ->
            DefaultMonth = maps:get(<<"start_month">>, Profile),
            case Month =:= DefaultMonth orelse maps:get(<<"custom_period">>, Profile) of
                true ->
                    Day = start_day(Code, Month),
                    StartYear =
                        case Month of
                            1 -> EndYear;
                            _ -> EndYear - 1
                        end,
                    Start = unix({{StartYear, Month, Day}, {0, 0, 0}}) - Offset * 60,
                    End = unix({{StartYear + 1, Month, Day}, {0, 0, 0}}) - Offset * 60,
                    {ok, {Start, End}};
                false ->
                    {error, custom_tax_period_not_supported}
            end;
        Error ->
            Error
    end;
bounds(_, _, _, _) ->
    {error, invalid_tax_period}.

-spec year(binary(), integer(), integer(), integer()) -> integer() | {error, term()}.
year(Code, Ts, Offset, Month) when is_integer(Ts), Ts >= 0 ->
    case lookup(Code) of
        {ok, _Profile} ->
            case bounds(Code, 2026, Offset, Month) of
                {ok, _} ->
                    {{Y, M, D}, _} = calendar:gregorian_seconds_to_datetime(
                        epoch() + Ts + Offset * 60
                    ),
                    Day = start_day(Code, Month),
                    case Month of
                        1 when Day =:= 1 -> Y;
                        _ ->
                            case {M, D} >= {Month, Day} of
                                true -> Y + 1;
                                false -> Y
                            end
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end;
year(_, _, _, _) ->
    {error, invalid_tax_period}.

unix(DateTime) -> calendar:datetime_to_gregorian_seconds(DateTime) - epoch().
epoch() -> calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).
