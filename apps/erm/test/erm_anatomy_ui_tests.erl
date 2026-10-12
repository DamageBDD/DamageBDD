-module(erm_anatomy_ui_tests).
-include_lib("eunit/include/eunit.hrl").
-export([init/1, handle_command/2, handle_cast/2, terminate/2]).

%% Exercise the real GTKGS/controller with a backend that also enforces the
%% native gn4_attach_widget/2 single-child window constraint.
init(Opts) ->
    {ok, Fake, Caps} = gtknode4_fake:init(Opts),
    {ok, #{fake => Fake, objects => #{}}, Caps}.

handle_command(
    {create, Id, Type, Parent, _Props} = Command,
    #{fake := Fake, objects := Objects} = State
) ->
    ParentType =
        case maps:find(Parent, Objects) of
            {ok, #{type := T}} -> T;
            error -> undefined
        end,
    HasChild = lists:any(
        fun(#{parent := P}) -> P =:= Parent end,
        maps:values(Objects)
    ),
    case ParentType =:= window andalso HasChild of
        true ->
            {reply, {error, create_failed}, State};
        false ->
            case gtknode4_fake:handle_command(Command, Fake) of
                {reply, {ok, _} = Reply, Next} ->
                    {reply, Reply, State#{
                        fake := Next,
                        objects := Objects#{Id => #{type => Type, parent => Parent}}
                    }};
                {reply, Reply, Next} ->
                    {reply, Reply, State#{fake := Next}}
            end
    end;
handle_command({destroy, _} = Command, #{fake := Fake, objects := Objects} = State) ->
    {reply, Reply, Next} = gtknode4_fake:handle_command(Command, Fake),
    Remaining = maps:filter(
        fun(Id, _) ->
            case gtknode4_fake:handle_command({inspect, Id}, Next) of
                {reply, {ok, _}, _} -> true;
                _ -> false
            end
        end,
        Objects
    ),
    {reply, Reply, State#{fake := Next, objects := Remaining}};
handle_command(test_objects, #{objects := Objects} = State) ->
    {reply, {ok, Objects}, State};
handle_command(Command, #{fake := Fake} = State) ->
    case gtknode4_fake:handle_command(Command, Fake) of
        {reply, Reply, Next} -> {reply, Reply, State#{fake := Next}};
        {reply, Reply, Next, Events} -> {reply, Reply, State#{fake := Next}, Events}
    end.
handle_cast(_, State) -> {noreply, State}.
terminate(_, _) -> ok.

single_window_child_test() ->
    Dir = filename:join(
        "/tmp",
        "anatomy-ui-test-" ++ os:getpid() ++ "-" ++
            integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:make_dir(Dir),
    ok = file:write_file(
        filename:join(Dir, "test.obj"),
        <<"v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n">>
    ),
    ok = file:write_file(
        filename:join(Dir, "manifest.config"),
        <<"[#{id => <<\"test\">>, name => <<\"Test mesh\">>, file => \"test.obj\"}].\n">>
    ),
    LogSetting = application:get_env(erm, log_to_file),
    application:set_env(erm, log_to_file, false),
    {ok, Sup} = gtknode4_sup:start_link(#{mode => fake, backend => ?MODULE}),
    unlink(Sup),
    try
        ok = gtknode4:await_ready(1000),
        %% Confirm the test backend detects the original failure and that
        %% GTKGS rolls back a rejected tree before testing the viewer itself.
        ?assertEqual(
            {error, {tree_node_failed, {frame, second}, error, create_failed}},
            gtkgs:create_tree(gtkgs:server(), [
                {window, example, [], [{label, first, []}, {frame, second, []}]}
            ])
        ),
        ?assertEqual({ok, #{}}, gtknode4:call(test_objects)),
        lists:foreach(
            fun(_) ->
                {ok, Pid} = erm_anatomy:start_link(#{
                    data_dir => Dir,
                    cache_dir => Dir,
                    auto_fetch => false
                }),
                unlink(Pid),
                ?assertEqual(ready, await_phase(100)),
                {ok, Objects} = gtknode4:call(test_objects),
                [Window] = [Id || {Id, #{type := window}} <- maps:to_list(Objects)],
                [#{type := box}] = [
                    O
                 || #{parent := Parent} = O <- maps:values(Objects),
                    Parent =:= Window
                ],
                exercise_mouse(Objects),
                ok = erm_anatomy:stop(),
                ?assertEqual(not_started, erm_anatomy:status()),
                ?assertEqual({ok, #{}}, gtknode4:call(test_objects)),
                ?assertEqual(
                    {ok, ["manifest.config", "test.obj"]},
                    sorted_files(Dir)
                )
            end,
            [first_start, reopen]
        )
    after
        erm_anatomy:stop(),
        gen_server:stop(Sup),
        file:del_dir_r(Dir),
        case LogSetting of
            undefined -> application:unset_env(erm, log_to_file);
            {ok, Value} -> application:set_env(erm, log_to_file, Value)
        end
    end.

await_phase(0) ->
    timeout;
await_phase(N) ->
    case erm_anatomy:status() of
        #{phase := loading} -> receive
            after 10 -> await_phase(N - 1)
            end;
        #{phase := Phase} -> Phase
    end.
sorted_files(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    {ok, lists:sort(Files)}.

exercise_mouse(Objects) ->
    [View] = [Id || {Id, #{type := picture}} <- maps:to_list(Objects)],
    Send = fun(Event, Data) -> ok = gtknode4:call({inject, View, Event, Data}) end,
    Begin = #{x => 450, y => 350, button => 1, width => 900, height => 700},
    Send(pointer_drag_begin, Begin),
    Send(pointer_drag_update, #{dx => 10, dy => 0}),
    Send(pointer_drag_update, #{dx => 20, dy => 0}),
    Send(pointer_drag_end, #{dx => 20, dy => 0}),
    await_status(fun(#{camera := {Y, _, _}}) -> abs(Y - 0.16) < 0.0001 end, 100),
    Send(pointer_doubleclick, #{button => 1}),
    await_status(
        fun(#{camera := C, pan := Pan}) -> C =:= {+0.0, +0.0, 1.0} andalso Pan =:= {+0.0, +0.0} end,
        100
    ),
    Send(pointer_drag_begin, Begin#{button := 3}),
    Send(pointer_drag_end, #{dx => 90, dy => 35}),
    await_status(fun(#{pan := {X, Y}}) -> abs(X - 90) < 0.01 andalso abs(Y - 35) < 0.01 end, 100),
    Send(pointer_scroll, #{dy => -1000000}),
    await_status(fun(#{camera := {_, _, Z}}) -> Z =:= 8.0 end, 100),
    [Send(pointer_scroll, #{dy => 1000000}) || _ <- lists:seq(1, 4)],
    await_status(fun(#{camera := {_, _, Z}}) -> Z =:= 0.1 end, 100),
    Send(pointer_doubleclick, #{button => 1}),
    await_status(fun(#{camera := C}) -> C =:= {+0.0, +0.0, 1.0} end, 100),
    Send(pointer_drag_begin, Begin),
    Send(pointer_cancel, #{}),
    Send(pointer_drag_update, #{dx => 80, dy => 20}),
    %% Wait for the controller, GTKGS and viewer queues to drain in order.
    ok = gtkgs:sync(),
    timer:sleep(50),
    ?assertMatch(#{camera := {+0.0, +0.0, 1.0}}, erm_anatomy:status()),
    ?assertEqual({error, invalid_source_or_structures}, erm_anatomy:load_source(unknown, [])),
    State = sys:get_state(erm_anatomy),
    ?assert(maps:get(frame, State) < 20).
await_status(_Pred, 0) ->
    error(pointer_event_timeout);
await_status(Pred, N) ->
    case Pred(erm_anatomy:status()) of
        true -> ok;
        false -> receive
            after 10 -> await_status(Pred, N - 1)
            end
    end.
