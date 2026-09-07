%%%-------------------------------------------------------------------
%%% @doc
%%% ERM GTK4 dialog demo. It deliberately uses only the gtkgs public API;
%%% there are no direct GTK or gtknode4 protocol calls in the UI process.
%%%-------------------------------------------------------------------
-module(gtkgs_dialog_demo).

-export([start/0, start_local/0, init/0, about/1, help/1, stop/1]).

-spec start() -> pid() | {error, term()}.
start() ->
    case ui_ready() of
        ok -> spawn(?MODULE, init, []);
        Error -> Error
    end.

-spec start_local() -> {ok, pid()} | {error, term()}.
start_local() ->
    case ensure_local_stack() of
        ok ->
            case gtknode4:await_ready(10000) of
                ok -> normalize_start(start());
                Error -> Error
            end;
        Error ->
            Error
    end.

about(Pid) when is_pid(Pid) ->
    Pid ! show_about,
    ok.

help(Pid) when is_pid(Pid) ->
    Pid ! show_help,
    ok.

stop(Pid) when is_pid(Pid) ->
    Pid ! stop,
    ok.

init() ->
    case ui_ready() of
        ok -> init_ready(gtkgs:server());
        {error, Reason} ->
            logger:warning("gtkgs dialog demo not started: ~p", [Reason]),
            ok
    end.

init_ready(Server) ->
    case gtkgs:create_tree(Server, [
        {window, main_window,
            [
                {title, "gtkgs manual test"},
                {size, {720, 520}},
                {orient, vertical}
            ],
            [
                {label, intro_label, [
                    {label,
                        {text, "GS-style objects and deterministic events over a GTK4 C-node."}},
                    {border, 10}
                ]},

                {entry, name_entry, [
                    {text, "Type here and press Return"},
                    {expand, true},
                    {border, 10}
                ]},

                {listbox, test_list, [
                    {items, [
                        "Nostr relay",
                        "Nostr event",
                        "Nostr identity"
                    ]},
                    {proportion, 1},
                    {expand, true},
                    {border, 10}
                ]},

                {editor, compose_editor, [
                    {text, "A test Nostr note."},
                    {proportion, 1},
                    {expand, true},
                    {border, 10}
                ]},

                {frame, action_row,
                    [
                        {orient, horizontal},
                        {expand, true},
                        {border, 10}
                    ],
                    [
                        {button, read_button, [
                            {label, "Read editor"},
                            {data, read_editor},
                            {border, 4}
                        ]},
                        {button, toggle_button, [
                            {label, "Toggle editor"},
                            {data, toggle_editor},
                            {border, 4}
                        ]},
                        {button, help_button, [
                            {label, "Help"},
                            {data, show_help},
                            {border, 4}
                        ]},
                        {button, about_button, [
                            {label, "About"},
                            {data, show_about},
                            {border, 4}
                        ]},
                        {button, close_button, [
                            {label, "Close"},
                            {data, close_window},
                            {border, 4}
                        ]}
                    ]},

                {label, status_label, [
                    {label, {text, "Ready"}},
                    {expand, true},
                    {border, 10}
                ]}
            ]}
    ]) of
        {ok, [Window]} ->
            case {gtkgs:config(Window, {map, true}), gtkgs:sync()} of
                {ok, ok} -> loop();
                {ConfigResult, SyncResult} ->
                    logger:error("gtkgs demo initialization failed: config=~p sync=~p", [
                        ConfigResult, SyncResult
                    ]),
                    _ = gtkgs:destroy(Window),
                    ok
            end;
        {error, Reason} ->
            logger:error("gtkgs demo tree creation failed: ~p", [Reason]),
            ok;
        Other ->
            logger:error("gtkgs demo returned an unexpected tree result: ~p", [Other]),
            ok
    end.

loop() ->
    receive
        {gtkgs, about_button, click, show_about, []} ->
            show_about_dialog(),
            loop();
        {gtkgs, help_button, click, show_help, []} ->
            show_help_dialog(),
            loop();
        show_about ->
            show_about_dialog(),
            loop();
        show_help ->
            show_help_dialog(),
            loop();
        stop ->
            gtkgs:destroy(main_window),
            ok;
        {gtkgs, read_button, click, read_editor, []} ->
            Text = gtkgs:read(compose_editor, text),
            set_status(io_lib:format("Editor contains: ~ts", [Text])),
            loop();
        {gtkgs, toggle_button, click, toggle_editor, []} ->
            Enabled = gtkgs:read(compose_editor, enable),
            ok = gtkgs:config(compose_editor, {enable, not Enabled}),
            set_status(io_lib:format("Editor enabled: ~p", [not Enabled])),
            loop();
        {gtkgs, name_entry, keypress, _Data, ['Return', Text]} ->
            set_status(io_lib:format("Entry Return: ~ts", [Text])),
            loop();
        {gtkgs, test_list, click, _Data, [Index, Text, true]} ->
            set_status(io_lib:format("List item ~p: ~ts", [Index, Text])),
            loop();
        {gtkgs, close_button, click, close_window, []} ->
            gtkgs:destroy(main_window),
            ok;
        {gtkgs, main_window, destroy, _Data, _Args} ->
            ok;
        Other ->
            io:format("gtkgs demo unhandled: ~p~n", [Other]),
            loop()
    end.

show_about_dialog() ->
    Result = gtkgs:message_dialog(
        main_window,
        about_text(),
        [
            {caption, "About gtkgs"},
            {style, [ok, information]}
        ]
    ),
    set_status(io_lib:format("About dialog closed: ~p", [Result])).

show_help_dialog() ->
    Result = gtkgs:message_dialog(
        main_window,
        help_text(),
        [
            {caption, "gtkgs Help"},
            {style, [ok, information]}
        ]
    ),
    set_status(io_lib:format("Help dialog closed: ~p", [Result])).

set_status(Text) ->
    gtkgs:config(status_label, {label, {text, unicode:characters_to_binary(Text)}}).

about_text() ->
    "gtkgs\n\n"
    "A GS-style logical object layer implemented over a supervised GTK4 C-node.\n\n"
    "This demo exercises hierarchy, owner-local names, reads, configuration, "
    "canonical events, renderer synchronisation and asynchronous GTK4 dialogs.".

help_text() ->
    "Manual test:\n\n"
    "1. Type into the entry and press Return.\n"
    "2. Select a list item.\n"
    "3. Edit the Nostr note and click Read editor.\n"
    "4. Toggle the editor enabled state.\n"
    "5. Open About and Help to test GTK4 dialogs.\n"
    "6. Close the window.".

ensure_local_stack() ->
    case whereis(gtknode4) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            case whereis(erm_sup) of
                ErmSup when is_pid(ErmSup) ->
                    {error, {
                        gtknode4_not_enabled,
                        "set erm.gtknode4.enabled to true and restart ERM"
                    }};
                undefined ->
                    %% Standalone/manual use outside a running ERM application.
                    Config0 = application:get_env(erm, gtknode4, #{}),
                    Config = maps:remove(enabled, options_map(Config0)),
                    case gtknode4_sup:start_link(Config#{mode => local_cnode}) of
                        {ok, SupPid} ->
                            unlink(SupPid),
                            ok;
                        {error, {already_started, _Pid}} ->
                            ok;
                        Error ->
                            Error
                    end
            end
    end.

ui_ready() ->
    case {whereis(gtkgs), whereis(gtknode4)} of
        {undefined, _} ->
            {error, gtkgs_not_started};
        {_, undefined} ->
            {error, gtknode4_not_started};
        {_Gtkgs, _Controller} ->
            try gtknode4:await_ready(0) of
                ok -> ok;
                {error, timeout} -> {error, gtknode4_not_ready};
                Other -> {error, {gtknode4_not_ready, Other}}
            catch
                exit:{noproc, _} -> {error, gtknode4_not_started};
                Class:Reason -> {error, {gtknode4_status_failed, Class, Reason}}
            end
    end.

normalize_start(Pid) when is_pid(Pid) -> {ok, Pid};
normalize_start({error, _Reason} = Error) -> Error.

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List);
options_map(undefined) -> #{}.
