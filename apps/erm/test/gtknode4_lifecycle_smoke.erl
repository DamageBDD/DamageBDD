%%%-------------------------------------------------------------------
%%% @doc Native gtknode4 widget-lifecycle smoke test.
%%%
%%% Run under the local_cnode profile with the C-node environment set to:
%%%     G_DEBUG=fatal-criticals
%%%
%%% A GTK critical will then terminate the native process, making a lifecycle
%%% regression observable through a changed OS pid or disconnected controller.
%%%-------------------------------------------------------------------
-module(gtknode4_lifecycle_smoke).

-export([run/0, run/1]).

-define(DEFAULT_ITERATIONS, 100).
-define(READY_TIMEOUT, 10000).

-spec run() -> {ok, map()} | {error, term()}.
run() ->
    run(?DEFAULT_ITERATIONS).

-spec run(pos_integer()) -> {ok, map()} | {error, term()}.
run(Iterations) when is_integer(Iterations), Iterations > 0 ->
    try
        ok = gtknode4:await_ready(?READY_TIMEOUT),
        Port0 = gtknode4_port:status(),
        OsPid0 = maps:get(os_pid, Port0),
        true = maps:get(alive, Port0),

        lists:foreach(fun exercise_tree/1, lists:seq(1, Iterations)),

        ok = expect_ok(gtkgs:sync()),
        Controller = gtknode4:status(),
        Port1 = gtknode4_port:status(),
        OsPid1 = maps:get(os_pid, Port1),

        case
            {
                maps:get(ready, Controller, false),
                maps:get(alive, Port1, false),
                OsPid1 =:= OsPid0
            }
        of
            {true, true, true} ->
                {ok, #{
                    iterations => Iterations,
                    os_pid => OsPid1,
                    controller => Controller,
                    port => Port1
                }};
            Failure ->
                {error, #{
                    lifecycle_regression => Failure,
                    initial_os_pid => OsPid0,
                    final_os_pid => OsPid1,
                    controller => Controller,
                    port => Port1
                }}
        end
    catch
        Class:Reason:Stacktrace ->
            {error, {Class, Reason, Stacktrace}}
    end;
run(Iterations) ->
    {error, {bad_iterations, Iterations}}.

exercise_tree(Index) ->
    Server = gtkgs:server(),
    Window = expect_ref(
        gtkgs:create(window, Server, [
            {title, io_lib:format("gtknode4 lifecycle ~B", [Index])},
            {size, {420, 280}},
            {orient, vertical}
        ])
    ),
    Outer = expect_ref(
        gtkgs:create(frame, Window, [
            {orient, vertical},
            {expand, true},
            {margin, 8}
        ])
    ),
    Row = expect_ref(
        gtkgs:create(frame, Outer, [
            {orient, horizontal},
            {expand, true},
            {spacing, 4}
        ])
    ),
    _Label = expect_ref(
        gtkgs:create(label, Row, [
            {label, "Lifecycle"},
            {expand, true}
        ])
    ),
    _Button = expect_ref(
        gtkgs:create(button, Row, [
            {label, "Destroy"}
        ])
    ),
    _Entry = expect_ref(
        gtkgs:create(entry, Outer, [
            {text, "registry-owned child"},
            {expand, true}
        ])
    ),
    _List = expect_ref(
        gtkgs:create(listbox, Outer, [
            {items, ["one", "two", "three"]},
            {expand, true}
        ])
    ),

    ok = expect_ok(gtkgs:config(Window, {map, true})),
    ok = expect_ok(gtkgs:sync()),
    ok = expect_ok(gtkgs:destroy(Window)),
    ok = expect_ok(gtkgs:sync()).

expect_ref({gtkgs_ref, _Server, _Id} = Ref) ->
    Ref;
expect_ref(Other) ->
    error({gtkgs_create_failed, Other}).

expect_ok(ok) ->
    ok;
expect_ok(Other) ->
    error({gtkgs_operation_failed, Other}).
