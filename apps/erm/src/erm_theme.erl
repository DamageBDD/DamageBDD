-module(erm_theme).
-compile({no_auto_import, [get/1]}).

-include_lib("wx/include/wx.hrl").

-export([
    current/0,
    set_current/1,
    names/0,
    get/1,
    color/2,
    font/2,
    spacing/2
]).

-define(APP, erm).

names() ->
    [damage_dark, amber_terminal, clean_light].

current() ->
    case persistent_term:get({?APP, theme}, undefined) of
        undefined -> damage_dark;
        Theme -> Theme
    end.

set_current(Name) ->
    case lists:member(Name, names()) of
        true ->
            persistent_term:put({?APP, theme}, Name),
            ok;
        false ->
            {error, {unknown_theme, Name}}
    end.

get(Name) ->
    maps:get(Name, themes()).

color(Key, ThemeName) ->
    %% wxErlang colour APIs accept {R,G,B} tuples directly.
    %% wxColour:new/3 is not exported on some Erlang/OTP wx builds.
    Theme = get(ThemeName),
    maps:get(Key, maps:get(colors, Theme)).

font(Key, ThemeName) ->
    Theme = get(ThemeName),
    Spec = maps:get(Key, maps:get(fonts, Theme)),
    wxFont:new(
        maps:get(size, Spec),
        maps:get(family, Spec, ?wxFONTFAMILY_DEFAULT),
        maps:get(style, Spec, ?wxFONTSTYLE_NORMAL),
        maps:get(weight, Spec, ?wxFONTWEIGHT_NORMAL)
    ).

spacing(Key, ThemeName) ->
    Theme = get(ThemeName),
    maps:get(Key, maps:get(spacing, Theme)).

themes() ->
    #{
        damage_dark => #{
            colors => #{
                bg => {32, 37, 41},
                surface => {40, 46, 52},
                card => {48, 55, 62},
                card_alt => {55, 63, 71},
                border => {82, 93, 104},
                text => {236, 241, 245},
                muted => {170, 181, 190},
                accent => {255, 196, 60},
                good => {90, 220, 150},
                danger => {240, 105, 105},
                button => {58, 67, 76},
                button_active => {75, 87, 98}
            },
            fonts => #{
                title => #{size => 14, weight => ?wxFONTWEIGHT_BOLD},
                section => #{size => 12, weight => ?wxFONTWEIGHT_BOLD},
                body => #{size => 10},
                small => #{size => 9},
                button => #{size => 10, weight => ?wxFONTWEIGHT_BOLD}
            },
            spacing => #{xs => 4, sm => 8, md => 12, lg => 16, xl => 24}
        },

        amber_terminal => #{
            colors => #{
                bg => {14, 15, 15},
                surface => {22, 24, 24},
                card => {28, 31, 31},
                card_alt => {36, 39, 39},
                border => {105, 90, 45},
                text => {245, 229, 170},
                muted => {180, 158, 100},
                accent => {255, 174, 48},
                good => {125, 240, 145},
                danger => {255, 95, 95},
                button => {38, 40, 40},
                button_active => {70, 58, 30}
            },
            fonts => #{
                title => #{size => 14, weight => ?wxFONTWEIGHT_BOLD},
                section => #{size => 12, weight => ?wxFONTWEIGHT_BOLD},
                body => #{size => 10, family => ?wxFONTFAMILY_TELETYPE},
                small => #{size => 9, family => ?wxFONTFAMILY_TELETYPE},
                button => #{size => 10, weight => ?wxFONTWEIGHT_BOLD}
            },
            spacing => #{xs => 4, sm => 8, md => 12, lg => 16, xl => 24}
        },

        clean_light => #{
            colors => #{
                bg => {244, 246, 248},
                surface => {255, 255, 255},
                card => {255, 255, 255},
                card_alt => {246, 248, 250},
                border => {205, 213, 221},
                text => {24, 31, 38},
                muted => {86, 99, 112},
                accent => {220, 145, 20},
                good => {20, 145, 90},
                danger => {200, 65, 65},
                button => {235, 239, 243},
                button_active => {220, 229, 238}
            },
            fonts => #{
                title => #{size => 14, weight => ?wxFONTWEIGHT_BOLD},
                section => #{size => 12, weight => ?wxFONTWEIGHT_BOLD},
                body => #{size => 10},
                small => #{size => 9},
                button => #{size => 10, weight => ?wxFONTWEIGHT_BOLD}
            },
            spacing => #{xs => 4, sm => 8, md => 12, lg => 16, xl => 24}
        }
    }.
