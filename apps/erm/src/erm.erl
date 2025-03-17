-module(erm).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").

-export([ask_password/1]).

get_password_text(PasswordCtrl) ->
    Text = wxTextCtrl:getValue(PasswordCtrl),
    string:strip(Text).

close_askpass(Frame) ->
    erase(askpass),
    wxWindow:close(Frame).

receive_loop(Frame, PasswordCtrl, CancelButton, OkButton) ->
    receive
        {wx, _, OkButton, [], {wxCommand, command_button_clicked, [], 0, 0}} ->
            ?LOG_DEBUG("Callback button ~p", [OkButton]),
            case get_password_text(PasswordCtrl) of
                "" ->
                    receive_loop(Frame, PasswordCtrl, CancelButton, OkButton);
                Password ->
                    close_askpass(Frame),
                    Password
            end;
        {wx, _, CancelButton, [], {wxCommand, command_button_clicked, [], 0, 0}} ->
            ?LOG_DEBUG("Cancel button", []),
            close_askpass(Frame),
            undefined;
        {wx, _, PasswordCtrl, _, {wxKey, key_up, _, _, 13, _, _, _, _, 13, _, _}} ->
            case get_password_text(PasswordCtrl) of
                "" ->
                    receive_loop(Frame, PasswordCtrl, CancelButton, OkButton);
                Password ->
                    close_askpass(Frame),
                    Password
            end;
        {wx, _, _Obj, [], {wxKey, key_up, _, _, 27, false, false, false, false, 27, _, _}} ->
            ?LOG_DEBUG("Cancel button", []),
            close_askpass(Frame),
            undefined;
        {wx, _, _Obj, [], {wxKey, key_up, _, _, _, false, false, false, false, _, _, _}} ->
            receive_loop(Frame, PasswordCtrl, CancelButton, OkButton);
        Unknown ->
            ?LOG_DEBUG("Unknown evvent ~p", [Unknown]),
            receive_loop(Frame, PasswordCtrl, CancelButton, OkButton)
    end.

%% Creates a secure password dialog
ask_password(Title) ->
    case get(askpass) of
        undefined ->
            put(askpass, self()),
            askpass(Title);
        Pid when is_pid(Pid) ->
            %% Block until the previous dialog is closed
            receive
            after infinity -> ok
            end,
            ask_password(Title)
    end.
askpass(Title) ->
    wx:new(),
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, Title, [{size, {300, 150}}, {pos, {300, 300}}]),
    Panel = wxPanel:new(Frame),
    Sizer = wxBoxSizer:new(?wxVERTICAL),

    TitlePrompt = wxStaticText:new(Panel, ?wxID_ANY, Title, [{style, ?wxALIGN_CENTER}]),
    wxSizer:add(Sizer, TitlePrompt, [{proportion, 1}]),
    Prompt = wxStaticText:new(Panel, ?wxID_ANY, "Enter Password:", [{style, ?wxALIGN_CENTER}]),
    wxSizer:add(Sizer, Prompt, [{proportion, 1}]),
    PasswordCtrl = wxTextCtrl:new(Panel, ?wxID_ANY, [
        {pos, {20, 50}}, {size, {250, -1}}, {style, ?wxTE_PASSWORD}
    ]),
    wxSizer:add(
        Sizer,
        PasswordCtrl,
        [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 5}]
    ),

    ButtonSzFlags = [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 5}],
    ButtonSizer = wxBoxSizer:new(?wxHORIZONTAL),

    OkButton = wxButton:new(Panel, ?wxID_OK, [{label, "OK"}, {pos, {80, 90}}]),
    CancelButton = wxButton:new(Panel, ?wxID_CANCEL, [{label, "Cancel"}, {pos, {160, 90}}]),
    wxSizer:add(ButtonSizer, OkButton, ButtonSzFlags),
    wxSizer:add(ButtonSizer, CancelButton, ButtonSzFlags),
    wxSizer:add(Sizer, ButtonSizer, [{flag, ?wxEXPAND bor ?wxALL}, {border, 5}]),
    wxFrame:setSizerAndFit(Panel, Sizer),

    wxButton:connect(CancelButton, command_button_clicked, []),
    wxButton:connect(OkButton, command_button_clicked, []),
    wxTextCtrl:connect(PasswordCtrl, key_up, []),

    wxSizer:setSizeHints(Sizer, Frame),
    wxFrame:show(Frame),

    %% Wait for user interaction
    receive_loop(Frame, PasswordCtrl, CancelButton, OkButton).
