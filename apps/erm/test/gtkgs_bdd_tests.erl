%%%-------------------------------------------------------------------
%%% Contract tests for the GS layer using the deterministic fake backend.
%%% Visual assertions intentionally belong in a separate real-GTK profile.
%%%-------------------------------------------------------------------
-module(gtkgs_bdd_tests).

-include_lib("eunit/include/eunit.hrl").

bdd_contract_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(_SupPid) ->
        [
            fun object_state_and_event_contract/0,
            fun deterministic_dialog_contract/0,
            fun fake_backend_rejects_visual_claims/0
        ]
    end}.

setup() ->
    cleanup_registered(),
    {ok, SupPid} = gtknode4_sup:start_link(#{
        mode => fake,
        gs => #{test_mode => true, event_log_limit => 100}
    }),
    unlink(SupPid),
    ok = gtknode4:await_ready(1000),
    SupPid.

cleanup(SupPid) ->
    exit(SupPid, kill),
    wait_until_stopped(50),
    ok.

object_state_and_event_contract() ->
    Server = gtkgs:server(),
    {ok, [Window]} = gtkgs:create_tree(Server, [
        {window, bdd_window, [{title, "BDD"}], [
            {label, status_label, [{label, "Ready"}]},
            {button, action_button, [{label, "Act"}, {data, action}]}
        ]}
    ]),
    [StatusRef, ButtonRef] = gtkgs:read(Window, children),

    ?assertEqual(<<"Ready">>, gtkgs:read(StatusRef, label)),
    ok = gtkgs:config(StatusRef, {label, "Changed"}),
    ?assertEqual(<<"Changed">>, gtkgs:read(StatusRef, text)),

    Cursor = gtkgs:event_cursor(),
    ok = gtkgs:inject(ButtonRef, click, #{}),
    {ok, Event} = gtkgs:await_event(ButtonRef, click, Cursor, 1000),
    ?assertEqual(action_button, maps:get(name, Event)),
    ?assertEqual(action, maps:get(data, Event)),
    ?assertEqual([], maps:get(args, Event)),

    {ok, Inspection} = gtkgs:inspect(ButtonRef),
    ?assertMatch(#{logical := #{type := button}, native := #{type := button}}, Inspection),
    ok = gtkgs:destroy(Window).

deterministic_dialog_contract() ->
    Server = gtkgs:server(),
    Window = gtkgs:create(window, Server, [{title, "Dialog BDD"}]),
    Cursor = gtkgs:event_cursor(),
    %% The fake backend only auto-responds in test mode; this keeps the
    %% scenario deterministic without pretending to test GTK rendering.
    Response = gtkgs:message_dialog(
        Window,
        "Proceed?",
        [
            {style, [yes_no, question]},
            {auto_response, yes}
        ]
    ),
    ?assertEqual(yes, Response),
    {ok, Opened} = gtkgs:await_event(Window, dialog_opened, Cursor, 1000),
    {ok, Closed} = gtkgs:await_event(
        Window,
        dialog_closed,
        maps:get(seq, Opened),
        1000
    ),
    ?assertEqual(yes, maps:get(response, maps:get(payload, Closed))),
    ?assertEqual([], gtkgs:active_dialogs()),
    ok = gtkgs:destroy(Window).

fake_backend_rejects_visual_claims() ->
    Server = gtkgs:server(),
    Window = gtkgs:create(window, Server, [{title, "No fake pixels"}]),
    ?assertEqual(
        {error, visual_capture_requires_real_backend},
        gtkgs:snapshot(Window)
    ),
    ok = gtkgs:destroy(Window).

cleanup_registered() ->
    case whereis(gtknode4_sup) of
        undefined ->
            ok;
        Pid ->
            exit(Pid, kill),
            wait_until_stopped(50)
    end.

wait_until_stopped(0) ->
    ok;
wait_until_stopped(Attempts) ->
    case whereis(gtknode4_sup) of
        undefined ->
            ok;
        _ ->
            timer:sleep(10),
            wait_until_stopped(Attempts - 1)
    end.
