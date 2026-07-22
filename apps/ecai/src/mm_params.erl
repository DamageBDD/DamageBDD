%%% =====================
%%% ecai_params.erl
%%% Deterministic, ECAI-style intraday parameter retrieval for market making.
%%% Encodes (symbol, param, slot) into a curve-hash-like key and maps to
%%% reproducible values without probability. Swap the mapping with on-chain
%%% ECAI NFT reads later.
%%% =====================

-module(mm_params).
-export([
    % (Param, Symbol) -> Value
    get_intraday_param/2,
    % (Param, Symbol, Default) -> Value
    get_intraday_param/3,
    % returns {dow, hour_slot}
    now_slot/0,
    % internal visibility for tests
    encode_key/3
]).

%% 10-min slots
-define(SLOTS_PER_HOUR, 6).
-define(MAX_STEP_BP, 80).
-define(MIN_STEP_BP, 8).

%% Public API -------------------------------------------------------------
get_intraday_param(Param, Symbol) ->
    get_intraday_param(Param, Symbol, undefined).

get_intraday_param(Param, Symbol, Default) ->
    Slot = now_slot(),
    Key = encode_key(Symbol, Param, Slot),
    case Param of
        "STEP_BP" ->
            %% Map key to tight/wide spread deterministically.
            %% Busy opens/close -> tighter; lunch lull -> wider; add key-mapping jitter for anti-gaming.
            Base = base_step_bp(Slot),
            Jit = jitter(Key, 5),
            clamp(Base + Jit, ?MIN_STEP_BP, ?MAX_STEP_BP);
        "BUDGET" ->
            %% Recycle capital more times per hour for intraday.
            %% 300–800 USDT envelope, deterministic per slot.
            Base =
                case Slot of
                    %% AU morning (pre-US) moderate
                    {_, H, _} when H >= 0, H < 10 -> 500.0;
                    %% midday lull
                    {_, H, _} when H >= 10, H < 15 -> 350.0;
                    %% afternoon pick-up
                    {_, H, _} when H >= 15, H < 20 -> 650.0;
                    _ -> 450.0
                end,
            Base + (jitter(Key, 30) * 1.0);
        "REFRESH_MS" ->
            %% 5s—20s depending on slot; shorter for volatility windows.
            case base_refresh_ms(Slot) of
                fast -> 5_000;
                med -> 10_000;
                slow -> 20_000
            end;
        "QTY_SLOPE" ->
            1.10 + (jitter(Key, 5) / 100.0);
        "LEVELS" ->
            %% 6..10
            6 + (jitter(Key, 5) rem 5);
        _ ->
            Default
    end.

%% Time slot utilities ----------------------------------------------------
now_slot() ->
    {{Y, Mo, D}, {H, Mi, _S}} = calendar:universal_time(),
    Dow = day_of_week({Y, Mo, D}),
    Slot = (Mi div (60 div ?SLOTS_PER_HOUR)),
    {Dow, H, Slot}.
%% RFC 3339 weekday (1..7). Portable across OTP versions.
day_of_week({Y, Mo, D}) ->
    %% Prefer modern API if present
    case erlang:function_exported(calendar, day_of_the_week, 1) of
        true ->
            calendar:day_of_the_week({Y, Mo, D});
        false ->
            %% Older OTP has day_of_week/3
            case erlang:function_exported(calendar, day_of_week, 3) of
                true ->
                    calendar:day_of_week(Y, Mo, D);
                false ->
                    %% Fallback using Zeller’s congruence (Mon=1..Sun=7)
                    dow_fallback(Y, Mo, D)
            end
    end.

dow_fallback(Y, M, D) ->
    {Y1, M1} =
        case M < 3 of
            true -> {Y - 1, M + 12};
            false -> {Y, M}
        end,
    K = Y1 rem 100,
    J = Y1 div 100,
    H0 = (D + (13 * (M1 + 1)) div 5 + K + K div 4 + J div 4 + 5 * J) rem 7,
    ((H0 + 5) rem 7) + 1.

%% Deterministic encoders -------------------------------------------------
encode_key(Symbol, Param, {Dow, H, Slot}) ->
    Data = io_lib:format("~s|~s|~B|~B|~B", [Symbol, Param, Dow, H, Slot]),
    crypto:hash(sha256, list_to_binary(Data)).

jitter(Key, Max) when is_binary(Key), Max > 0 ->
    <<A:32, _/binary>> = Key,
    (A rem (Max + 1)).

base_step_bp({_, H, _}) ->
    case H of
        %% tighter mornings
        Hh when Hh >= 0, Hh < 10 -> 20;
        %% wider midday
        Hh when Hh >= 10, Hh < 15 -> 45;
        %% moderate pm
        Hh when Hh >= 15, Hh < 20 -> 28;
        _ -> 35
    end.

base_refresh_ms({_, H, _}) ->
    case H of
        Hh when Hh >= 9, Hh < 11 -> fast;
        Hh when Hh >= 11, Hh < 15 -> slow;
        Hh when Hh >= 15, Hh < 19 -> med;
        _ -> med
    end.

clamp(X, Min, _Max) when X < Min -> Min;
clamp(X, _Min, Max) when X > Max -> Max;
clamp(X, _Min, _Max) -> X.
