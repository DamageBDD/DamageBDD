-module(erm_askpass).
-author("Steven Joseph <steven@stevenjoseph.in>").

-copyright("Steven Joseph <steven@stevenjoseph.in>").

-license("Apache-2.0").

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start/0, ask_password/1]).

%% Starts wxWidgets if not already started
start() ->
    case wx:get_env() of
        undefined -> wx:new();
        _ -> ok
    end.

%% Creates a secure password dialog
ask_password(Title) ->
    start(),
    Frame = wxFrame:new(wx:null(), ?wxID_ANY, Title, [{size, {300, 150}}]),
    Panel = wxPanel:new(Frame),

    _Prompt = wxStaticText:new(Panel, ?wxID_ANY, "Enter Password:", [{pos, {20, 20}}]),
    PasswordCtrl = wxTextCtrl:new(Panel, ?wxID_ANY, "", [
        {pos, {20, 50}}, {size, {250, -1}}, {style, ?wxTE_PASSWORD}
    ]),

    OkButton = wxButton:new(Panel, ?wxID_OK, "OK", [{pos, {80, 90}}]),
    CancelButton = wxButton:new(Panel, ?wxID_CANCEL, "Cancel", [{pos, {160, 90}}]),

    wxFrame:connect(Frame, close_window),
    wxButton:connect(OkButton, command_button_clicked, [
        {callback, fun(_Ev) -> wx:destroy(Frame) end}
    ]),
    wxButton:connect(CancelButton, command_button_clicked, [
        {callback, fun(_Ev) -> wx:destroy(Frame) end}
    ]),

    wxFrame:show(Frame),

    %% Wait for user interaction
    ReceivePassword = fun() ->
        receive
            {wx, _, command_button_clicked, ?wxID_OK, _} ->
                Password = wxTextCtrl:getValue(PasswordCtrl),
                wx:destroy(Frame),
                Password;
            {wx, _, command_button_clicked, ?wxID_CANCEL, _} ->
                wx:destroy(Frame),
                undefined
        end
    end,
    ReceivePassword().
