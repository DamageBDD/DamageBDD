# GTK4 GS-style Erlang baseline

This bundle is a concrete baseline for a fresh GTK4-native C-node UI layer.
It retains the useful application-facing shape of the supplied `wxgs` module
without exposing raw GTK function names as the long-term API.

## Modules

- `gtknode4.erl` — protocol controller, correlation, readiness, event fan-out.
- `gtknode4_port.erl` — local OS-process owner and log collector.
- `gtknode4_sup.erl` — session-aware `one_for_all` supervision tree.
- `gtknode4_backend.erl` — deterministic backend contract.
- `gtknode4_fake.erl` — structural/contract BDD backend; never claims pixels.
- `gtkgs.erl` — GS-style object hierarchy and BDD inspection surface.
- `gtkgs_dialog_demo.erl` — manual dialog/UI demo using only `gtkgs`.
- `gtkgs_bdd_tests.erl` — GS/object/dialog EUnit contract examples.
- `gtknode4_controller_tests.erl` — endpoint handshake/correlation tests.
- `features/gtkgs_dialog.feature` — DamageBDD scenario split.
- `doc/gtknode4_protocol.md` — exact C-node protocol to implement.

## Supervision topology

```text
gtknode4_sup (one_for_all in local/fake mode)
├── gtknode4          protocol controller
├── gtknode4_port     local external C-node, omitted in fake mode
└── gtkgs             logical GS object service
```

These members are one UI session. A C-node restart invalidates every native
widget; a `gtkgs` crash loses the logical registry while native widgets remain;
and a controller crash loses pending correlations. Local and fake modes
therefore restart all three together. The port worker also enforces a bounded
handshake and restarts the session when distribution disconnects.
`external_cnode` mode uses `rest_for_one` because the external native process
is explicitly outside this supervisor.

## Start a real local C-node

Build the executable at `priv/gtknode4`, start the VM with distribution, then:

```erlang
{ok, _Sup} = gtknode4_sup:start_link(#{
    mode => local_cnode,
    port => #{
        executable => "priv/gtknode4",
        handshake_timeout => 10000
    },
    gs => #{
        test_mode => false,
        event_log_limit => 1000
    }
}),
ok = gtknode4:await_ready(10000),
DemoPid = gtkgs_dialog_demo:start().
```

Example shell:

```bash
rebar3 shell --sname erm
```

## Run deterministic contract tests

```erlang
{ok, _Sup} = gtknode4_sup:start_link(#{
    mode => fake,
    gs => #{test_mode => true}
}).
```

The fake backend verifies object state, command translation, event sequencing,
timeouts and dialog result handling. `snapshot/1` deliberately returns
`{error, visual_capture_requires_real_backend}` so a fake cannot accidentally
certify visual accuracy.

## BDD usage pattern

```erlang
Cursor = gtkgs:event_cursor(),
ok = gtkgs:inject(ButtonRef, click, #{}),
{ok, Event} = gtkgs:await_event(ButtonRef, click, Cursor, 1000),
ok = gtkgs:sync(),
{ok, Snapshot} = gtkgs:snapshot(WindowRef).
```

A modal dialog is a separate GTK surface. Capture it without sleeps by opening
the blocking convenience call in a helper process. A human may click the native
button in the normal profile. For a visual BDD run that closes the dialog through
the protocol after capture, start both `gtkgs` and the C-node in test mode (see
`config/sys.visual_test.config`):

```erlang
Owner = self(),
Cursor0 = gtkgs:event_cursor(),
spawn(fun() ->
    Result = gtkgs:message_dialog(WindowRef, "Proceed?", [
        {style, [yes_no, question]}
    ]),
    Owner ! {dialog_result, Result}
end),
{ok, _Opened} = gtkgs:await_event(WindowRef, dialog_opened, Cursor0, 5000),
[Dialog | _] = gtkgs:active_dialogs(),
{ok, DialogSnapshot} = gtkgs:snapshot_dialog(maps:get(ref, Dialog)),
ok = gtkgs:respond_dialog(maps:get(ref, Dialog), yes),
receive {dialog_result, yes} -> ok after 5000 -> error(dialog_timeout) end.
```

`respond_dialog/2`, `inject/3`, and dialog `auto_response` are rejected outside
test mode. Lifecycle-only `dismiss_dialog` remains available internally so a
caller crash or timeout cannot orphan a modal surface. This keeps production
UI control separate from BDD-only stimulus.

Store object refs in scenario context. Names remain owner-local for GS-style
application convenience, while refs are safe to pass between BDD step
processes.

## Native implementation still required

The Erlang side is complete enough to define and test the contract, but the C
binary must implement the commands and event shapes in
`doc/gtknode4_protocol.md`. In particular, the original C skeleton needs a
real non-blocking distribution receive integration and GTK-main-context
command dispatch before the manual demo will render.
