# gtknode4 protocol v1

This is the native contract required by `gtknode4.erl` and `gtkgs.erl`.
The C-node is a distributed Erlang endpoint; the local Erlang port owns only
its operating-system lifetime and output stream.

## Handshake

After connecting to the Erlang node, send one of these messages to the
registered Erlang controller (`gtknode4` by default):

```erlang
{gtknode4, hello, 1, {CRegisteredName, CNode}, CapabilitiesMap}.
```

or:

```erlang
{gtknode4, hello, 1, CNode, CRegisteredName, CapabilitiesMap}.
```

The preferred capability map is:

```erlang
#{
    gtk_version => {4, Minor, Micro},
    protocol_version => 1,
    widgets => [window, box, button, label, entry, text_view, list_view,
                scale, picture, scrolled_box],
    dialogs => alert_dialog,
    snapshot => true,
    inspect => true,
    test_injection => TestMode,
    renderer => RendererName
}.
```

The C-node must accept registered sends at `{CRegisteredName, CNode}`.

## Calls, casts and replies

```erlang
%% Erlang -> C-node
{gtknode4, call, Ref, Command}.
{gtknode4, cast, Command}.

%% C-node -> Erlang controller
{gtknode4, reply, Ref, Result}.
```

Every call must receive exactly one reply. A cast receives no reply.
Unknown commands return:

```erlang
{error, {unsupported_command, CommandTag}}.
```

## Canonical commands

### Create

```erlang
{create, NativeId, NativeType, ParentNativeId | root, PropertiesMap}
    -> {ok, NativeMetadataMap} | {error, Reason}.
```

`NativeId` is allocated by `gtkgs` and is stable for the lifetime of the
native object. `PropertiesMap.automation_id` must be applied as an accessible
or buildable identifier so screenshots and accessibility inspection can be
correlated with BDD objects.

Native types in v1 are capability-negotiated. The current desktop backend
advertises:

```text
window, box, button, label, entry, text_view, list_view, scale,
picture, scrolled_box
```

A `window` native object owns an implicit root `GtkBox`; children whose parent
is the window ID are appended to that box. A `box` maps to `GtkBox`. This keeps
the GS hierarchy stable while avoiding GTK4's removed generic-container API.
Child layout keys such as `expand`, `border`, and `align` are interpreted when
the child is attached to its parent.

`picture` maps to `GtkPicture`. ERM only passes normalized local image paths to
this object; network fetching/decoding remains outside the GTK process.

`scrolled_box` maps to a `GtkScrolledWindow` whose child is an internal
`GtkBox`. Logical children are appended to that inner box. This provides a
scrollable GS-style container without exposing a second native object ID.

Clients MUST check the `widgets` capability list before relying on an optional
native type. A protocol-compatible but older C-node may omit newer widgets.

### Configure

```erlang
{config, NativeId, PatchMap} -> ok | {error, Reason}.
```

Canonical keys include:

```text
title, label, text, items, add, clear, enabled, shown, focus,
size, width, height, min_size, tooltip, orientation,
expand, proportion, border, border_sides, align, selection
```

### Read

```erlang
{read, NativeId, Property} -> {ok, Value} | {error, Reason}.
```

Reads must query the native object, not merely echo the last requested value.
That distinction lets BDD catch failed or transformed GTK mutations.

### Inspect

```erlang
{inspect, NativeId} -> {ok, NativeStateMap} | {error, Reason}.
```

Recommended state includes widget type, accessible role/name, visibility,
sensitivity, allocation, text/label, selection, parent and child order.

### Destroy

```erlang
{destroy, NativeId} -> ok | {error, Reason}.
```

Destroying a container destroys its native descendants. A user-initiated
window close emits a canonical `destroy` event before the native identifier is
forgotten.

### Renderer barrier

```erlang
sync -> ok | {error, Reason}.
```

`sync` is not merely a queue flush. Reply only after:

1. all commands received before `sync` have been applied on the GTK main
   context;
2. pending layout has completed; and
3. a frame-clock update/after-paint point has been observed for mapped roots.

This is the key BDD invariant: scenarios use `gtkgs:sync/0`, never sleeps.

### Snapshot

```erlang
{snapshot, NativeId, OptionsMap}
    -> {ok, SnapshotMap} | {error, Reason}.
```

Recommended response:

```erlang
#{
    png => PngBinary,
    width => Width,
    height => Height,
    scale => Scale,
    gtk_version => {4, Minor, Micro},
    renderer => Renderer,
    theme => Theme,
    font => FontDescription,
    locale => Locale,
    render_serial => Serial
}.
```

A visual BDD report must retain this metadata beside the PNG. Golden-image
comparisons are invalid when renderer profile metadata differs unless the
scenario explicitly permits it.

An open dialog is a separate native surface and therefore has its own capture
command:

```erlang
{snapshot_dialog, DialogId, OptionsMap}
    -> {ok, SnapshotMap} | {error, Reason}.
```

For a human checkpoint, start `gtkgs:message_dialog/3` in a helper process,
wait for `dialog_opened`, retrieve the ref from `gtkgs:active_dialogs/0`, call
`gtkgs:snapshot_dialog/1`, then use `gtkgs:respond_dialog/2` when test mode is
enabled. This avoids timing sleeps and does not pretend that the parent-window
snapshot contains a separate modal surface.

### Message dialog

```erlang
{message_dialog, DialogId, ParentNativeId, MessageBinary, OptionsMap}
    -> {ok, ResponseAtom} | {error, Reason}.
```

The C implementation must use an asynchronous response callback and keep the
protocol call pending until that callback completes. On GTK 4.10 and newer,
`GtkAlertDialog` is suitable; an implementation supporting older GTK4 minors
can use a `GtkDialog`/`GtkMessageDialog` response signal. It must never run a
nested blocking dialog loop or block the GTK main context.

Canonical options:

```erlang
#{
    caption => binary(),
    detail => binary(),                 % optional
    kind => information | warning | error | question,
    buttons => [ok | cancel | yes | no | help],
    modal => boolean(),
    default_response => atom(),
    cancel_response => atom() | undefined,
    auto_response => atom()             % test mode only
}.
```

When shown and closed, emit `dialog_opened` and `dialog_closed` events against
the parent native ID. Include `dialog_id` in both payloads.

```erlang
{dialog_response, DialogId, ResponseAtom} -> ok | {error, Reason}.
```

`dialog_response` and `auto_response` must be rejected unless the C-node was
started with `--test-mode`. The C-node must accept `dialog_response` as either
a call or cast.

Lifecycle cancellation is separate from simulated user input:

```erlang
{dismiss_dialog, DialogId} -> ok | {error, Reason}.
```

`dismiss_dialog` is accepted in every mode and must cancel/dismiss the native
dialog without recording an affirmative user choice. `gtkgs` uses its cast
form after a protocol timeout and when the process which opened a dialog dies.

### Test input injection

```erlang
{inject, NativeId, CanonicalEvent, PayloadMap} -> ok | {error, Reason}.
```

Injection is test-mode only. It must invoke the native GTK action path where
possible (`activate`, editable update, selection model update) rather than
only fabricating an outbound event.

## Events

```erlang
{gtknode4, event, NativeId, EventType, PayloadMap}.
```

The controller adds a monotonically increasing receipt sequence before
forwarding to subscribers:

```erlang
{gtknode4, event, Seq, NativeId, EventType, PayloadMap}.
```

Canonical v1 event types:

```text
click, doubleclick, keypress, change, configure, destroy,
dialog_opened, dialog_closed
```

Examples:

```erlang
{gtknode4, event, 2003, click, #{}}.
{gtknode4, event, 2004, keypress, #{key => return, text => <<"Alice">>}}.
{gtknode4, event, 2005, click,
    #{index => 1, text => <<"Nostr event">>, selected => true}}.
{gtknode4, event, 2000, configure, #{width => 720, height => 520}}.
```

Raw GTK signal names may be included as `PayloadMap.raw_signal`, but must not
replace the canonical event atom.

## Local executable command line

The supplied `gtknode4_port` worker launches:

```text
gtknode4
  --name gtknode4@HOST
  --peer app@HOST
  --register gtknode4
  --controller gtknode4
  --cookie-env GTKNODE4_COOKIE
  --protocol 1
  [--test-mode]
```

Read the cookie from the named environment variable. Do not require the
cookie in argv, where it is visible to local process inspection.
