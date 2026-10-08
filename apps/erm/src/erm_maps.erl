%%%-------------------------------------------------------------------
%%% @doc
%%% ERM Maps: a GTKGS/libshumate map application.
%%%
%%% The Erlang process owns UI state and talks only to gtkgs. The gtknode4
%%% native node owns ShumateSimpleMap and tile/network rendering. This keeps
%%% lifecycle, diagnostics and window-manager behaviour aligned with the rest
%%% of ERM instead of introducing a second GUI runtime.
%%%
%%% Default map source: OpenStreetMap Mapnik (libshumate id "osm-mapnik").
%%%-------------------------------------------------------------------
-module(erm_maps).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").
-include("erm_log.hrl").

-export([
    start/0,
    start/1,
    start_link/0,
    start_link/1,
    stop/0,
    show/0,
    hide/0,
    set_center/2,
    set_view/3,
    set_zoom/1,
    zoom_in/0,
    zoom_out/0,
    set_source/1,
    status/0
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
-define(DEFAULT_SOURCE, <<"osm-mapnik">>).
-define(DEFAULT_LATITUDE, 0.0).
-define(DEFAULT_LONGITUDE, 0.0).
-define(DEFAULT_ZOOM, 2.0).
-define(DEFAULT_WIDTH, 1024).
-define(DEFAULT_HEIGHT, 720).
-define(LOG_DOMAIN, ?ERM_LOG_DOMAIN_MAPS).

-record(state, {
    window,
    map,
    source_id = ?DEFAULT_SOURCE,
    latitude = ?DEFAULT_LATITUDE,
    longitude = ?DEFAULT_LONGITUDE,
    zoom_level = ?DEFAULT_ZOOM,
    show_zoom_buttons = true,
    visible = true
}).

-type options() :: map() | list().

%%%===================================================================
%%% Public API
%%%===================================================================

-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    start(#{}).

-spec start(options()) -> {ok, pid()} | {error, term()}.
start(UserOpts0) when is_map(UserOpts0); is_list(UserOpts0) ->
    case whereis(?SERVER) of
        Pid when is_pid(Pid) ->
            _ = gen_server:call(?SERVER, show),
            {ok, Pid};
        undefined ->
            case prepare_options(UserOpts0) of
                {ok, Opts} ->
                    case ensure_gtknode4_ready(maps:get(ready_timeout, Opts)) of
                        ok ->
                            case gen_server:start({local, ?SERVER}, ?MODULE, Opts, []) of
                                {ok, Pid} -> {ok, Pid};
                                {error, {already_started, Pid}} -> {ok, Pid};
                                Error -> Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(options()) -> gen_server:start_ret().
start_link(UserOpts0) when is_map(UserOpts0); is_list(UserOpts0) ->
    case prepare_options(UserOpts0) of
        {ok, Opts} -> gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []);
        {error, Reason} -> {error, Reason}
    end.

-spec stop() -> ok.
stop() ->
    case whereis(?SERVER) of
        undefined -> ok;
        _ -> gen_server:stop(?SERVER)
    end.

-spec show() -> ok | {ok, pid()} | {error, term()}.
show() ->
    case whereis(?SERVER) of
        undefined -> start();
        _ -> gen_server:call(?SERVER, show)
    end.

-spec hide() -> ok | {error, not_started}.
hide() ->
    call_if_started(hide).

-spec set_center(number(), number()) -> ok | {error, term()}.
set_center(Latitude, Longitude) ->
    gen_server_call({set_center, Latitude, Longitude}).

-spec set_view(number(), number(), number()) -> ok | {error, term()}.
set_view(Latitude, Longitude, ZoomLevel) ->
    gen_server_call({set_view, Latitude, Longitude, ZoomLevel}).

-spec set_zoom(number()) -> ok | {error, term()}.
set_zoom(ZoomLevel) ->
    gen_server_call({set_zoom, ZoomLevel}).

-spec zoom_in() -> ok | {error, term()}.
zoom_in() ->
    gen_server_call(zoom_in).

-spec zoom_out() -> ok | {error, term()}.
zoom_out() ->
    gen_server_call(zoom_out).

-spec set_source(atom() | binary() | string()) -> ok | {error, term()}.
set_source(SourceId) ->
    gen_server_call({set_source, SourceId}).

-spec status() -> map() | not_started.
status() ->
    case whereis(?SERVER) of
        undefined -> not_started;
        _ -> gen_server:call(?SERVER, status)
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    _ = erm_log:set_process_domain(?LOG_DOMAIN),
    case gtknode4:await_ready(maps:get(ready_timeout, Opts)) of
        ok ->
            case ensure_map_backend() of
                ok -> init_ui(Opts);
                {error, Reason} -> {stop, Reason}
            end;
        Error ->
            {stop, {gtknode4_not_ready, Error}}
    end.

init_ui(Opts) ->
    SourceId = maps:get(source_id, Opts),
    Latitude = maps:get(latitude, Opts),
    Longitude = maps:get(longitude, Opts),
    ZoomLevel = maps:get(zoom_level, Opts),
    ShowZoomButtons = maps:get(show_zoom_buttons, Opts),
    Width = maps:get(width, Opts),
    Height = maps:get(height, Opts),

    case gtkgs:set_stylesheet(erm_maps, stylesheet()) of
        ok -> ok;
        {error, StylesheetReason} ->
            ?LOG_WARNING("ERM Maps stylesheet unavailable reason=~p", [StylesheetReason])
    end,

    Server = gtkgs:server(),
    Tree = [
        {window, erm_maps_window,
            [
                {title, "ERM Maps"},
                {width, Width},
                {height, Height},
                {wm_class, "erm_maps"},
                {wm_instance, "erm_maps"},
                {window_role, "maps"},
                {class, "erm-maps-window"}
            ],
            [
                {frame, erm_maps_root,
                    [
                        {orient, vertical},
                        {spacing, 0},
                        {expand, true},
                        {class, "erm-maps-root"}
                    ],
                    [
                        {map, erm_maps_view, [
                            {source_id, SourceId},
                            {latitude, Latitude},
                            {longitude, Longitude},
                            {zoom_level, ZoomLevel},
                            {show_zoom_buttons, ShowZoomButtons},
                            {expand, true},
                            {class, "erm-maps-view"}
                        ]},
                        {label, erm_maps_status, [
                            {label, status_text(Latitude, Longitude, ZoomLevel, SourceId)},
                            {align, start},
                            {class, "erm-maps-status"}
                        ]}
                    ]}
            ]}
    ],

    case gtkgs:create_tree(Server, Tree) of
        {ok, [Window]} ->
            [Root] = gtkgs:read(Window, children),
            [MapRef, _StatusRef] = gtkgs:read(Root, children),
            ok = gtkgs:config(Window, {map, true}),
            ok = gtkgs:sync(),
            ?LOG_INFO(
                "ERM Maps started source=~ts lat=~p lon=~p zoom=~p",
                [SourceId, Latitude, Longitude, ZoomLevel]
            ),
            InitialState = #state{
                window = Window,
                map = MapRef,
                source_id = SourceId,
                latitude = Latitude,
                longitude = Longitude,
                zoom_level = ZoomLevel,
                show_zoom_buttons = ShowZoomButtons,
                visible = true
            },
            %% A map source may clamp zoom/location to its own supported range.
            %% Keep the Erlang state aligned with what libshumate accepted.
            State = state_from_native(InitialState),
            _ = update_status_label(State),
            {ok, State};
        {error, CreateReason} ->
            {stop, {maps_ui_failed, CreateReason}}
    end.

handle_call(show, _From, State = #state{window = Window}) ->
    case gtkgs:config(Window, {map, true}) of
        ok -> {reply, ok, State#state{visible = true}};
        Error -> {reply, Error, State}
    end;
handle_call(hide, _From, State = #state{window = Window}) ->
    case gtkgs:config(Window, {map, false}) of
        ok -> {reply, ok, State#state{visible = false}};
        Error -> {reply, Error, State}
    end;
handle_call({set_center, Latitude0, Longitude0}, _From, State) ->
    case {normalize_latitude(Latitude0), normalize_longitude(Longitude0)} of
        {{ok, Latitude}, {ok, Longitude}} ->
            update_map(
                [{latitude, Latitude}, {longitude, Longitude}],
                State#state{latitude = Latitude, longitude = Longitude}
            );
        {{error, _} = Error, _} ->
            {reply, Error, State};
        {_, {error, _} = Error} ->
            {reply, Error, State}
    end;
handle_call({set_view, Latitude0, Longitude0, Zoom0}, _From, State) ->
    case {
        normalize_latitude(Latitude0),
        normalize_longitude(Longitude0),
        normalize_zoom(Zoom0)
    } of
        {{ok, Latitude}, {ok, Longitude}, {ok, Zoom}} ->
            update_map(
                [{latitude, Latitude}, {longitude, Longitude}, {zoom_level, Zoom}],
                State#state{latitude = Latitude, longitude = Longitude, zoom_level = Zoom}
            );
        {{error, _} = Error, _, _} ->
            {reply, Error, State};
        {_, {error, _} = Error, _} ->
            {reply, Error, State};
        {_, _, {error, _} = Error} ->
            {reply, Error, State}
    end;
handle_call({set_zoom, Zoom0}, _From, State) ->
    case normalize_zoom(Zoom0) of
        {ok, Zoom} ->
            update_map([{zoom_level, Zoom}], State#state{zoom_level = Zoom});
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call(zoom_in, _From, State) ->
    Zoom = min(24.0, State#state.zoom_level + 1.0),
    update_map([{zoom_level, Zoom}], State#state{zoom_level = Zoom});
handle_call(zoom_out, _From, State) ->
    Zoom = max(0.0, State#state.zoom_level - 1.0),
    update_map([{zoom_level, Zoom}], State#state{zoom_level = Zoom});
handle_call({set_source, SourceId0}, _From, State) ->
    case normalize_source_id(SourceId0) of
        {ok, SourceId} ->
            update_map([{source_id, SourceId}], State#state{source_id = SourceId});
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call(status, _From, State) ->
    {reply, state_status(State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({gtkgs, erm_maps_view, map_changed, _Data, [Payload]}, State0) when is_map(Payload) ->
    State = State0#state{
        latitude = maps:get(latitude, Payload, State0#state.latitude),
        longitude = maps:get(longitude, Payload, State0#state.longitude),
        zoom_level = maps:get(zoom_level, Payload, State0#state.zoom_level),
        source_id = maps:get(source_id, Payload, State0#state.source_id)
    },
    _ = update_status_label(State),
    {noreply, State};
handle_info({gtkgs, erm_maps_window, hidden, _Data, _Args}, State) ->
    {noreply, State#state{visible = false}};
handle_info({gtkgs, erm_maps_window, destroy, _Data, _Args}, State) ->
    {stop, normal, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{window = Window}) ->
    try gtkgs:destroy(Window) of
        _ -> ok
    catch
        _:_ -> ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal helpers
%%%===================================================================

update_map(Options, NewState = #state{map = MapRef}) ->
    case gtkgs:config(MapRef, Options) of
        ok ->
            _ = gtkgs:sync(),
            %% Read back the native viewport because libshumate can clamp zoom
            %% levels when the selected source has a narrower supported range.
            State = state_from_native(NewState),
            _ = update_status_label(State),
            {reply, ok, State};
        {error, Reason} = Error ->
            ?LOG_WARNING("ERM Maps update failed options=~p reason=~p", [Options, Reason]),
            {reply, Error, state_from_native(NewState)}
    end.

update_status_label(State) ->
    gtkgs:config(
        erm_maps_status,
        {label,
            status_text(
                State#state.latitude,
                State#state.longitude,
                State#state.zoom_level,
                State#state.source_id
            )}
    ).

state_from_native(State = #state{map = MapRef}) ->
    State#state{
        latitude = read_or(MapRef, latitude, State#state.latitude),
        longitude = read_or(MapRef, longitude, State#state.longitude),
        zoom_level = read_or(MapRef, zoom_level, State#state.zoom_level),
        source_id = read_or(MapRef, source_id, State#state.source_id),
        show_zoom_buttons =
            read_or(MapRef, show_zoom_buttons, State#state.show_zoom_buttons)
    }.

read_or(MapRef, Key, Default) ->
    try gtkgs:read(MapRef, Key) of
        {'EXIT', _} -> Default;
        {error, _} -> Default;
        Value -> Value
    catch
        _:_ -> Default
    end.

state_status(State) ->
    #state{
        source_id = SourceId,
        latitude = Latitude,
        longitude = Longitude,
        zoom_level = Zoom,
        show_zoom_buttons = ShowZoomButtons,
        visible = Visible
    } = state_from_native(State),
    #{
        source_id => SourceId,
        latitude => Latitude,
        longitude => Longitude,
        zoom_level => Zoom,
        show_zoom_buttons => ShowZoomButtons,
        visible => Visible,
        backend => safe_gtknode4_status()
    }.


ensure_map_backend() ->
    try gtknode4:status() of
        #{ready := true, capabilities := Capabilities} ->
            Widgets = maps:get(widgets, Capabilities, []),
            case Widgets =:= [] orelse lists:member(map, Widgets) of
                true ->
                    ok;
                false ->
                    {error, {map_widget_unavailable, #{
                        libshumate => maps:get(libshumate, Capabilities, false),
                        widgets => Widgets
                    }}}
            end;
        Status ->
            {error, {gtknode4_not_ready, Status}}
    catch
        Class:Reason ->
            {error, {gtknode4_status_failed, Class, Reason}}
    end.

safe_gtknode4_status() ->
    try gtknode4:status() of
        Status -> Status
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

prepare_options(UserOpts0) ->
    AppOpts = options_map(application_options()),
    UserOpts = options_map(UserOpts0),
    Opts0 = maps:merge(default_options(), maps:merge(AppOpts, UserOpts)),
    case normalize_options(Opts0) of
        {ok, Opts} -> {ok, Opts};
        {error, _} = Error -> Error
    end.

normalize_options(Opts0) ->
    case {
        normalize_source_id(maps:get(source_id, Opts0, ?DEFAULT_SOURCE)),
        normalize_latitude(maps:get(latitude, Opts0, ?DEFAULT_LATITUDE)),
        normalize_longitude(maps:get(longitude, Opts0, ?DEFAULT_LONGITUDE)),
        normalize_zoom(maps:get(zoom_level, Opts0, ?DEFAULT_ZOOM)),
        positive_integer(width, maps:get(width, Opts0, ?DEFAULT_WIDTH)),
        positive_integer(height, maps:get(height, Opts0, ?DEFAULT_HEIGHT)),
        positive_integer(ready_timeout, maps:get(ready_timeout, Opts0, ?DEFAULT_READY_TIMEOUT)),
        boolean_option(show_zoom_buttons, maps:get(show_zoom_buttons, Opts0, true))
    } of
        {
            {ok, SourceId},
            {ok, Latitude},
            {ok, Longitude},
            {ok, Zoom},
            {ok, Width},
            {ok, Height},
            {ok, ReadyTimeout},
            {ok, ShowZoomButtons}
        } ->
            {ok, #{
                source_id => SourceId,
                latitude => Latitude,
                longitude => Longitude,
                zoom_level => Zoom,
                width => Width,
                height => Height,
                ready_timeout => ReadyTimeout,
                show_zoom_buttons => ShowZoomButtons
            }};
        Results ->
            first_error(tuple_to_list(Results))
    end.

normalize_source_id(Value) when is_atom(Value) ->
    normalize_source_id(atom_to_binary(Value, utf8));
normalize_source_id(Value) when is_list(Value) ->
    normalize_source_id(unicode:characters_to_binary(Value));
normalize_source_id(Value) when is_binary(Value), byte_size(Value) > 0 ->
    {ok, Value};
normalize_source_id(Value) ->
    {error, {invalid_source_id, Value}}.

normalize_latitude(Value) when is_number(Value), Value >= -90, Value =< 90 ->
    {ok, float(Value)};
normalize_latitude(Value) ->
    {error, {invalid_latitude, Value}}.

normalize_longitude(Value) when is_number(Value), Value >= -180, Value =< 180 ->
    {ok, float(Value)};
normalize_longitude(Value) ->
    {error, {invalid_longitude, Value}}.

normalize_zoom(Value) when is_number(Value), Value >= 0, Value =< 24 ->
    {ok, float(Value)};
normalize_zoom(Value) ->
    {error, {invalid_zoom_level, Value}}.

positive_integer(_Name, Value) when is_integer(Value), Value > 0 ->
    {ok, Value};
positive_integer(Name, Value) ->
    {error, {invalid_option, Name, Value}}.

boolean_option(_Name, Value) when is_boolean(Value) ->
    {ok, Value};
boolean_option(Name, Value) ->
    {error, {invalid_option, Name, Value}}.

first_error([{error, _} = Error | _]) -> Error;
first_error([_ | Rest]) -> first_error(Rest);
first_error([]) -> {error, invalid_options}.

default_options() ->
    #{
        source_id => ?DEFAULT_SOURCE,
        latitude => ?DEFAULT_LATITUDE,
        longitude => ?DEFAULT_LONGITUDE,
        zoom_level => ?DEFAULT_ZOOM,
        width => ?DEFAULT_WIDTH,
        height => ?DEFAULT_HEIGHT,
        ready_timeout => ?DEFAULT_READY_TIMEOUT,
        show_zoom_buttons => true
    }.

application_options() ->
    case application:get_env(erm, maps, #{}) of
        Value when is_map(Value); is_list(Value) -> Value;
        _ -> #{}
    end.

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List);
options_map(_) -> #{}.

ensure_gtknode4_ready(Timeout) ->
    _ = maybe_start_gtknode4(),
    try gtknode4:await_ready(Timeout) of
        ok -> ok;
        {error, Reason} -> {error, {gtknode4_not_ready, Reason}}
    catch
        Class:Reason -> {error, {gtknode4_not_ready, {Class, Reason}}}
    end.

maybe_start_gtknode4() ->
    case whereis(gtknode4_sup) of
        Pid when is_pid(Pid) -> ok;
        undefined ->
            case whereis(erm_sup) of
                Pid when is_pid(Pid) ->
                    try erm_sup:start_gtknode4() of
                        {ok, _} -> ok;
                        {error, already_present} -> ok;
                        {error, {already_started, _}} -> ok;
                        {error, {unmanaged_process_already_started, _}} -> ok;
                        Other -> Other
                    catch
                        Class:StartReason ->
                            {error, {gtknode4_start_failed, Class, StartReason}}
                    end;
                undefined ->
                    {error, erm_sup_not_running}
            end
    end.

gen_server_call(Request) ->
    case whereis(?SERVER) of
        undefined -> {error, not_started};
        _ -> gen_server:call(?SERVER, Request)
    end.

call_if_started(Request) ->
    gen_server_call(Request).

status_text(Latitude, Longitude, Zoom, SourceId) ->
    iolist_to_binary(
        io_lib:format(
            "~ts   ~.5f, ~.5f   zoom ~.1f",
            [SourceId, Latitude, Longitude, Zoom]
        )
    ).

stylesheet() ->
    iolist_to_binary([
        ".erm-maps-window { background: #101316; }\n",
        ".erm-maps-root { background: #101316; }\n",
        ".erm-maps-view { min-width: 320px; min-height: 240px; }\n",
        ".erm-maps-status {",
        "  padding: 8px 12px;",
        "  background: rgba(16,19,22,0.94);",
        "  color: #d8dee9;",
        "  font-family: monospace;",
        "}\n"
    ]).
