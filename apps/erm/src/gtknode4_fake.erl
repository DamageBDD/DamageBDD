%%%-------------------------------------------------------------------
%%% @doc
%%% Deterministic in-memory backend for gtknode4 protocol/BDD tests.
%%%
%%% It deliberately does not claim visual fidelity. Snapshot requests fail
%%% explicitly so that visual scenarios must exercise the real GTK renderer.
%%%-------------------------------------------------------------------
-module(gtknode4_fake).
-behaviour(gtknode4_backend).

-export([init/1, handle_command/2, handle_cast/2, terminate/2]).

-record(state, {
    objects = #{},
    dialogs = #{},
    test_mode = true
}).

init(Opts) ->
    TestMode = maps:get(test_mode, Opts, true),
    Capabilities = #{
        backend => fake,
        protocol_version => 1,
        widgets => [
            window, box, button, label, entry, text_view, list_view, scale,
            picture, scrolled_box
        ],
        object_commands => [create, config, read, destroy, inspect, sync],
        test_injection => TestMode,
        visual_capture => false,
        dialogs => deterministic
    },
    {ok, #state{test_mode = TestMode}, Capabilities}.

handle_command({create, NativeId, Type, Parent, Props0}, State0) ->
    Props = options_map(Props0),
    case validate_create(NativeId, Parent, State0#state.objects) of
        ok ->
            Object = #{
                native_id => NativeId,
                type => Type,
                parent => Parent,
                props => default_props(Type, Props)
            },
            Objects = maps:put(NativeId, Object, State0#state.objects),
            {reply, {ok, #{native_id => NativeId}}, State0#state{objects = Objects}};
        {error, Reason} ->
            {reply, {error, Reason}, State0}
    end;
handle_command({config, NativeId, Patch0}, State0) ->
    Patch = options_map(Patch0),
    case maps:get(NativeId, State0#state.objects, undefined) of
        undefined ->
            {reply, {error, {native_object_not_found, NativeId}}, State0};
        Object0 ->
            Props0 = maps:get(props, Object0),
            Props = apply_patch(Patch, Props0),
            Object = Object0#{props := Props},
            Objects = maps:put(NativeId, Object, State0#state.objects),
            {reply, ok, State0#state{objects = Objects}}
    end;
handle_command({read, NativeId, Key}, State) ->
    {reply, read_object(NativeId, Key, State#state.objects), State};
handle_command({inspect, NativeId}, State) ->
    case maps:get(NativeId, State#state.objects, undefined) of
        undefined -> {reply, {error, {native_object_not_found, NativeId}}, State};
        Object -> {reply, {ok, Object}, State}
    end;
handle_command({destroy, NativeId}, State0) ->
    case maps:is_key(NativeId, State0#state.objects) of
        false ->
            {reply, {error, {native_object_not_found, NativeId}}, State0};
        true ->
            Ids = descendants_including(NativeId, State0#state.objects),
            Objects = lists:foldl(fun maps:remove/2, State0#state.objects, Ids),
            {reply, ok, State0#state{objects = Objects}}
    end;
handle_command({message_dialog, DialogId, ParentId, Message, Options0}, State0) ->
    Options = options_map(Options0),
    case maps:is_key(ParentId, State0#state.objects) of
        false ->
            {reply, {error, {native_object_not_found, ParentId}}, State0};
        true ->
            Response = maps:get(
                auto_response,
                Options,
                maps:get(default_response, Options, default_dialog_response(Options))
            ),
            Events = [
                {ParentId, dialog_opened, #{
                    dialog_id => DialogId, message => Message, options => Options
                }},
                {ParentId, dialog_closed, #{dialog_id => DialogId, response => Response}}
            ],
            {reply, {ok, Response}, State0, Events}
    end;
handle_command({dismiss_dialog, DialogId}, State0) ->
    case maps:get(DialogId, State0#state.dialogs, undefined) of
        undefined ->
            {reply, ok, State0};
        Dialog ->
            ParentId = maps:get(parent, Dialog),
            Dialogs = maps:remove(DialogId, State0#state.dialogs),
            Event = {ParentId, dialog_closed, #{dialog_id => DialogId, response => dismissed}},
            {reply, ok, State0#state{dialogs = Dialogs}, [Event]}
    end;
handle_command({dialog_response, DialogId, Response}, State0) ->
    case maps:get(DialogId, State0#state.dialogs, undefined) of
        undefined ->
            {reply, {error, {dialog_not_found, DialogId}}, State0};
        Dialog ->
            ParentId = maps:get(parent, Dialog),
            Dialogs = maps:remove(DialogId, State0#state.dialogs),
            Event = {ParentId, dialog_closed, #{dialog_id => DialogId, response => Response}},
            {reply, ok, State0#state{dialogs = Dialogs}, [Event]}
    end;
handle_command({inject, NativeId, EventType, Payload0}, State0 = #state{test_mode = true}) ->
    Payload = normalize_payload(Payload0),
    case maps:get(NativeId, State0#state.objects, undefined) of
        undefined ->
            {reply, {error, {native_object_not_found, NativeId}}, State0};
        Object0 ->
            Object = apply_injected_state(EventType, Payload, Object0),
            Objects = maps:put(NativeId, Object, State0#state.objects),
            {reply, ok, State0#state{objects = Objects}, [{NativeId, EventType, Payload}]}
    end;
handle_command({inject, _NativeId, _EventType, _Payload}, State) ->
    {reply, {error, test_mode_disabled}, State};
handle_command({snapshot, _NativeId, _Options}, State) ->
    {reply, {error, visual_capture_requires_real_backend}, State};
handle_command({snapshot_dialog, _DialogId, _Options}, State) ->
    {reply, {error, visual_capture_requires_real_backend}, State};
handle_command(sync, State) ->
    {reply, ok, State};
handle_command({sync}, State) ->
    {reply, ok, State};
handle_command(reset, State) ->
    {reply, ok, State#state{objects = #{}, dialogs = #{}}};
handle_command(Command, State) ->
    {reply, {error, {unsupported_command, Command}}, State}.

handle_cast(shutdown, State) ->
    {noreply, State};
handle_cast({dismiss_dialog, DialogId}, State0) ->
    case handle_command({dismiss_dialog, DialogId}, State0) of
        {reply, _Result, State1} -> {noreply, State1};
        {reply, _Result, State1, Events} -> {noreply, State1, Events}
    end;
handle_cast(_Command, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

validate_create(NativeId, _Parent, Objects) when is_map_key(NativeId, Objects) ->
    {error, {native_id_exists, NativeId}};
validate_create(_NativeId, root, _Objects) ->
    ok;
validate_create(_NativeId, Parent, Objects) ->
    case maps:is_key(Parent, Objects) of
        true -> ok;
        false -> {error, {native_parent_not_found, Parent}}
    end.

default_props(Type, Props0) ->
    Base = #{
        enabled => true,
        shown => false,
        type => Type
    },
    Props1 = maps:merge(Base, Props0),
    case Type of
        button -> ensure_prop(label, <<"Button">>, Props1);
        label -> ensure_prop(label, <<>>, Props1);
        entry -> ensure_prop(text, <<>>, Props1);
        text_view -> ensure_prop(text, <<>>, Props1);
        list_view -> ensure_prop(items, [], Props1);
        _ -> Props1
    end.

ensure_prop(Key, Value, Map) ->
    case maps:is_key(Key, Map) of
        true -> Map;
        false -> maps:put(Key, Value, Map)
    end.

apply_patch(Patch, Props0) ->
    Props1 =
        case maps:get(clear, Patch, false) of
            true -> clear_props(Props0);
            false -> Props0
        end,
    Props2 =
        case maps:get(add, Patch, undefined) of
            undefined -> Props1;
            Item -> maps:update_with(items, fun(Items) -> Items ++ [Item] end, [Item], Props1)
        end,
    Patch1 = maps:without([clear, add], Patch),
    maps:merge(Props2, Patch1).

clear_props(Props) ->
    case maps:get(type, Props, undefined) of
        entry -> maps:put(text, <<>>, Props);
        text_view -> maps:put(text, <<>>, Props);
        list_view -> maps:put(items, [], Props);
        _ -> Props
    end.

read_object(NativeId, Key, Objects) ->
    case maps:get(NativeId, Objects, undefined) of
        undefined ->
            {error, {native_object_not_found, NativeId}};
        Object ->
            Props = maps:get(props, Object),
            read_prop(Key, Object, Props)
    end.

read_prop(native_id, Object, _Props) ->
    {ok, maps:get(native_id, Object)};
read_prop(type, Object, _Props) ->
    {ok, maps:get(type, Object)};
read_prop(parent, Object, _Props) ->
    {ok, maps:get(parent, Object)};
read_prop(text, Object, Props) ->
    Type = maps:get(type, Object),
    case Type of
        button -> {ok, maps:get(label, Props, <<>>)};
        label -> {ok, maps:get(label, Props, <<>>)};
        _ -> {ok, maps:get(text, Props, <<>>)}
    end;
read_prop(label, _Object, Props) ->
    {ok, maps:get(label, Props, <<>>)};
read_prop(enable, _Object, Props) ->
    {ok, maps:get(enabled, Props, true)};
read_prop(enabled, _Object, Props) ->
    {ok, maps:get(enabled, Props, true)};
read_prop(shown, _Object, Props) ->
    {ok, maps:get(shown, Props, maps:get(show, Props, false))};
read_prop(Key, _Object, Props) ->
    case maps:find(Key, Props) of
        {ok, Value} -> {ok, Value};
        error -> {error, {unknown_native_property, Key}}
    end.

apply_injected_state(click, #{index := _Index} = Payload, Object0) ->
    apply_injected_state(select, Payload, Object0);
apply_injected_state(keypress, Payload, Object0) ->
    maybe_set_text(Payload, Object0);
apply_injected_state(change, Payload, Object0) ->
    maybe_set_text(Payload, Object0);
apply_injected_state(select, Payload, Object0) ->
    Props0 = maps:get(props, Object0),
    Props = maps:put(selection, maps:get(index, Payload, -1), Props0),
    Object0#{props := Props};
apply_injected_state(_EventType, _Payload, Object) ->
    Object.

maybe_set_text(Payload, Object0) ->
    case maps:get(text, Payload, undefined) of
        undefined ->
            Object0;
        Text ->
            Props0 = maps:get(props, Object0),
            Object0#{props := maps:put(text, Text, Props0)}
    end.

descendants_including(RootId, Objects) ->
    descendants([RootId], Objects, []).

descendants([], _Objects, Acc) ->
    Acc;
descendants([Id | Rest], Objects, Acc) ->
    Children = [
        ChildId
     || {ChildId, Object} <- maps:to_list(Objects),
        maps:get(parent, Object, root) =:= Id
    ],
    descendants(Children ++ Rest, Objects, [Id | Acc]).

default_dialog_response(Options) ->
    case maps:get(buttons, Options, [ok]) of
        [First | _] -> First;
        [] -> ok
    end.

options_map(Map) when is_map(Map) -> Map;
options_map(List) when is_list(List) -> maps:from_list(List).

normalize_payload(Map) when is_map(Map) -> Map;
normalize_payload(undefined) -> #{};
normalize_payload(Value) -> #{value => Value}.
