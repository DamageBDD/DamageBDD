# Learning-store responsiveness and provider status recovery

## Scope

This change addresses collection reads blocking `ecai_learning_store`, receipt
statistics blocking the inference pool, and incomplete dashboard configuration
and health reporting. It does not diagnose the underlying cause of a particular
cloud transport failure. The current `damage_gun` implementation is outside the
ECAI-only source archive used to prepare this change.

No existing DETS records, inference receipts, or provider settings are deleted.
No remote connection is automatically enabled. No generation request is sent by
a status refresh or the connection test.

## Store behavior

Point reads already used `dets:lookup/2`. The expensive operation was an unrelated
collection fold running inside the same serialized store callback.

The store now builds a protected, key-only ETS collection index once at startup.
It updates the index alongside successful DETS insert/delete operations, before
sync, so visibility remains consistent even if sync fails. Large source, graph,
and relation values are not mirrored in ETS. Startup still traverses the DETS
key space; this is not an on-disk index or a zero-cost startup migration.

Collection callbacks defer work to linked, monitored readers. There are at most
two active readers and 32 admitted requests including queued work. The queue
budget starts at admission. Reader completion, failure, caller death, timeout,
and orderly store shutdown clean up timers, monitors, and workers. Overload
returns `{error, learning_store_busy}`. Timeout returns
`{error, learning_store_query_timeout}`. Workers fetch indexed values one at a
time, allowing snapshots to discard large payloads before accumulating results.

Existing successful return shapes and repair compare-and-put semantics remain.
Collection listings are best-effort views, not transactions; values can advance
while a listing is read. Snapshot export has a stricter rule: a store write
revision fences each snapshot read. Overlapping mutation causes a retry (at most
two retries), then `{error, learning_store_snapshot_busy}`. Snapshot writing
returns that error rather than publishing a mixed or empty snapshot.

Add these optional tuples under the `ecai` application's configuration:

```erlang
{learning_store_read_timeout_ms, 30000},
{learning_store_query_timeout_ms, 60000},
```

These are the new defaults. They do not configure inference HTTP deadlines.
The query budget applies once the store admits a query; it cannot interrupt a
store callback already blocked in disk I/O. Serialized DETS writes/sync and
individual very large reads can still delay the store. Full repair enumeration
remains proportional to the number/size of repair records; this patch does not
introduce a paginated public API or promise constant-memory collection replies.

## Pool status and discovery

Receipt counts are loaded once using bounded, status-only DETS projections.
Subsequent receipt changes update cached counts. `status/0` no longer scans or
copies receipt payloads. Counts are reconstructed on restart; operators must not
mutate the receipt table behind the pool or reset receipts to fix availability.

Existing `capacity/1` semantics are retained. New status fields are separate:

- `available_capacity`: currently usable free slots per role, not a queue count.
- Per node: `available_slots`, `saturated`, and `oldest_inflight_ms`.
- Separate generation latency and `probe_latency_ms`.
- Sanitized `last_error`, `last_request_error`, and request/probe timestamps.
- Runtime defaults, active probe count, and cached receipt state counts.

A successful catalog probe does not erase the last generation error. A later
successful generation clears it. Diagnostics expose allowlisted codes, HTTP
status, transport phase, and safe reason atoms only, not upstream bodies,
headers, prompts, tokens, vault references, filesystem paths, or stack traces.

Automatic probes are deduplicated per live node/configuration. Tokens and probe
references reject stale results; monitored probe death releases the probe slot.
A node cannot become routable solely because its *first failed* probe put it in
`degraded` health. A previously verified node can still use the configured failure
threshold. This is not a full generation circuit-breaker redesign.

`refresh/0` remains discovery-only. It does not reload deployment configuration.
The ambiguous-paid-request receipt policy is unchanged. In particular,
`inference_uncertain` is not silently retried and existing uncertain receipts
are not cleared.

## Dashboard configuration and status

A saved dashboard registry replaces the complete deployment node list. An
explicitly empty registry must remain empty; automatically merging deployment
nodes could re-enable disabled processing or remote data transfer.

The settings response now includes a credential-redacted deployment node list
separately from the effective saved configuration. The panel identifies omitted
deployment nodes and offers **Import missing deployment nodes (disabled)**.
This action changes only the unsaved draft. It does not change role consent,
enable nodes, contact providers, or save anything automatically. Deployment
endpoints and inherited advanced options are captured when the settings service
starts; update deployment config and restart through the normal procedure when
changing that trusted baseline.

To restore omitted local/LAN nodes:

1. Sign in as an authorized node administrator and open AI providers.
2. Import the missing deployment nodes. Review their hosts, models, roles,
   credential source and any required non-loopback role consent.
3. Save them disabled, test saved model discovery, then enable the desired nodes
   and save again. A successful catalog test is not proof that generation works.

Manual discovery now uses the saved health timeout and bounded connection
budget, preserves stricter response caps, checks whether the configured default
model exists, and rejects results from a stale configuration revision. For an
unchanged deployment endpoint, saving now retains its inherited proxy policy
and any smaller response-size cap instead of forcing direct transport/8 MiB.

The panel joins the existing 12-second shell poller. Polling is read-only,
visible-panel-only, suppresses overlaps, preserves dirty drafts and queued keys,
and respects identity/navigation epochs. It shows live saturation, request
age, diagnostic details and sample time. A failed refresh is shown as unavailable,
not stale healthy. Editor selection is disabled during a manual probe/save so
an asynchronous result cannot populate a different selected connection.

Existing server-side administrator checks, endpoint allowlists, consent gates,
revision conflicts, destination-bound vault references, write-only key behavior,
and explicit empty-registry semantics are retained. Browser tests use a simulated
API; server authorization and real vault/network behavior still require runtime
integration tests.

## Timeout interpretation

Tune queue wait, connect, provider request, and health-probe deadlines separately.
For the reported burst workload, a starting experiment is a 900000 ms queue
budget and 20000 ms health budget, while retaining the existing 600000 ms cloud
request budget until its actual failure phase is known. These values are operator
choices, not newly forced defaults or measured guarantees.

When dashboard settings are active, set the shared queue/health values there.
`cluster_attempts` and `queue_timeout_ms` inside a node entry remain ignored:
request options or the shared pool defaults control them. Existing callers may
supply request-specific deadlines, and those overrides are deliberately retained.
Existing requests keep the deadlines/endpoint options already selected.

Three occupied slots mean saturation, not necessarily stuck requests. Increasing
queue wait does not create throughput. Do not increase provider concurrency
beyond the capacity actually available to the deployment/account.

## Build, tests, and rollout

Run from the complete DamageBDD umbrella repository, not this ECAI-only archive:

```bash
rebar3 compile
rebar3 eunit --module=ecai_learning_store_tests,ecai_llm_pool_reload_tests,ecai_llm_settings_tests,ecai_inference_diagnostics_tests
python3 apps/ecai/test/test_inference_status_recovery_contract.py -v
python3 apps/ecai/test/test_llm_settings_contract.py -v
node --check apps/ecai/priv/static/js/ecai-llm-settings.js
node --check apps/ecai/priv/static/js/ecai-console.js
CHROMIUM_PATH=/usr/bin/chromium python3 apps/ecai/test/test_llm_settings_browser.py
```

Python/Playwright and Chromium are required by the browser test. The default
Chromium path can be overridden with `CHROMIUM_PATH`.

Both store and pool record layouts change. **Do not hot-load these modules over
old process state.** Use a controlled ECAI/application or node restart. Stop
initiating background work and drain paid inference before stopping services;
there is no force-kill or automatic drain command in this patch. Take consistent
state backups only after an orderly stop or with an appropriate filesystem
snapshot. Never delete the learning store or inference receipts as a workaround.

After restart, inspect:

```erlang
ecai_learning_store:status().
ecai_llm_settings:status().
ecai_ollama_pool:status().
```

Check the configuration source/revision, imported node enablement, healthy model
discovery, free slots, request ages, active/queued store queries and any saved
request error. Re-run a known small workload before resuming a full backlog.

## Validation boundary for the prepared patch

Performed: JavaScript syntax checks; nine available existing static settings
contracts; eight new static recovery contracts; Chromium browser tests covering
existing settings behavior and new polling/saturation/recovery cases.

Not performed: Erlang compilation/EUnit (no `erl`, `erlc`, or `rebar3` in the patch
preparation environment), live cloud/LAN inference, large real DETS benchmarks,
full umbrella integration, or real server-side authorization/vault tests. The
existing Damage bridge static contract requires `apps/damage`, absent from the
supplied archive, and was not run. EUnit regressions are included for downstream
execution; the browser suite is not evidence that Erlang modules compile.
