# Knowledge search and indexing workspace

## Apply and restart

This incremental change is based on `ecai-knowledge-search-current.tar.gz` for
`ecai-console.js`, `ecai-console.css`, the console Mustache template and
`damage_theme_manifest.erl`. The two Wikimedia backend modules come from the
previously supplied `latest-ecai.tar.gz`. It preserves the current knowledge
retrieval endpoints and existing model-internals, chat, evaluation and queue
integrations; it does not replace the older Quick Index module.

From the monorepo root, apply the patch only after `git apply --check` succeeds.
Do not force a failed hunk onto a newer backend module.

```sh
git apply --check /path/to/ecai-knowledge-workspace.patch
git apply /path/to/ecai-knowledge-workspace.patch
rebar3 compile
rebar3 eunit --module=damage_theme_ecai_palette_tests
rebar3 eunit --module=ecai_wikimedia_sample_startup_tests
node --test apps/ecai/test/knowledge_search_model.test.mjs
```

Restart the node through its usual development or release launch procedure,
then hard-refresh the console. The backend restart matters: an already-running
anonymous fixture process and its old dynamic child specification do not become
registered merely because the module was hot-reloaded. Do not restart in the
middle of an important indexing run.

## Search behaviour

Typing issues a request after a 300 ms pause; Enter submits immediately. Empty
input cancels work and clears results. IME composition does not submit partial
compositions. In-flight search and retained-source requests are canceled when
superseded, hidden, or invalidated by an identity change. A monotonically
increasing request sequence and the account epoch also reject stale responses,
even when cancellation arrives too late.

This is client-side incremental search against the existing
`POST /ecai/knowledge/search` API, **not** a new prefix index, Google backend,
suggestion provider, server streaming protocol or ranking algorithm. A backend
may not match an incomplete word. Rankings, access control and source integrity
remain server responsibilities. Canceling a fetch does not promise that backend
computation has already stopped.

Readable titles prefer retained record titles/names over machine-heavy previews.
Snippets highlight literal query words using text nodes, never HTML. Account
addresses and long hashes are hidden only from the short preview, not removed
from the source or original preview in Technical details. Source retrieval still
uses `POST /ecai/knowledge/source` and the backend-provided `source_ref`.

The viewer reports partial backend availability, missing previews, failures and
source completeness. It preserves the prior results while a new search is
pending or failed and labels which query those older results belong to.
Superseded source buttons are disabled until current results arrive.

Live-build results may refresh every three seconds, but polling pauses while
source or technical details are open, while a source request is active, when the
panel/tab is hidden, and after errors. Search/source requests have a 30-second
client timeout. No results or source text are persisted in browser storage.

## Visible test flow: Quick Index

Use a managed email session. Wallet-only identity is not sufficient for enqueueing
through the existing Quick Index boundary. The node's index-jobs subsystem,
searchable index backend and configured IPFS service must be working.

Open **Index jobs**. A **Try the complete indexing flow** sample panel sits above
the normal Quick Index card.

1. Choose **Load 3-record sample**. This loads the bundled UTF-8 JSONL file into
   the existing File input and starts its existing detection/inspection handler.
   Loading a sample does not enqueue it. An actual downloadable JSONL file is
   also available in this panel.
2. Review the detected format, three-record estimate and SHA-256 identity in
   Quick Index. Then explicitly choose **Index detected source**. The existing
   handler sends the inspected SHA-256 and an idempotency key and stages the
   bytes through IPFS before enqueueing the real durable job.
3. Follow the job in **Execution history**. Expand it to inspect progress,
   events and any failure. A successful enqueue is not a completed index. Wait
   for successful completion/finalization before requiring a finalized result;
   live previews can become searchable earlier.
4. Choose **Search sample**, or type `orbital orchard` in **Knowledge search**.
   Open **Retrieve source** and check the returned text and reported integrity/
   completeness. `kinetic lighthouse` and `cedar observatory` exercise the other
   two records.

The checked-in file is:

```text
apps/ecai/priv/static/samples/knowledge-smoke.jsonl
```

It contains three synthetic, public test records: Orbital orchard — irrigation
check; Kinetic lighthouse — battery check; Cedar observatory — sensor check.
The file is served through the existing static route at
`/static/samples/knowledge-smoke.jsonl`.

Do not substitute confidential material in this public/searchable workflow.
Quick Index stages public source bytes in the configured IPFS store. Use the
existing Knowledge & privacy workflow for confidential corpora. No new payment,
cloud dispatch or NFT-mint action is triggered by the sample controls; existing
node policies, resource limits and storage costs still apply to jobs you enqueue.

## Visible test flow: Wikimedia

Open **Wikimedia**. A **Wikimedia smoke sample** panel is now above the preset
picker instead of relying on a faint preset card to reveal the test flow.

Choose **Check sample service** first. This calls the existing public
`GET /ecai/wikimedia/sample` endpoint and displays its actual status. Choose
**Select only smoke preset**, then use the existing **Add selected to index
queue** button and confirmation. Only `laptop-smoke` is selected; the other
presets are deselected. Selecting a sample does not itself enqueue a job.

The shipped fixture has four inputs: Quantum mechanics, Classical mechanics,
Physique quantique and Noise. The smoke preset selects the top three by fixture
pageviews and excludes Noise. Quantum mechanics and Physique quantique share a
Wikibase entity for deduplication coverage, so three selected inputs need not
become three distinct final entities/search hits. Do not assert an exact global
search result count on a node that already contains other indexed material.

Follow download, selection, indexing and finalization in Index jobs, then search
`Quantum mechanics` and retrieve the source. The preset uses local bundled
files rather than external Wikimedia downloads. Generating a final NFT manifest
is not the same as minting an NFT; no automatic minting or payment was added.

The existing bundled files must be included in the ECAI release:

```text
priv/wikimedia-fixtures/enwiki_content-20260720-00000.json
priv/wikimedia-fixtures/enwiki_content-20260720-00000.json.bz2
priv/wikimedia-fixtures/pageviews-202606-user.txt
priv/wikimedia-fixtures/pageviews-202606-user.txt.bz2
```

Read-only checks on a local default-port node:

```sh
ECAI_URL='http://127.0.0.1:9003'
curl --fail --silent --show-error "$ECAI_URL/ecai/wikimedia/sample"
curl --fail --silent --show-error "$ECAI_URL/ecai/wikimedia/sample/catalog"
curl --fail --silent --show-error "$ECAI_URL/static/samples/knowledge-smoke.jsonl"
```

Change the URL to the node's configured ECAI listener. When indexing inside a
container, the rewritten sample URL must be reachable from that worker using the
existing `wikimedia_sample_api_host` and listener-port configuration. This change
does not widen the source-fetch allowlist or disable source validation.

### Why the smoke preset previously returned `not_running`

The sample helper cold-started a supervised fixture with `#{port => 0}`. The
nonempty-options child spec invoked `start_link/1`, whose intentional behaviour
is to create an **anonymous** process for isolated tests. Production reads such
as `catalog_path/0` locate the **registered** process name, so they reported
`not_running` despite a child having started.

Production child specs now use `start_link_registered/1`, preserving anonymous
`start_link/1` for isolated tests. Supervision ownership checks also verify the
actual registered PID. API catalog writes use distinct temporary filenames so
concurrent status/preset requests do not race over one `.tmp` file.

For the OTP registration distinction, see the official `gen_server`
`start_link/3` and `start_link/4` documentation at erlang.org.

## Theme fixes

The theme adapter now maps ECAI's `--paper` and `--canvas` together with ink,
muted text, secondary surfaces, links, borders, navigation and action colours.
Primary-button text is derived from the accent's contrast. Success, warning and
error colours select readable light/dark variants. This does not change the
serialized NFT theme manifest or its token identity.

The generic text-input selector excludes checkboxes/radios; those controls use a
bounded 18-pixel size and inline labels. A late, scoped workspace stylesheet
removes hardcoded light surfaces from search results, Wikimedia presets and
plans, Quick Index, job cards, progress and checkpoints. Existing layout and
other feature controllers remain in place.

## Regression tests and validation limits

```sh
node --check apps/ecai/priv/static/js/ecai-console.js
node --check apps/ecai/priv/static/js/ecai-knowledge-search.js
node --check apps/ecai/priv/static/js/ecai-index-samples.js
node --test apps/ecai/test/knowledge_search_model.test.mjs
python3 apps/ecai/test/test_knowledge_workspace_browser.py
```

The browser test needs Playwright and Chromium. It accepts a system `chromium`
or `CHROMIUM_EXECUTABLE`. Normal mode uses intercepted local test routes and the
actual ESM loader. `ECAI_OFFLINE_BROWSER=1` instead inlines local styles, executes
the same module bodies with explicit import bindings, and uses in-memory HTTP
and EventSource doubles. This mode requires no navigable HTTP origin. Neither
mode contacts a live node, IPFS, a chain or a payment service.

The new EUnit tests check theme CSS generation and cold fixture startup,
concurrent catalog writes and supervisor restart. Run them in an isolated EUnit
VM, not through a production node shell.

See `knowledge-workspace-validation.md` for the checks actually executed while
preparing this patch. Browser simulation does not establish live queue/index/
source availability or replace the manual node smoke flows above.
