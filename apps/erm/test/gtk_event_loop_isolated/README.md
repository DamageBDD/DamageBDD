# GTK distribution liveness regression

Run from the repository root:

```sh
sh apps/erm/test/gtk_event_loop_isolated/run.sh
sh apps/erm/test/motion/run.sh
```

The first runner needs the C compiler, Erlang libei development files, GTK4
and X11 development files. It does not need a display or a running Erlang node.
It compiles the production C source into a harness and uses real libei tick
packets over a socket pair, without mocking distribution reads.

The cases exercise a permanently ready GLib source, sync with that source,
an incomplete distribution header, peer disconnect, an idle connection and
intentional shutdown. The pre-fix main loop, sync and partial-header cases
hang until the harness watchdog terminates them.

GTK dispatch is now bounded to 32 iterations or 2 ms per turn, checked between
callbacks. An individual blocking GTK callback can still stall the UI; this
is a scheduling bound, not thread isolation. Sync services pending GTK work
within that bound and does not wait for animations to finish. Use the existing
motion_finished event to wait for an animation.

Distribution receives have a 1-second timeout after the socket becomes
readable. A timeout abandons the connection, since the receiver may already
have consumed a partial packet. Socket and receive failures are logged to
stderr and produce a nonzero process exit; normal shutdown still exits zero.
The existing supervisor recreates the GTK session after connection loss.

The motion runner uses Xvfb by default. Its native integration case sets a
4-second net_ticktime and leaves a processing animation running for 9 seconds
without application messages. It checks for node loss, a changed native PID
or controller PID, then verifies sync and widget reads still work. The short
tick interval is confined to this isolated test VM.
