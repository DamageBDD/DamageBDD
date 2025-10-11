%%--------------------------------------------------------------------
%% erm_volume: Big finger-friendly volume control for PulseAudio/PipeWire
%%--------------------------------------------------------------------
-module(erm_volume).
-author("Steven Joseph <steven@damagebdd.com>").

-compile({no_auto_import, [min/2, max/2]}).

-include_lib("wx/include/wx.hrl").
-include_lib("kernel/include/logger.hrl").

-behaviour(wx_object).

-export([start/1, show/0, close/0]).
-export([
    init/1,
    terminate/2,
    code_change/3,
    handle_info/2,
    handle_call/3,
    handle_cast/2,
    handle_event/2
]).

-record(sink, {
    % backend id (string)
    id,
    % pretty name
    name,
    % wxSlider control
    slider,
    % wxTextCtrl showing %
    value_txt,
    % wxButton toggle mute
    mute_btn,
    % cached mute state
    muted = false
}).

-record(state, {
    parent,
    panel,
    config = [],
    font_label,
    font_button,
    % wpctl | pactl
    backend,
    % [#sink{}]
    sinks = []
}).

-define(FONT_BIG, 24).
-define(SLIDER_HEIGHT, 90).
-define(TIMER_REFRESH_MS, 1500).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start(Config) ->
    wx_object:start_link(?MODULE, Config, []).

show() ->
    case whereis(erm_volume) of
        undefined -> start([]);
        Pid -> wx_object:call(Pid, show)
    end.

close() ->
    case whereis(erm_volume) of
        undefined -> ok;
        Pid -> wx_object:call(Pid, close)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Config) ->
    Env = persistent_term:get(erm_wx_env),
    wx:set_env(Env),
    register(erm_volume, self()),

    Frame = wxFrame:new(
        wx:null(),
        ?wxID_ANY,
        "erm_volume",
        [{style, (?wxDEFAULT_FRAME_STYLE bor ?wxWANTS_CHARS) band (bnot ?wxSYSTEM_MENU)}]
    ),
    Panel = wxPanel:new(Frame, []),
    wxWindow:connect(Panel, paint, []),
    wxWindow:connect(Panel, activate, []),

    %% Fonts (reuse erm_fonts if present; fallback otherwise)
    FontLabel = safe_font(Frame, 11, 600),
    FontButton = safe_font(Frame, 10, 400),

    %% Title
    Title = wxStaticText:new(Panel, ?wxID_ANY, "Audio Output (Sink) Volumes", [
        {style, ?wxALIGN_CENTER}
    ]),
    wxStaticText:setFont(Title, erm_font_bold(Frame, ?FONT_BIG)),

    Root = wxBoxSizer:new(?wxVERTICAL),
    wxSizer:add(Root, Title, [{proportion, 0}, {flag, ?wxEXPAND bor ?wxALL}, {border, 8}]),

    Scrolled = wxScrolledWindow:new(Panel, ?wxID_ANY, [{style, ?wxVSCROLL bor ?wxTAB_TRAVERSAL}]),
    wxScrolledWindow:setScrollRate(Scrolled, 5, 10),
    ListSizer = wxBoxSizer:new(?wxVERTICAL),

    wxSizer:add(Root, Scrolled, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 8}]),
    wxWindow:setSizer(Scrolled, ListSizer),
    wxWindow:setSizerAndFit(Panel, Root),

    set_window_size_and_position(Frame),

    Backend = detect_backend(),
    Sinks0 = fetch_sinks(Backend),
    Sinks = build_sink_rows(Scrolled, ListSizer, Sinks0, FontLabel, FontButton),

    wxFrame:show(Frame),

    %% periodic refresh via send_after
    _ = erlang:send_after(?TIMER_REFRESH_MS, self(), refresh),

    {Frame, #state{
        parent = Frame,
        panel = Panel,
        config = Config,
        font_label = FontLabel,
        font_button = FontButton,
        backend = Backend,
        sinks = Sinks
    }}.

terminate(_Reason, #state{parent = Frame}) ->
    catch wxFrame:destroy(Frame),
    wx:destroy().

code_change(_, _, State) -> {stop, ignore, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Helpers

safe_font(Frame, Size, Weight) ->
    case erlang:function_exported(erm_fonts, get_font, 3) of
        true ->
            erm_fonts:get_font(Frame, Size, Weight);
        false ->
            wxFont:new(
                Size,
                ?wxFONTFAMILY_DEFAULT,
                ?wxFONTSTYLE_NORMAL,
                if
                    Weight >= 600 -> ?wxFONTWEIGHT_BOLD;
                    true -> ?wxFONTWEIGHT_NORMAL
                end
            )
    end.

erm_font_bold(Frame, Size) ->
    case erlang:function_exported(erm_fonts, get_font, 3) of
        true -> erm_fonts:get_font(Frame, Size, 700);
        false -> wxFont:new(Size, ?wxFONTFAMILY_DEFAULT, ?wxFONTSTYLE_NORMAL, ?wxFONTWEIGHT_BOLD)
    end.

set_window_size_and_position(Frame) ->
    Display = wxDisplay:new(),
    {_, _, W, H} = wxDisplay:getGeometry(Display),
    WinW = erlang:round(W * 0.6),
    WinH = erlang:round(H * 0.6),
    wxFrame:setSize(Frame, {0, H - WinH, WinW, WinH}),
    wxFrame:center(Frame),
    ok.

detect_backend() ->
    case os:find_executable("wpctl") of
        false ->
            case os:find_executable("pactl") of
                false -> pactl;
                _ -> pactl
            end;
        _ ->
            wpctl
    end.

%% Fetch sinks list with id, name, pct [0..100], muted boolean
fetch_sinks(wpctl) ->
    Out = os:cmd("wpctl status 2>/dev/null"),
    parse_wpctl_status(Out);
fetch_sinks(pactl) ->
    case os:cmd("pactl -f json list sinks 2>/dev/null") of
        "null\n" -> parse_pactl_text(os:cmd("pactl list sinks 2>/dev/null"));
        Json -> parse_pactl_json(Json)
    end.

parse_wpctl_status(Text) ->
    Lines = string:split(Text, "\n", all),
    parse_wpctl_lines(Lines, false, []).

parse_wpctl_lines([H | T], InOut, Acc) ->
    case {InOut, H} of
        {false, Line} ->
            case string:find(Line, "Output Devices:") of
                nomatch -> parse_wpctl_lines(T, false, Acc);
                _ -> parse_wpctl_lines(T, true, Acc)
            end;
        {true, Line} ->
            Trim = string:trim(Line),
            case Trim =:= "" of
                true ->
                    parse_wpctl_lines(T, false, Acc);
                false ->
                    %% Example: "  48. Built-in Audio Analog Stereo [vol: 0.35 (35%) MUTE]"
                    case
                        re:run(
                            Line,
                            "^[\\s]*([0-9]+)\\.[\\s]+(.+?)\\s*\\[vol:\\s*([0-9.]+).*?(\\d+)%\\)?(.*)\\]$",
                            [{capture, all, list}]
                        )
                    of
                        {match, [_, Id, Name, _F, Pct, Tail]} ->
                            Muted =
                                (string:find(Tail, "MUTED") =/= nomatch) orelse
                                    (string:find(Tail, "MUTE") =/= nomatch),
                            parse_wpctl_lines(T, true, [
                                {Id, Name, list_to_integer(Pct), Muted} | Acc
                            ]);
                        nomatch ->
                            parse_wpctl_lines(T, true, Acc)
                    end
            end
    end;
parse_wpctl_lines([], _InOut, Acc) ->
    lists:reverse(Acc).

parse_pactl_json(Json) ->
    case code:ensure_loaded(jsx) of
        {module, jsx} ->
            try
                L = jsx:decode(Json, [return_maps]),
                lists:map(
                    fun(M) ->
                        Id = maps:get(index, M),
                        Name =
                            case maps:get(description, M, undefined) of
                                undefined -> maps:get(name, M);
                                D -> D
                            end,
                        %% grab first channel's value_percent if present
                        Vol = maps:get(volume, M, #{}),
                        Pct = volume_map_to_pct(Vol),
                        Muted = maps:get(mute, M, false),
                        {integer_to_list(Id), Name, Pct, Muted}
                    end,
                    L
                )
            catch
                _:_ ->
                    parse_pactl_text(os:cmd("pactl list sinks 2>/dev/null"))
            end;
        _ ->
            parse_pactl_text(os:cmd("pactl list sinks 2>/dev/null"))
    end.

volume_map_to_pct(Map) ->
    %% Map can be like #{ <<"front-left">> => #{<<"value_percent">> := <<"35%">>}, ...}
    Vals = [pct_to_int(P) || #{<<"value_percent">> := P} <- maps:values(Map)],
    case Vals of
        [] -> 0;
        _ -> lists:max(Vals)
    end.

pct_to_int(S) when is_list(S) ->
    case re:run(S, "([0-9]+)%", [{capture, [1], list}]) of
        {match, [Num]} -> list_to_integer(Num);
        _ -> 0
    end;
pct_to_int(Bin) when is_binary(Bin) ->
    pct_to_int(binary_to_list(Bin));
pct_to_int(_) ->
    0.

parse_pactl_text(Text) ->
    Lines = string:split(Text, "\n", all),
    parse_pactl_blocks(Lines, undefined, #{id => "", name => "", pct => 0, muted => false}, []).

parse_pactl_blocks([H | T], CurId, Cur, Acc) ->
    case re:run(H, "^Sink #([0-9]+)", [{capture, [1], list}]) of
        {match, [Id]} ->
            Acc1 =
                case CurId of
                    undefined ->
                        Acc;
                    _ ->
                        [
                            {
                                maps:get(id, Cur),
                                maps:get(name, Cur),
                                maps:get(pct, Cur),
                                maps:get(muted, Cur)
                            }
                            | Acc
                        ]
                end,
            parse_pactl_blocks(T, Id, #{id => Id, name => "", pct => 0, muted => false}, Acc1);
        nomatch ->
            Cur1 =
                case string:find(H, "Description:") of
                    nomatch ->
                        case string:find(H, "Name:") of
                            nomatch ->
                                case string:find(H, "Volume:") of
                                    nomatch ->
                                        case string:find(H, "Mute:") of
                                            nomatch -> Cur;
                                            _ -> Cur#{muted => (string:find(H, "yes") =/= nomatch)}
                                        end;
                                    _ ->
                                        Cur#{pct => pct_to_int(H)}
                                end;
                            _ ->
                                Cur#{
                                    name => string:trim(
                                        string:substr(H, string:length("Name:") + 1)
                                    )
                                }
                        end;
                    _ ->
                        Cur#{
                            name => string:trim(string:substr(H, string:length("Description:") + 1))
                        }
                end,
            parse_pactl_blocks(T, CurId, Cur1, Acc)
    end;
parse_pactl_blocks([], CurId, Cur, Acc) ->
    Acc1 =
        case CurId of
            undefined ->
                Acc;
            _ ->
                [
                    {
                        maps:get(id, Cur),
                        maps:get(name, Cur),
                        maps:get(pct, Cur),
                        maps:get(muted, Cur)
                    }
                    | Acc
                ]
        end,
    lists:reverse(Acc1).

build_sink_rows(Parent, ListSizer, SinkTuples, FontLabel, FontButton) ->
    lists:map(
        fun({Id, Name, Pct, Muted}) ->
            Row = wxBoxSizer:new(?wxVERTICAL),

            NameTxt = wxStaticText:new(Parent, ?wxID_ANY, iolist_to_binary([Name, " (", Id, ")"])),
            wxStaticText:setFont(NameTxt, FontLabel),
            wxSizer:add(Row, NameTxt, [{flag, ?wxEXPAND bor ?wxALL}, {border, 6}]),

            Line = wxBoxSizer:new(?wxHORIZONTAL),

            Dec = wxButton:new(Parent, ?wxID_ANY, [{label, "-"}]),
            wxButton:setFont(Dec, FontButton),
            wxSizer:add(Line, Dec, [
                {proportion, 0}, {flag, ?wxALL bor ?wxALIGN_CENTER_VERTICAL}, {border, 4}
            ]),

            Slider = wxSlider:new(Parent, ?wxID_ANY, Pct, 0, 150, [
                {style, ?wxSL_HORIZONTAL bor ?wxSL_AUTOTICKS}
            ]),
            wxSlider:setPageSize(Slider, 5),
            wxSlider:setLineSize(Slider, 2),
            wxWindow:setMinSize(Slider, {-1, ?SLIDER_HEIGHT}),
            wxSizer:add(Line, Slider, [{proportion, 1}, {flag, ?wxEXPAND bor ?wxALL}, {border, 4}]),

            Inc = wxButton:new(Parent, ?wxID_ANY, [{label, "+"}]),
            wxButton:setFont(Inc, FontButton),
            wxSizer:add(Line, Inc, [
                {proportion, 0}, {flag, ?wxALL bor ?wxALIGN_CENTER_VERTICAL}, {border, 4}
            ]),

            ValTxt = wxTextCtrl:new(Parent, ?wxID_ANY, [
                {value, integer_to_list(Pct) ++ "%"}, {style, ?wxTE_CENTER}
            ]),
            wxTextCtrl:setEditable(ValTxt, false),
            wxSizer:add(Line, ValTxt, [
                {proportion, 0}, {flag, ?wxALL bor ?wxALIGN_CENTER_VERTICAL}, {border, 4}
            ]),

            MuteLbl =
                if
                    Muted -> "Unmute";
                    true -> "Mute"
                end,
            MuteBtn = wxButton:new(Parent, ?wxID_ANY, [{label, MuteLbl}]),
            wxButton:setFont(MuteBtn, FontButton),
            wxSizer:add(Line, MuteBtn, [
                {proportion, 0}, {flag, ?wxALL bor ?wxALIGN_CENTER_VERTICAL}, {border, 4}
            ]),

            wxSizer:add(Row, Line, [{flag, ?wxEXPAND}]),
            wxSizer:add(ListSizer, Row, [{flag, ?wxEXPAND bor ?wxALL}, {border, 6}]),

            %% Connect events (attach userData on the top-level #wx wrapper)
            wxSlider:connect(Slider, command_slider_updated, [{userData, {sink, Id}}]),
            wxButton:connect(Inc, command_button_clicked, [{userData, {inc, Id}}]),
            wxButton:connect(Dec, command_button_clicked, [{userData, {dec, Id}}]),
            wxButton:connect(MuteBtn, command_button_clicked, [{userData, {mute, Id}}]),

            #sink{
                id = Id,
                name = Name,
                slider = Slider,
                value_txt = ValTxt,
                mute_btn = MuteBtn,
                muted = Muted
            }
        end,
        SinkTuples
    ).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Events

handle_event(
    #wx{
        userData = {sink, Id},
        event = #wxCommand{type = command_slider_updated, commandInt = Value}
    },
    State = #state{backend = B, sinks = Sinks}
) ->
    set_volume(B, Id, Value),
    update_value_text(Id, Value, Sinks),
    {noreply, State};
handle_event(
    #wx{
        userData = {inc, Id},
        event = #wxCommand{type = command_button_clicked}
    },
    State = #state{sinks = Sinks, backend = B}
) ->
    adjust_slider(Id, +2, Sinks, B),
    {noreply, State};
handle_event(
    #wx{
        userData = {dec, Id},
        event = #wxCommand{type = command_button_clicked}
    },
    State = #state{sinks = Sinks, backend = B}
) ->
    adjust_slider(Id, -2, Sinks, B),
    {noreply, State};
handle_event(
    #wx{
        userData = {mute, Id},
        event = #wxCommand{type = command_button_clicked}
    },
    State = #state{backend = B, sinks = Sinks}
) ->
    {ok, Muted1} = toggle_mute(B, Id),
    update_mute_button(Id, Muted1, Sinks),
    {noreply, State};
handle_event(Ev = #wx{}, State) ->
    ?LOG_DEBUG("Unhandled event: ~p", [Ev]),
    {noreply, State}.

handle_info(refresh, State = #state{backend = B, sinks = Sinks}) ->
    Fresh = fetch_sinks(B),
    refresh_ui_from_backend(Fresh, Sinks),
    _ = erlang:send_after(?TIMER_REFRESH_MS, self(), refresh),
    {noreply, State};
handle_info(Msg, State) ->
    ?LOG_DEBUG("Info: ~p", [Msg]),
    {noreply, State}.

handle_call(show, _From, State = #state{parent = Frame}) ->
    wxFrame:show(Frame),
    {reply, ok, State};
handle_call(close, _From, State = #state{parent = Frame}) ->
    wxFrame:hide(Frame),
    {reply, ok, State};
handle_call(_Req, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Backend ops

set_volume(wpctl, Id, Pct) ->
    Cmd = io_lib:format(
        "wpctl set-volume ~s ~.2f --limit 1.50 >/dev/null 2>&1",
        [Id, erlang:min(1.5, erlang:max(0.0, Pct / 100.0))]
    ),
    os:cmd(lists:flatten(Cmd)),
    ok;
set_volume(pactl, Id, Pct) ->
    Cmd = io_lib:format("pactl set-sink-volume ~s ~B%% >/dev/null 2>&1", [Id, Pct]),
    os:cmd(lists:flatten(Cmd)),
    ok.

toggle_mute(wpctl, Id) ->
    os:cmd(io_lib:format("wpctl set-mute ~s toggle >/dev/null 2>&1", [Id])),
    Fresh = fetch_sinks(wpctl),
    {ok, find_muted(Id, Fresh)};
toggle_mute(pactl, Id) ->
    os:cmd(io_lib:format("pactl set-sink-mute ~s toggle >/dev/null 2>&1", [Id])),
    Fresh = fetch_sinks(pactl),
    {ok, find_muted(Id, Fresh)}.

find_muted(Id, Tuples) ->
    case lists:keyfind(Id, 1, Tuples) of
        {_, _, _, Muted} -> Muted;
        false -> false
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% UI sync helpers

adjust_slider(Id, Delta, Sinks, Backend) ->
    case lists:keyfind(Id, #sink.id, Sinks) of
        #sink{slider = Sl} ->
            Cur = wxSlider:getValue(Sl),
            New = erlang:min(150, erlang:max(0, Cur + Delta)),
            wxSlider:setValue(Sl, New),
            update_value_text(Id, New, Sinks),
            set_volume(Backend, Id, New),
            ok;
        false ->
            ok
    end.

update_value_text(Id, Pct, Sinks) ->
    case lists:keyfind(Id, #sink.id, Sinks) of
        #sink{value_txt = Txt} ->
            wxTextCtrl:setValue(Txt, io_lib:format("~B%", [Pct]));
        false ->
            ok
    end.

update_mute_button(Id, Muted, Sinks) ->
    case lists:keyfind(Id, #sink.id, Sinks) of
        #sink{mute_btn = Btn} ->
            wxButton:setLabel(
                Btn,
                if
                    Muted -> "Unmute";
                    true -> "Mute"
                end
            );
        false ->
            ok
    end.

refresh_ui_from_backend(Tuples, Sinks) ->
    lists:foreach(
        fun(#sink{id = Id, slider = Sl, value_txt = Txt, mute_btn = Btn}) ->
            case lists:keyfind(Id, 1, Tuples) of
                {_, _, Pct, Muted} ->
                    wxSlider:setValue(Sl, Pct),
                    wxTextCtrl:setValue(Txt, io_lib:format("~B%", [Pct])),
                    wxButton:setLabel(
                        Btn,
                        if
                            Muted -> "Unmute";
                            true -> "Mute"
                        end
                    );
                false ->
                    ok
            end
        end,
        Sinks
    ).
