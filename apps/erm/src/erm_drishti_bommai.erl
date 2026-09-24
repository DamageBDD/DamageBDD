%%%-------------------------------------------------------------------
%%% Drishti Bommai desktop toy for erm.
%%%
%%% Physics belongs in Erlang. GTK is only the renderer.
%%%-------------------------------------------------------------------
-module(erm_drishti_bommai).
-behaviour(gen_server).

-export([
    start/0,
    start/1,
    start_link/0,
    start_link/1,
    display_default/0,
    default_asset/0,
    image_dimensions/0,
    image_dimensions/1,
    stop/0,
    show/0,
    hide/0,
    kick/1,
    kick/2
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(DEFAULT_READY_TIMEOUT, 15000).

-record(state, {
    window,
    asset,

    width = 420,
    height = 520,
    image_width = 160,
    image_height = 220,

    %% Horizontal rest-space on either side of the moving body.
    base = 120,

    %% Pendulum state, expressed as horizontal displacement.
    x = 0.0,
    velocity = 0.0,
    time = 0.0,

    %% Physics.
    spring = 6.5,
    damping = 1.45,
    ambient = 3.5,

    tick_ms = 16,
    timer = undefined
}).

%%%===================================================================
%%% API
%%%===================================================================

%% Display the packaged image from priv/images/drishti_bommai.png.
%%
%% The PNG dimensions are read directly from the IHDR chunk. The default view
%% preserves the native aspect ratio and scales down, never up, to fit inside
%% max_image_width/max_image_height. No ImageMagick, wxImage or shell helper is
%% required.
display_default() ->
    start().

%% Shell-friendly, unlinked entry point. The default asset is resolved via
%% code:priv_dir(erm), so it works from rebar3 and packaged releases.
start() ->
    start([]).

start(UserOpts0) when is_list(UserOpts0); is_map(UserOpts0) ->
    case whereis(?SERVER) of
        Pid when is_pid(Pid) ->
            show(),
            {ok, Pid};
        undefined ->
            case prepare_options(UserOpts0) of
                {ok, Opts} ->
                    %% Do not create a gen_server just to have init/1 fail and
                    %% emit a SASL crash report when GTK is unavailable.
                    case ensure_gtknode4_ready(Opts) of
                        ok -> start_server(Opts);
                        {error, _Reason} = Error -> Error
                    end;
                {error, _Reason} = Error ->
                    Error
            end
    end.

start_server(Opts) ->
    case gen_server:start({local, ?SERVER}, ?MODULE, Opts, []) of
        {ok, Pid} ->
            show(),
            {ok, Pid};
        {error, {already_started, Pid}} ->
            show(),
            {ok, Pid};
        Error ->
            Error
    end.

ensure_gtknode4_ready(Opts) ->
    _ = maybe_start_gtknode4(),
    Timeout = maps:get(ready_timeout, Opts, ?DEFAULT_READY_TIMEOUT),
    case catch gtknode4:await_ready(Timeout) of
        ok ->
            ok;
        {error, Reason} ->
            {error, {gtknode4_not_ready, gtknode4_diagnostics(Reason)}};
        {'EXIT', Reason} ->
            {error, {gtknode4_not_ready, gtknode4_diagnostics({exit, Reason})}};
        Other ->
            {error, {gtknode4_not_ready, gtknode4_diagnostics(Other)}}
    end.

maybe_start_gtknode4() ->
    case whereis(gtknode4_sup) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
            case whereis(erm_sup) of
                Pid when is_pid(Pid) ->
                    case catch erm_sup:start_gtknode4() of
                        {ok, _} -> ok;
                        {error, already_present} -> ok;
                        {error, {already_started, _}} -> ok;
                        {error, {unmanaged_process_already_started, _}} -> ok;
                        _ -> ok
                    end;
                undefined ->
                    ok
            end
    end.

gtknode4_diagnostics(AwaitReason) ->
    #{
        await => AwaitReason,
        display_session => safe_status(erm_display),
        controller => safe_status(gtknode4),
        port => safe_status(gtknode4_port),
        display => os:getenv("DISPLAY"),
        wayland_display => os:getenv("WAYLAND_DISPLAY"),
        xauthority => os:getenv("XAUTHORITY")
    }.

safe_status(Module) ->
    try Module:status() of
        Status -> Status
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% Supervisor entry points.
start_link() ->
    start_link([]).

start_link(UserOpts0) when is_list(UserOpts0); is_map(UserOpts0) ->
    case prepare_options(UserOpts0) of
        {ok, Opts} ->
            gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []);
        {error, _Reason} = Error ->
            Error
    end.

stop() ->
    case whereis(?SERVER) of
        undefined ->
            ok;
        _Pid ->
            gen_server:stop(?SERVER)
    end.

show() ->
    gen_server:cast(?SERVER, show).

hide() ->
    gen_server:cast(?SERVER, hide).

kick(left) ->
    kick(left, 300.0);
kick(right) ->
    kick(right, 300.0).

kick(Direction, Strength)
        when (Direction =:= left orelse Direction =:= right),
             is_number(Strength) ->
    gen_server:cast(?SERVER, {kick, Direction, float(Strength)}).

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),

    ReadyTimeout = maps:get(ready_timeout, Opts, ?DEFAULT_READY_TIMEOUT),
    case gtknode4:await_ready(ReadyTimeout) of
        ok ->
            init_ui(Opts);
        Error ->
            {stop, {gtknode4_not_ready, Error}}
    end.

init_ui(Opts) ->
    Width = maps:get(width, Opts, 420),
    Height = maps:get(height, Opts, 520),
    ImageWidth = maps:get(image_width, Opts, 160),
    ImageHeight = maps:get(image_height, Opts, 220),
    TickMs = maps:get(tick_ms, Opts, 16),

    Asset0 = maps:get(asset, Opts),
    Asset = filename:absname(Asset0),

    case filelib:is_regular(Asset) of
        false ->
            {stop, {drishti_asset_not_found, Asset}};
        true ->
            Base = max(16, (Width - ImageWidth) div 2),

            ok = gtkgs:set_stylesheet(
                drishti_bommai,
                stylesheet()
            ),

            Server = gtkgs:server(),

            Tree = [
                {window, drishti_window,
                    [
                        {title, "Drishti Bommai"},
                        {width, Width},
                        {height, Height},
                        {class, "drishti-window"}
                    ],
                    [
                        %% Keep exactly one root child below the native
                        %% GtkWindow.
                        {frame, drishti_root,
                            [
                                {orient, vertical},
                                {spacing, 0},
                                {expand, true},
                                {class, "drishti-root"}
                            ],
                            [
                                {label, drishti_anchor,
                                    [
                                        {label, "●"},
                                        {align, center},
                                        {class, "drishti-anchor"}
                                    ]},

                                {frame, drishti_sway_row,
                                    [
                                        {orient, horizontal},
                                        {spacing, 0},
                                        {hexpand, true},
                                        {vexpand, true},
                                        {class, "drishti-stage"}
                                    ],
                                    [
                                        {label, drishti_left_space,
                                            [
                                                {label, ""},
                                                {width, Base}
                                            ]},

                                        {frame, drishti_body,
                                            [
                                                {orient, vertical},
                                                {width, ImageWidth},
                                                {valign, start},
                                                {class, "drishti-body"}
                                            ],
                                            [
                                                {label, drishti_chain,
                                                    [
                                                        {label, "│\n●\n●"},
                                                        {align, center},
                                                        {class, "drishti-chain"}
                                                    ]},

                                                {picture, drishti_picture,
                                                    [
                                                        {file, Asset},
                                                        {width, ImageWidth},
                                                        {height, ImageHeight},
                                                        {class, "drishti-picture"}
                                                    ]}
                                            ]},

                                        {label, drishti_right_space,
                                            [
                                                {label, ""},
                                                {width, Base}
                                            ]}
                                    ]}
                            ]}
                    ]}
            ],

            case gtkgs:create_tree(Server, Tree) of
                {ok, [Window]} ->
                    ok = gtkgs:config(Window, {map, true}),
                    ok = gtkgs:sync(),

                    Timer = erlang:send_after(TickMs, self(), tick),

                    {ok, #state{
                        window = Window,
                        asset = Asset,
                        width = Width,
                        height = Height,
                        image_width = ImageWidth,
                        image_height = ImageHeight,
                        base = Base,
                        tick_ms = TickMs,
                        timer = Timer,
                        spring = maps:get(spring, Opts, 6.5),
                        damping = maps:get(damping, Opts, 1.45),
                        ambient = maps:get(ambient, Opts, 3.5)
                    }};

                Error ->
                    {stop, {drishti_ui_failed, Error}}
            end
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(show, State) ->
    _ = gtkgs:config(drishti_window, {map, true}),
    {noreply, State};

handle_cast(hide, State) ->
    _ = gtkgs:config(drishti_window, {map, false}),
    {noreply, State};

handle_cast({kick, left, Strength}, State) ->
    {noreply, State#state{
        velocity = State#state.velocity - Strength
    }};

handle_cast({kick, right, Strength}, State) ->
    {noreply, State#state{
        velocity = State#state.velocity + Strength
    }};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(tick, State0) ->
    State1 = physics_step(State0),
    Timer = erlang:send_after(State1#state.tick_ms, self(), tick),
    {noreply, State1#state{timer = Timer}};

%% gtknode4 currently hides the window on close.
handle_info({gtkgs, drishti_window, hidden, _Data, _Args}, State) ->
    {stop, normal, State};

handle_info({gtkgs, drishti_window, destroy, _Data, _Args}, State) ->
    {stop, normal, State};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_timer(State#state.timer),
    catch gtkgs:destroy(drishti_window),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Physics
%%%===================================================================

physics_step(State = #state{
    x = X,
    velocity = V,
    time = T,
    spring = K,
    damping = D,
    ambient = Ambient,
    tick_ms = TickMs,
    base = Base
}) ->
    Dt = TickMs / 1000.0,

    %% Light irregular "alive" movement while at rest.
    Drive =
        Ambient *
        (
            math:sin(T * 1.7) +
            0.35 * math:sin(T * 3.13)
        ),

    %% Damped harmonic oscillator.
    Acceleration =
        -(K * X) -
        (D * V) +
        Drive,

    V1 = V + Acceleration * Dt,
    X0 = X + V1 * Dt,

    %% Never allow either spacer to collapse.
    Limit = max(8, Base - 8),
    X1 = clamp(X0, -Limit, Limit),

    Shift = round(X1),

    LeftWidth = max(1, Base + Shift),
    RightWidth = max(1, Base - Shift),

    _ = gtkgs:config(
        drishti_left_space,
        {width, LeftWidth}
    ),
    _ = gtkgs:config(
        drishti_right_space,
        {width, RightWidth}
    ),

    State#state{
        x = X1,
        velocity = V1,
        time = T + Dt
    }.

clamp(Value, Min, _Max) when Value < Min ->
    Min;
clamp(Value, _Min, Max) when Value > Max ->
    Max;
clamp(Value, _Min, _Max) ->
    Value.

cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    ok.

%% Resolve the asset through the application priv directory so the same
%% code works from rebar3 shell and from a packaged/release installation.
default_asset() ->
    case code:priv_dir(erm) of
        Dir when is_list(Dir) ->
            filename:join([Dir, "images", "drishti_bommai.png"]);
        {error, _Reason} ->
            %% Helpful fallback while running directly from a source tree.
            filename:absname(
                filename:join(["apps", "erm", "priv", "images",
                               "drishti_bommai.png"])
            )
    end.

%% Native dimensions of the packaged image.
image_dimensions() ->
    image_dimensions(default_asset()).

%% Read a PNG's dimensions without decoding the image. Width and height live in
%% the mandatory IHDR chunk immediately after the eight-byte PNG signature.
image_dimensions(Path0) ->
    Path = filename:absname(to_list(Path0)),
    case file:open(Path, [read, binary]) of
        {ok, Io} ->
            Result =
                case file:read(Io, 24) of
                    {ok, <<
                        137, 80, 78, 71, 13, 10, 26, 10,
                        0, 0, 0, 13, "IHDR",
                        Width:32/unsigned-big-integer,
                        Height:32/unsigned-big-integer
                    >>} when Width > 0, Height > 0 ->
                        {ok, {Width, Height}};
                    {ok, _Other} ->
                        {error, {unsupported_image_format, Path}};
                    eof ->
                        {error, {truncated_image, Path}};
                    {error, Reason} ->
                        {error, {image_read_failed, Path, Reason}}
                end,
            _ = file:close(Io),
            Result;
        {error, Reason} ->
            {error, {image_open_failed, Path, Reason}}
    end.

prepare_options(UserOpts0) ->
    UserOpts = options_map(UserOpts0),
    Asset = filename:absname(to_list(maps:get(asset, UserOpts, default_asset()))),
    case filelib:is_regular(Asset) of
        false ->
            {error, {drishti_asset_not_found, Asset}};
        true ->
            case image_dimensions(Asset) of
                {ok, {NativeWidth, NativeHeight}} ->
                    Defaults = #{
                        asset => Asset,
                        ready_timeout => ?DEFAULT_READY_TIMEOUT,
                        fit => true,
                        max_image_width => 420,
                        max_image_height => 560,
                        window_padding_x => 48,
                        window_padding_y => 96
                    },
                    Opts0 = maps:merge(Defaults, UserOpts),
                    case resolve_image_size(NativeWidth, NativeHeight, Opts0) of
                        {ok, {ImageWidth, ImageHeight}} ->
                            PaddingX = positive_int(maps:get(window_padding_x, Opts0), 48),
                            PaddingY = positive_int(maps:get(window_padding_y, Opts0), 96),
                            Width = positive_int(
                                maps:get(width, UserOpts, ImageWidth + PaddingX),
                                ImageWidth + PaddingX
                            ),
                            Height = positive_int(
                                maps:get(height, UserOpts, ImageHeight + PaddingY),
                                ImageHeight + PaddingY
                            ),
                            {ok, Opts0#{
                                asset => Asset,
                                native_image_width => NativeWidth,
                                native_image_height => NativeHeight,
                                image_width => ImageWidth,
                                image_height => ImageHeight,
                                width => Width,
                                height => Height
                            }};
                        {error, _Reason} = Error ->
                            Error
                    end;
                {error, _Reason} = Error ->
                    Error
            end
    end.

resolve_image_size(NativeWidth, NativeHeight, Opts) ->
    WidthOpt = maps:get(image_width, Opts, undefined),
    HeightOpt = maps:get(image_height, Opts, undefined),
    case {WidthOpt, HeightOpt} of
        {Width, Height} when is_integer(Width), Width > 0,
                             is_integer(Height), Height > 0 ->
            {ok, {Width, Height}};
        {Width, undefined} when is_integer(Width), Width > 0 ->
            Height = max(1, round(NativeHeight * (Width / NativeWidth))),
            {ok, {Width, Height}};
        {undefined, Height} when is_integer(Height), Height > 0 ->
            Width = max(1, round(NativeWidth * (Height / NativeHeight))),
            {ok, {Width, Height}};
        {undefined, undefined} ->
            case maps:get(fit, Opts, true) of
                false ->
                    {ok, {NativeWidth, NativeHeight}};
                true ->
                    MaxWidth = positive_int(maps:get(max_image_width, Opts, 420), 420),
                    MaxHeight = positive_int(maps:get(max_image_height, Opts, 560), 560),
                    {ok, fit_dimensions(NativeWidth, NativeHeight, MaxWidth, MaxHeight)};
                Invalid ->
                    {error, {invalid_fit_option, Invalid}}
            end;
        _ ->
            {error, {invalid_image_dimensions, WidthOpt, HeightOpt}}
    end.

fit_dimensions(Width, Height, MaxWidth, MaxHeight) ->
    Scale = lists:min([1.0, MaxWidth / Width, MaxHeight / Height]),
    {
        max(1, round(Width * Scale)),
        max(1, round(Height * Scale))
    }.

positive_int(Value, _Default) when is_integer(Value), Value > 0 ->
    Value;
positive_int(_Value, Default) ->
    Default.

options_map(Map) when is_map(Map) ->
    Map;
options_map(List) when is_list(List) ->
    maps:from_list(List).

to_list(Value) when is_list(Value) ->
    Value;
to_list(Value) when is_binary(Value) ->
    unicode:characters_to_list(Value).

%%%===================================================================
%%% GTK CSS
%%%===================================================================

stylesheet() ->
    [
        ".drishti-window {",
        "  background-color: #101116;",
        "}",

        ".drishti-root {",
        "  background-color: transparent;",
        "}",

        ".drishti-stage {",
        "  background-color: transparent;",
        "}",

        ".drishti-anchor {",
        "  color: #e5b83c;",
        "  font-size: 20px;",
        "  font-weight: bold;",
        "}",

        ".drishti-chain {",
        "  color: #dfaa24;",
        "  font-size: 18px;",
        "  font-weight: bold;",
        "}",

        ".drishti-picture {",
        "  background-color: transparent;",
        "}"
    ].
