%%%-------------------------------------------------------------------
%%% wxgs_dialog_demo
%%%
%%% Small manual test application for wxgs. It deliberately uses the
%%% GS-like public API only; there are no direct wx calls here.
%%%-------------------------------------------------------------------
-module(wxgs_dialog_demo).

-export([start/0, init/0, about/1, help/1, stop/1]).

start() ->
    spawn(?MODULE, init, []).

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
    Server = wxgs:start(),

    {ok, [Window]} = wxgs:create_tree(Server, [
        {window, main_window,
            [
                {title, "wxgs manual test"},
                {size, {720, 520}},
                {orient, vertical}
            ],
            [
                {label, intro_label, [
                    {label, {text, "GS-style objects and events implemented on Erlang wx."}},
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
    ]),

    ok = wxgs:config(Window, {map, true}),
    loop().

loop() ->
    receive
        {wxgs, about_button, click, show_about, []} ->
            show_about_dialog(),
            loop();
        {wxgs, help_button, click, show_help, []} ->
            show_help_dialog(),
            loop();
        show_about ->
            show_about_dialog(),
            loop();
        show_help ->
            show_help_dialog(),
            loop();
        stop ->
            wxgs:destroy(main_window),
            ok;
        {wxgs, read_button, click, read_editor, []} ->
            Text = wxgs:read(compose_editor, text),
            set_status(io_lib:format("Editor contains: ~ts", [Text])),
            loop();
        {wxgs, toggle_button, click, toggle_editor, []} ->
            Enabled = wxgs:read(compose_editor, enable),
            ok = wxgs:config(compose_editor, {enable, not Enabled}),
            set_status(io_lib:format("Editor enabled: ~p", [not Enabled])),
            loop();
        {wxgs, name_entry, keypress, _Data, ['Return', Text]} ->
            set_status(io_lib:format("Entry Return: ~ts", [Text])),
            loop();
        {wxgs, test_list, click, _Data, [Index, Text, true]} ->
            set_status(io_lib:format("List item ~p: ~ts", [Index, Text])),
            loop();
        {wxgs, close_button, click, close_window, []} ->
            wxgs:destroy(main_window),
            ok;
        {wxgs, main_window, destroy, _Data, _Args} ->
            ok;
        Other ->
            io:format("wxgs demo unhandled: ~p~n", [Other]),
            loop()
    end.

show_about_dialog() ->
    _ = wxgs:message_dialog(
        main_window,
        about_text(),
        [
            {caption, "About wxgs"},
            {style, [ok, information]}
        ]
    ),
    set_status("About dialog closed").

show_help_dialog() ->
    _ = wxgs:message_dialog(
        main_window,
        help_text(),
        [
            {caption, "wxgs Help"},
            {style, [ok, information]}
        ]
    ),
    set_status("Help dialog closed").

set_status(Text) ->
    wxgs:config(status_label, {label, {text, lists:flatten(Text)}}).

about_text() ->
    "wxgs\n\n"
    "A small GS-style compatibility layer implemented on Erlang wx.\n\n"
    "This demo exercises object hierarchy, owner-local names, configuration, "
    "reads, list/entry/button events and modal dialogs.".

help_text() ->
    "Manual test:\n\n"
    "1. Type into the entry and press Return.\n"
    "2. Select a list item.\n"
    "3. Edit the Nostr note and click Read editor.\n"
    "4. Toggle the editor enabled state.\n"
    "5. Open About and Help to test wxgs modal dialogs.\n"
    "6. Close the window.".
