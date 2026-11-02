%% Declarative GTK frame-clock motion. Targets are motion/voice_meter widgets.
-module(gtkgs_motion).
-export([animate/2, animate/3, sequence/2, sequence/3, stagger/3,
         set/2, cancel/1, pause/1, resume/1, seek/2, inspect/1,
         classes/2, add_class/2, remove_class/2, normalize/1]).

animate(Object, To) -> animate(Object, To, #{}).
animate(Object, To, Options) when is_map(Options) ->
    sequence(Object, [Options#{to => To}], Options);
animate(_, _, _) -> {error, invalid_motion}.
sequence(Object, Steps) -> sequence(Object, Steps, #{}).
sequence(Object, Steps, Options) when is_map(Options) ->
    case normalize(Steps) of
        {ok, Segments} ->
            Reduced = maps:get(reduced_motion, Options,
                               application:get_env(erm, reduced_motion, false)),
            case is_boolean(Reduced) of
                true ->
                    Id = erlang:unique_integer([positive, monotonic]),
                    case gtkgs:motion(Object, play, {Id, Reduced, Segments}) of
                        ok -> {ok, Id};
                        Error -> Error
                    end;
                false -> {error, invalid_motion}
            end;
        Error -> Error
    end;
sequence(_, _, _) -> {error, invalid_motion}.
%% Start all targets now, applying a native delay to each. No Erlang timers.
stagger(Objects, Step, Gap) when is_list(Objects), length(Objects) =< 128,
                               is_map(Step), is_integer(Gap), Gap >= 0, Gap =< 5000 ->
    case normalize([Step]) of
        {ok,_} ->
            Steps=[Step#{delay => maps:get(delay, Step, 0) + N*Gap}
                   || N <- lists:seq(0, length(Objects)-1)],
            case lists:all(fun(S)->element(1,normalize([S]))=:=ok end,Steps) of
                true -> [sequence(O,[S],Step) || {O,S}<-lists:zip(Objects,Steps)];
                false -> {error, invalid_motion}
            end;
        Error -> Error
    end;
stagger(_, _, _) -> {error, invalid_motion}.
set(Object, Values) ->
    case normalize([#{to => Values, duration => 0}]) of
        {ok, _} -> gtkgs:motion(Object, set, Values);
        Error -> Error
    end.
cancel(Object) -> gtkgs:motion(Object, cancel, #{}).
pause(Object) -> gtkgs:motion(Object, pause, #{}).
resume(Object) -> gtkgs:motion(Object, resume, #{}).
seek(Object, Ms) when is_number(Ms), Ms >= 0, Ms =< 600000 ->
    gtkgs:motion(Object, seek, Ms);
seek(_, _) -> {error, invalid_motion}.
inspect(Object) -> gtkgs:motion(Object, inspect, #{}).
classes(Object, Names) -> class_config(Object, classes, Names).
add_class(Object, Names) -> class_config(Object, class, Names).
remove_class(Object, Names) -> class_config(Object, remove_class, Names).
class_config(Object, Key, Names) ->
    try
        true = is_list(Names) andalso length(Names) =< 32,
        Bins = [unicode:characters_to_binary(N) || N <- Names],
        true = lists:all(fun(B) -> byte_size(B) > 0 andalso byte_size(B) =< 80 andalso
                           re:run(B, <<"^[a-zA-Z_][a-zA-Z0-9_-]*$">>) =/= nomatch end, Bins),
        gtkgs:config(Object, {Key, iolist_to_binary(lists:join(<<" ">>, Bins))})
    catch _:_ -> {error, invalid_classes} end.

normalize(Steps) ->
    try
        true = is_list(Steps) andalso Steps =/= [] andalso length(Steps) =< 64,
        Segments = [segment(S) || S <- Steps],
        true = lists:sum([D+L || {D,L,_,_} <- Segments]) =< 600000,
        {ok, Segments}
    catch _:_ -> {error, invalid_motion} end.
segment(S) ->
    true = is_map(S),
    [] = maps:keys(S) -- [to, duration, delay, easing, reduced_motion],
    To = maps:get(to, S),
    true = is_map(To) andalso map_size(To) > 0,
    true = lists:all(fun({K,V}) -> valid(K,V) end, maps:to_list(To)),
    Duration = maps:get(duration, S, 180), Delay = maps:get(delay, S, 0),
    true = is_integer(Duration) andalso Duration >= 0 andalso Duration =< 600000,
    true = is_integer(Delay) andalso Delay >= 0 andalso Delay =< 600000,
    Ease = maps:get(easing, S, out_cubic),
    true = lists:member(Ease, [linear, out_cubic, spring]),
    {Duration, Delay, Ease, To}.
valid(K,V) when is_number(V) ->
    case K of
        x -> abs(V) =< 100000;
        y -> abs(V) =< 100000;
        rotation -> abs(V) =< 100000;
        scale -> V >= 0.01 andalso V =< 100;
        opacity -> V >= 0 andalso V =< 1;
        input -> V >= 0 andalso V =< 1;
        output -> V >= 0 andalso V =< 1;
        mood -> is_integer(V) andalso V >= 0 andalso V =< 5;
        _ -> false
    end;
valid(_,_) -> false.
