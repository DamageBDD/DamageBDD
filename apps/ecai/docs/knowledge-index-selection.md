# Knowledge search: explicit index selection

## Baseline and deployment

Apply `ecai-knowledge-index-selection.patch` after the previously supplied
`ecai-knowledge-workspace.patch` (UI) and `ecai-knowledge-prefix.patch` (backend).
This incremental patch was built against the current backend upload plus the
prefix overlay, and the current UI upload plus the workspace overlay. It is not
a replacement for those patches. It does not alter stored indexes or contracts.

```sh
git apply --check "$HOME/Downloads/ecai-knowledge-index-selection.patch"
git apply "$HOME/Downloads/ecai-knowledge-index-selection.patch"
rebar3 compile
rebar3 eunit --module=ecai_knowledge_indexes_tests
rebar3 eunit --module=ecai_knowledge_prefix_tests
node --test apps/ecai/test/knowledge_search_model.test.mjs apps/ecai/test/knowledge_indexes_model.test.mjs
```

Restart via the node's normal startup procedure to install the new Cowboy route,
then hard-refresh the browser. Hot-loading only the Erlang handler does not
update a previously compiled Cowboy dispatch table. No re-index, NFT mint,
payment, new configuration file, or new application dependency is required.

## Search indexes accordion

The accordion sits below the search field and above the results. It groups
server-provided logical IDs into Shared live, Wikimedia, Published disk, and
Your funded indexes. Each checkbox displays a name, logical ID, visibility
scope, and an advisory availability state.

* All indexes is the initial mode. It includes newly configured/published indexes
  on subsequent queries. It does not silently exclude unavailable services.
* Unchecking or checking a row creates an explicit list of IDs. New catalog
  entries are not automatically added to that explicit list.
* Clear selection pauses UI searching and removes old results. Enter, typing,
  and live refresh cannot turn it back into an all-index query.
* Selecting another scope clears old result/source views, aborts superseded
  requests, and re-runs the current query. Response guards include the selection
  as well as the query, result count, and authentication epoch.
* Refresh list does not change selection. A selected ID missing from the refreshed
  catalog is retained as “No longer listed” until unchecked. An outdated ID causes
  an explicit server error, not a broader search.

Selections and catalog data live only in this page's memory. They survive tab/view
navigation within the console, not reloads. Sign-in, sign-out, or switching
accounts resets the selection to all and discards the old catalog and results.
Late catalog, result, and source responses cannot restore another identity's data.

The catalog is loaded on entering the search view or opening the accordion, with
an explicit refresh/retry button. Catalog failure leaves the selection unchanged;
unfiltered default searches can still work while the catalog is unavailable.

Availability checks do not run queries, load snapshots, verify every segment, or
prove that an index contains matches. Shared/Wikimedia check registered process
presence; disk checks public-store eligibility and its docstore marker; funded
entries check the manifest file exists. Actual query status replaces the advisory
status after a response. Unavailable entries remain selectable so they can be
retried after recovery. Private encrypted corpora are not added to this public
search interface.

## API contract

### GET /ecai/knowledge/indexes

Reuses the knowledge API's existing session/Bearer authentication. Guests receive
public IDs; authenticated callers also receive their own accepted funded manifest
IDs. Explicit invalid Authorization headers remain 401. The handler never takes
an owner/principal from the request body.

Example entry:

```json
{
  "id": "shared",
  "label": "Shared live index",
  "description": "Records in the shared in-memory index",
  "kind": "shared",
  "scope": "public",
  "state": "ready"
}
```

The response contains `ok`, `indexes`, `default_selection: "all"`, `partial`, and
`backends`. No local directories, manifest paths, snapshot paths, credentials, or
arbitrary manifest fields are returned. Disk entries use their configured logical
ID as the label. Funded IDs have the form `pool:<pool_id>`. IDs are not document
filenames, individual records, or every indexing job. Multiple source files may
be stored together in one logical index.

`partial` on the catalog concerns discovery, not query matches. An unavailable
funded coordinator is reported as a discovery failure instead of pretending the
caller has no funded indexes. The UI keeps the selected IDs even when discovery
is incomplete.

### POST /ecai/knowledge/search

```json
{"q":"redire","limit":10,"matching":"bool_prefix","indexes":["shared","public-ipfs"]}
```

`indexes` is optional. Omission or the literal string `"all"` retains all-index
behaviour. An array selects exactly those logical IDs; `[]` selects none and
returns zero results, zero backend states, and `partial: false` for a valid query.
`null`, a scalar ID, objects, non-string elements, empty IDs, IDs over 128 bytes,
and arrays over 128 elements are rejected. Duplicate IDs are canonicalized.

Every explicit ID is resolved against operator-configured public indexes and/or
caller-owned funded manifests BEFORE any query worker starts. An unknown ID and
an unauthorized funded ID both return `400 invalid_index_selection`. A funded
registry outage while validating a funded selection returns
`503 funded_indexes_unavailable`; it does not fall back to public indexes.
A public-only selection does not contact the funded coordinator during search.

Only selected backends contribute hits, reciprocal-rank fusion, status entries,
and partial-result warnings. A selected backend failure is reported; an unselected
backend failure cannot mark that response partial. All-index mode reports funded
discovery failures separately in `backends` so missing coverage is visible.

The response echoes its resolved selection:

```json
{"selection":{"mode":"selected","indexes":["public-ipfs","shared"]}}
```

For all mode, `mode` is `"all"` and the list contains the indexes actually resolved
for this request. If discovery was incomplete, inspect `partial` and `backends`.

The browser rejects a filtered response without the expected selection echo.
This avoids silently showing all results when frontend assets are newer than the
backend. Existing clients that omit `indexes` continue to work. Existing final-word
prefix/exact semantics, ranking, owner checks, and source-integrity checks are
unchanged. RAG/context callers still request their existing all-index legacy mode.
Search selection is not a new authorization policy; source retrieval retains its
independent access and version checks.

### GET search

Use one `indexes` query parameter containing `all` or a JSON array:

```sh
BASE='https://your-node.example'
curl --fail-with-body -sS --get "$BASE/ecai/knowledge/search" \
  --data-urlencode 'q=redire' \
  --data-urlencode 'indexes=["shared"]'
```

Repeated `indexes` query parameters are rejected rather than keeping the last one.
POST is simpler for an array. Body-size, query-size, result-count, prefix-expansion,
and backend-timeout limits already applied to knowledge search remain in force.

## Smoke checks

1. Open Knowledge search, expand Search indexes, and query a retained record.
2. Clear selection. Results disappear and no search request should be sent.
3. Check only Shared live. A request carries `indexes: ["shared"]`. The response
   contains only a `shared` backend status (even when Wikimedia is unavailable).
4. Select a configured disk index alone. Its matches should appear without shared
   results. Retrieve source to exercise the unchanged integrity check.
5. Sign in as an owner with an accepted funded manifest. Only that owner's funded
   IDs should appear. A direct request for another owner's ID must fail.
6. Change selection during a slow search or source request. Its late response must
   not reinsert old-scope results. Refresh the catalog and switch accounts to check
   that neither action silently widens an explicit selection.

A DamageBDD feature using the existing HTTP steps is included at
`apps/ecai/priv/features/knowledge/index_selection.feature`; set `ecai_api` to your
node. It covers none, shared-only scope, invalid path IDs, and null rejection.

## Validation for this delivery

Executed: 11 Node model tests; eight existing static source/auth/privacy checks;
the previous search component's Chromium regression
suite; and the new index-selection Chromium suite covering payloads, scope races,
source cancellation, identity isolation, catalog failures/removals, explicit all,
backend echo checking, limited-vs-unavailable warnings, keyboard operation,
text-only labels, and dark/forest/violet desktop/mobile rendering. The browser
uses the production template, CSS, and module bodies with mocked backend replies;
it does NOT demonstrate real backend search, authentication, IPFS, or payments.
Rendered selector caption contrast checks pass at 4.5:1 or above for those three
fixture palettes; this is not an accessibility audit of every app/theme.

Added but not executed here: `ecai_knowledge_indexes_tests` EUnit assertions and
its real Cowboy HTTP contract test, and the DamageBDD feature. Erlang/rebar3 are
not installed in this environment, and package installation failed. Run the
compile and EUnit commands above on your node before committing. Existing source
retrieval, private-index guards, funded owner callbacks, disk/snapshot readers,
and the prefix engine are reused without implementation changes.
