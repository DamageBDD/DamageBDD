%% erm_askpass.erl
%% Fully self-contained GUI/TTY password (and text) prompt utility.
%% Apache-2.0
%% Author: Steven Joseph <steven@stevenjoseph.in>

-module(erm_askpass).

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").

-export([ask_password/1, ask_text/1]).

%% =========================
%% Public API
%% =========================

%% ask_password("Enter password:")
ask_password(Prompt) when is_list(Prompt) ->
    try
        case maybe_gui_password(Prompt) of
            {ok, Pw} ->
                Pw;
            _ ->
                case maybe_devtty_password(Prompt) of
                    {ok, Pw2} ->
                        Pw2;
                    _ ->
                        case maybe_stdio_password(Prompt) of
                            {ok, Pw3} -> Pw3;
                            _ -> error({no_user_input_available, all_attempts_failed})
                        end
                end
        end
    catch
        throw:cancel -> error({user_cancelled, password});
        Class:Reason -> erlang:error({ask_password_failed, Class, Reason})
    end.

%% ask_text("Enter value:")
%% Text entry (echoed). Uses GUI where possible, then /dev/tty, then stdio.
ask_text(Prompt) when is_list(Prompt) ->
    try
        case maybe_gui_text(Prompt) of
            {ok, S} ->
                S;
            _ ->
                case maybe_devtty_text(Prompt) of
                    {ok, S2} ->
                        S2;
                    _ ->
                        case maybe_stdio_text(Prompt) of
                            {ok, S3} -> S3;
                            _ -> error({no_user_input_available, all_attempts_failed})
                        end
                end
        end
    catch
        throw:cancel -> error({user_cancelled, text});
        Class:Reason -> erlang:error({ask_text_failed, Class, Reason})
    end.

%% =========================
%% GUI path (wx)
%% =========================

maybe_gui_password(Prompt) ->
    case is_gui_available() of
        true -> gui_password_dialog("Authentication", Prompt);
        false -> {error, no_gui}
    end.

maybe_gui_text(Prompt) ->
    case is_gui_available() of
        true -> gui_text_dialog("Input Required", Prompt);
        false -> {error, no_gui}
    end.

%% ---- Password dialog (masked) ----
gui_password_dialog(Title, Prompt) ->
    with_wx(fun() ->
        show_dialog(Title, Prompt, password)
    end).

%% ---- Text dialog (echoed) ----
gui_text_dialog(Title, Prompt) ->
    with_wx(fun() ->
        show_dialog(Title, Prompt, text)
    end).

%% Core dialog builder/runner
show_dialog(Title, Prompt, Mode) ->
    case get(askpass) of
        undefined ->
            put(askpass, self());
        Pid when is_pid(Pid) ->
            %% Prevent parallel dialogs; wait for the other to close.
            receive
            after 1 -> ok
            end,
            erase(askpass),
            put(askpass, self())
    end,
    try
        Frame = wxFrame:new(wx:null(), ?wxID_ANY, Title, [{size, {360, 180}}]),
        Panel = wxPanel:new(Frame),
        Sizer = wxBoxSizer:new(?wxVERTICAL),

        TitlePrompt = wxStaticText:new(Panel, ?wxID_ANY, Title, [{style, ?wxALIGN_CENTER}]),
        wxSizer:add(Sizer, TitlePrompt, [
            {proportion, 0}, {flag, ?wxALL bor ?wxALIGN_CENTER}, {border, 8}
        ]),

        PromptLbl = wxStaticText:new(Panel, ?wxID_ANY, Prompt, [{style, ?wxALIGN_CENTER}]),
        wxSizer:add(Sizer, PromptLbl, [
            {proportion, 0}, {flag, ?wxALL bor ?wxALIGN_CENTER}, {border, 6}
        ]),

        Style =
            case Mode of
                password -> ?wxTE_PASSWORD;
                text -> 0
            end,
        Input = wxTextCtrl:new(Panel, ?wxID_ANY, [{style, Style}]),
        wxSizer:add(Sizer, Input, [
            {proportion, 0}, {flag, ?wxEXPAND bor ?wxLEFT bor ?wxRIGHT}, {border, 12}
        ]),

        BtnSizer = wxBoxSizer:new(?wxHORIZONTAL),
        OkBtn = wxButton:new(Panel, ?wxID_OK, [{label, "OK"}]),
        CancelBtn = wxButton:new(Panel, ?wxID_CANCEL, [{label, "Cancel"}]),
        wxSizer:add(BtnSizer, OkBtn, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 6}]),
        wxSizer:add(BtnSizer, CancelBtn, [
            {proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 6}
        ]),
        wxSizer:add(Sizer, BtnSizer, [{proportion, 0}, {flag, ?wxEXPAND bor ?wxALL}, {border, 6}]),

        wxFrame:setSizerAndFit(Panel, Sizer),
        wxButton:connect(OkBtn, command_button_clicked, []),
        wxButton:connect(CancelBtn, command_button_clicked, []),
        wxTextCtrl:connect(Input, key_up, []),

        wxFrame:show(Frame),

        Result = dialog_loop(Frame, Input, CancelBtn, OkBtn, Mode),
        case Result of
            undefined -> throw(cancel);
            "" -> {error, empty};
            Value -> {ok, Value}
        end
    after
        erase(askpass)
    end.

dialog_loop(Frame, Input, CancelBtn, OkBtn, Mode) ->
    receive
        {wx, _, OkBtn, [], {wxCommand, command_button_clicked, [], 0, 0}} ->
            case get_input(Input) of
                "" ->
                    dialog_loop(Frame, Input, CancelBtn, OkBtn, Mode);
                V ->
                    close_frame(Frame),
                    V
            end;
        {wx, _, CancelBtn, [], {wxCommand, command_button_clicked, [], 0, 0}} ->
            close_frame(Frame),
            undefined;
        {wx, _, Input, _, {wxKey, key_up, _, _, 13, _, _, _, _, 13, _, _}} ->
            %% Enter
            case get_input(Input) of
                "" ->
                    dialog_loop(Frame, Input, CancelBtn, OkBtn, Mode);
                V ->
                    close_frame(Frame),
                    V
            end;
        {wx, _, _Obj, [], {wxKey, key_up, _, _, 27, _, _, _, _, 27, _, _}} ->
            %% Esc
            close_frame(Frame),
            undefined;
        _Other ->
            dialog_loop(Frame, Input, CancelBtn, OkBtn, Mode)
    end.

get_input(TextCtrl) ->
    Text = wxTextCtrl:getValue(TextCtrl),
    string:strip(Text).

close_frame(Frame) ->
    catch wxWindow:close(Frame).

with_wx(Fun) ->
    %% Ensure wx is available and a display/wayland session exists
    case is_gui_available() of
        false ->
            {error, no_gui};
        true ->
            WX = wx:new(),
            try
                Fun()
            after
                catch wx:destroy(WX)
            end
    end.

is_gui_available() ->
    Has = fun(Var) ->
        case os:getenv(Var) of
            false -> false;
            _ -> true
        end
    end,
    Has("WAYLAND_DISPLAY") orelse Has("DISPLAY") orelse
        case os:getenv("XDG_SESSION_TYPE") of
            "wayland" -> true;
            "x11" -> true;
            _ -> false
        end.

%% =========================
%% /dev/tty and stdio paths
%% =========================

maybe_devtty_password(Prompt) ->
    case file:open("/dev/tty", [read, write]) of
        {ok, Dev} ->
            try
                Pw = io:get_password(Dev, Prompt),
                case Pw of
                    "" -> {error, empty};
                    _ -> {ok, flatten(Pw)}
                end
            catch
                _:E -> {error, {tty_password_failed, E}}
            after
                catch file:close(Dev)
            end;
        {error, enoent} ->
            {error, no_tty};
        Err ->
            Err
    end.

maybe_devtty_text(Prompt) ->
    case file:open("/dev/tty", [read, write]) of
        {ok, Dev} ->
            try
                ok = io:format(Dev, "~s", [Prompt]),
                case io:get_line(Dev, "") of
                    eof ->
                        {error, eof};
                    Line ->
                        Val = strip_newline(Line),
                        case Val of
                            "" -> {error, empty};
                            _ -> {ok, Val}
                        end
                end
            catch
                _:E -> {error, {tty_text_failed, E}}
            after
                catch file:close(Dev)
            end;
        {error, enoent} ->
            {error, no_tty};
        Err ->
            Err
    end.

maybe_stdio_password(Prompt) ->
    case stdio_is_tty() of
        true ->
            try
                Pw = io:get_password(Prompt, "~s"),
                case Pw of
                    "" -> {error, empty};
                    _ -> {ok, flatten(Pw)}
                end
            catch
                _:E -> {error, {stdio_password_failed, E}}
            end;
        false ->
            {error, stdio_not_tty}
    end.

maybe_stdio_text(Prompt) ->
    case stdio_is_tty() of
        true ->
            try
                ok = io:format("~s", [Prompt]),
                case io:get_line("") of
                    eof ->
                        {error, eof};
                    Line ->
                        Val = strip_newline(Line),
                        case Val of
                            "" -> {error, empty};
                            _ -> {ok, Val}
                        end
                end
            catch
                _:E -> {error, {stdio_text_failed, E}}
            end;
        false ->
            {error, stdio_not_tty}
    end.

stdio_is_tty() ->
    %% Heuristic: group_leader is interactive; adequate for most shells.
    GL = group_leader(),
    is_pid(GL) andalso GL =:= whereis(user).

strip_newline(S) when is_list(S) ->
    lists:reverse(strip_nl_rev(lists:reverse(S)));
strip_newline(B) when is_binary(B) ->
    strip_newline(unicode:characters_to_list(B)).

strip_nl_rev([$\n | T]) -> strip_nl_rev(T);
strip_nl_rev([$\r | T]) -> strip_nl_rev(T);
strip_nl_rev(L) -> L.

flatten(S) when is_binary(S) -> unicode:characters_to_list(S);
flatten(S) when is_list(S) -> lists:flatten(S);
flatten(Other) -> lists:flatten(io_lib:format("~ts", [Other])).
