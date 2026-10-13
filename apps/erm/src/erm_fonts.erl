-module(erm_fonts).

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").

-export([get_font/3]).

get_font(Frame, Min, Max) ->
    %% Get the size of the frame
    {Width, _Height} = wxWindow:getSize(Frame),
    %% Calculate a font size relative to the window dimensions
    FontSize = max(Min, min(Max, Width div 10)),
    ?LOG_DEBUG("Fontzize ~p width ~p", [FontSize, Width]),
    %% Create a new font
    wxFont:new(FontSize, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD).
