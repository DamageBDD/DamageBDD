%%%-------------------------------------------------------------------
%%% Parallel bulk loader for ecai_search (100k+ records)
%%%
%%% Usage (REPL):
%%%   c(ecai_search_bench_parallel), c(ecai_search).
%%%   C = ecai_search_bench_parallel:load_parallel(100000, 8).
%%%-------------------------------------------------------------------
-module(ecai_search_bench_parallel).
-export([load_parallel/2]).

-define(CITIES, [<<"Sydney">>, <<"Melbourne">>, <<"Brisbane">>, <<"Perth">>, <<"Adelaide">>]).
-define(CATS, [
    <<"plumber">>,
    <<"electrician">>,
    <<"builder">>,
    <<"mechanic">>,
    <<"it">>,
    <<"accountant">>,
    <<"dentist">>
]).
-define(TAGPOOL, [
    <<"24x7">>,
    <<"licensed">>,
    <<"emergency">>,
    <<"bulk">>,
    <<"fast">>,
    <<"eco">>,
    <<"ndis">>,
    <<"afterhours">>
]).

%% Top-level: spawn W workers to insert N records into a single Ctx
load_parallel(N, W) when is_integer(N), N > 0, is_integer(W), W > 0 ->
    Ctx = ecai_search:new(),
    Start = erlang:monotonic_time(millisecond),
    Self = self(),

    %% Split [1..N] into W contiguous ranges
    Chunks = chunk_ranges(N, W),

    Pids = [
        spawn_link(fun() -> worker(Ctx, From, To, Self) end)
     || {From, To} <- Chunks
    ],

    %% progress loop
    Total = N,
    loop_progress(length(Pids), 0, 0, Total),

    Finish = erlang:monotonic_time(millisecond),
    Ms = Finish - Start,
    Sz = ecai_search:size(Ctx),
    io:format(
        "Loaded ~p docs in ~p ms  (~.1f docs/sec)~nSize: ~p~n",
        [N, Ms, (N * 1000.0) / max(1, Ms), Sz]
    ),
    Ctx.

%% ---- Workers ------------------------------------------------------

worker(Ctx, From, To, Parent) ->
    seed_rand(),
    Count = To - From + 1,
    ReportEvery = max(Count div 10, 1),
    lists:foreach(
        fun(I) ->
            DocId = iolist_to_binary(["biz:", integer_to_binary(I)]),
            ecai_search:add_record(Ctx, DocId, random_record(I)),
            case (I - From + 1) rem ReportEvery of
                0 -> Parent ! {progress, ReportEvery};
                _ -> ok
            end
        end,
        lists:seq(From, To)
    ),
    Parent ! {done, self()}.

seed_rand() ->
    Now = erlang:monotonic_time(),
    PidHash = erlang:phash2(self()),
    Seed = {Now band 16#FFFF, (Now bsr 16) band 16#FFFF, PidHash band 16#FFFF},
    rand:seed(exsss, Seed).

random_record(I) ->
    Name = <<(random_word(6))/binary, " ", (random_word(5))/binary, " ", (random_word(2))/binary>>,
    Cat = pick(?CATS),
    City = pick(?CITIES),
    Tags = [pick(?TAGPOOL), random_word(4)],
    Phone = make_phone(I),
    #{name => Name, category => Cat, city => City, tags => Tags, phone => Phone}.

random_word(Len) ->
    list_to_binary([$a + rand:uniform(26) - 1 || _ <- lists:seq(1, Len)]).

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).

make_phone(I) ->
    %% Australian-ish mobile: +61 4xxxxxxx (deterministic-ish per I)
    Dig = I rem 10000000,
    list_to_binary(io_lib:format("+61 4~7..0B", [Dig])).

%% ---- Coordinator --------------------------------------------------

loop_progress(0, _Inserted, _Seen, _Total) ->
    ok;
loop_progress(Open, Inserted, Seen, Total) ->
    receive
        {progress, N} ->
            NewI = Inserted + N,
            NewS = Seen + N,
            maybe_tick(NewS, Total),
            loop_progress(Open, NewI, NewS, Total);
        {done, _Pid} ->
            loop_progress(Open - 1, Inserted, Seen, Total)
    after 1000 ->
        maybe_tick(Seen, Total),
        loop_progress(Open, Inserted, Seen, Total)
    end.

maybe_tick(Seen, Total) ->
    %% lightweight periodic print
    Pct = (Seen * 100) div max(1, Total),
    case Pct rem 10 of
        0 when Seen =/= 0 -> io:format("~p% (~p/~p)~n", [Pct, Seen, Total]);
        _ -> ok
    end.

%% ---- Helpers ------------------------------------------------------

chunk_ranges(N, W) ->
    Base = N div W,
    Remainder = N rem W,
    {_, Ranges} =
        lists:foldl(
            fun(Idx, {From, Acc}) ->
                Extra =
                    if
                        Idx =< Remainder -> 1;
                        true -> 0
                    end,
                To = From + Base + Extra - 1,
                {To + 1, Acc ++ [{From, To}]}
            end,
            {1, []},
            lists:seq(1, W)
        ),
    Ranges.
