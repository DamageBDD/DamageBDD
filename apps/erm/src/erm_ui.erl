-module(erm_ui).

-include_lib("wx/include/wx.hrl").

-export([
    theme/0,
    set_theme/1,
    apply_root/1,
    panel/2,
    card/1,
    card_alt/1,
    title/2,
    section/2,
    body_text/2,
    small_text/2,
    status_text/2,
    button/3,
    touch_button/3,
    paint_button/2,
    add/3,
    add_expand/3,
    spacer/2
]).

theme() ->
    erm_theme:current().

set_theme(Name) ->
    erm_theme:set_current(Name).

apply_root(Window) ->
    T = theme(),
    wxWindow:setBackgroundColour(Window, erm_theme:color(bg, T)),
    ok.

panel(Parent, Kind) ->
    Style =
        case Kind of
            root -> ?wxBORDER_NONE;
            top -> ?wxBORDER_NONE;
            bottom -> ?wxBORDER_SIMPLE;
            _ -> ?wxBORDER_SIMPLE
        end,
    P = wxPanel:new(Parent, [{style, Style}]),
    paint_panel(P, Kind),
    P.

card(Parent) ->
    P = wxPanel:new(Parent, [{style, ?wxBORDER_SIMPLE}]),
    paint_panel(P, card),
    P.

card_alt(Parent) ->
    P = wxPanel:new(Parent, [{style, ?wxBORDER_SIMPLE}]),
    paint_panel(P, card_alt),
    P.

paint_panel(P, Kind) ->
    T = theme(),
    ColourKey =
        case Kind of
            root -> bg;
            top -> surface;
            bottom -> surface;
            card -> card;
            card_alt -> card_alt;
            _ -> surface
        end,
    wxWindow:setBackgroundColour(P, erm_theme:color(ColourKey, T)),
    ok.

title(Parent, Text) ->
    static(Parent, Text, title, text).

section(Parent, Text) ->
    static(Parent, Text, section, accent).

body_text(Parent, Text) ->
    W = static(Parent, Text, body, text),
    wxStaticText:wrap(W, 420),
    W.

small_text(Parent, Text) ->
    W = static(Parent, Text, small, muted),
    wxStaticText:wrap(W, 420),
    W.

status_text(Parent, Text) ->
    W = static(Parent, Text, small, accent),
    wxStaticText:wrap(W, 420),
    W.

static(Parent, Text0, FontKey, ColourKey) ->
    T = theme(),
    Text = to_list(Text0),
    W = wxStaticText:new(Parent, ?wxID_ANY, Text),
    wxWindow:setForegroundColour(W, erm_theme:color(ColourKey, T)),
    wxWindow:setFont(W, erm_theme:font(FontKey, T)),
    W.

button(Parent, Id, Label) ->
    B = wxButton:new(Parent, Id, [{label, to_list(Label)}]),
    paint_button(B, false),
    B.

touch_button(Parent, Id, Label) ->
    B = button(Parent, Id, Label),
    wxWindow:setMinSize(B, {-1, 42}),
    B.

paint_button(B, Active) ->
    T = theme(),
    Bg =
        case Active of
            true -> button_active;
            false -> button
        end,
    wxWindow:setBackgroundColour(B, erm_theme:color(Bg, T)),
    wxWindow:setForegroundColour(B, erm_theme:color(text, T)),
    wxWindow:setFont(B, erm_theme:font(button, T)),
    ok.

add(Sizer, Window, Border) ->
    wxSizer:add(Sizer, Window, [
        {flag, ?wxLEFT bor ?wxRIGHT bor ?wxTOP},
        {border, Border}
    ]).

add_expand(Sizer, Window, Border) ->
    wxSizer:add(Sizer, Window, [
        {flag, ?wxEXPAND bor ?wxLEFT bor ?wxRIGHT bor ?wxTOP},
        {border, Border}
    ]).

spacer(Sizer, Px) ->
    wxSizer:addSpacer(Sizer, Px).

to_list(V) when is_binary(V) ->
    unicode:characters_to_list(V);
to_list(V) when is_list(V) ->
    V;
to_list(V) when is_atom(V) ->
    atom_to_list(V);
to_list(V) ->
    io_lib:format("~p", [V]).
