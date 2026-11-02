# Task-focused sidebar and settings launchers

## Navigation

Workspace: Overview, Conversation, Knowledge search.
Knowledge: Index jobs, Knowledge & privacy, Wikimedia.
Create: AI personalities (when present), Video Studio.
More tools (collapsed initially): LLM evaluation, Mathematical paths, Marketplace,
Market Maker, Funded indexing, Code learning & repair, Operations and API explorer.
The generator preserves additional unrecognized navigation buttons in More tools.

Settings stays at the bottom: Account settings, Compute, API keys, Node settings.
The existing single footer node indicator remains below Settings. Its online flag
still reflects the existing chat-endpoint check, not proof that every service is
healthy. The footer opens Node settings. Detailed per-service checks remain on
Overview and task-specific warnings, job progress and authentication notices are
not suppressed.

Removed from the shell: the decorative dot under the fallback brand symbol,
the topbar connection sentence, and the three Existing tools shortcuts. The logo
and brand template variables remain intact. Legacy routes and contextual links
such as the advanced index builder are not deleted.

## Settings scope

Account settings is a session and preferences launcher: sign in, create account,
connect wallet, switch account, sign out, plus links to existing API key, privacy,
Compute and index-mint preferences. It is NOT a new profile/email/password editor.
Sign-in actions reuse DamageAuth; sign-out invokes the existing sign-out control,
which retains server-side revocation behaviour. No token, key, personal settings
or profile data is written into browser storage by this module.

Node settings is a capability-aware entry point to existing administrator
settings and diagnostics. Administrators can open learning/repository/review-gate
settings and Operations. Guests and wallet-only sessions see an access explanation,
not node configuration forms. Role checks for navigation use the current validated
console state; the existing server handlers still authorize all requests. Opening
settings does not save, invoke inference, run ingestion, reserve spend or mint.

No Erlang, endpoint, storage schema, Compute policy or minting behaviour changes.
New dashboard hashes: #account and #node-settings. Existing hashes are preserved.

## Interaction and accessibility

The workspace list scrolls independently of the Settings/footer area. Very short
landscape viewports scroll the whole menu so nothing becomes unreachable.
More tools uses a native details/summary control and expands automatically for an
active nested deep link. Existing hidden administrator/funded-indexing buttons
and their IDs are retained; no privilege is inferred from clicking a link.

The mobile drawer has an explicit expanded state, inert off-screen controls,
Escape-to-close, keyboard focus containment and return-to-trigger on dismissal.
The page behind an open drawer is inert. Changing view closes the drawer, resets
page scroll and focuses the new heading; refreshing the same page does not steal
focus. Styles reuse node palette tokens and avoid restyling other workspaces.

## Apply

The reference patch was generated from the uploaded ECAI archive, the later
uploaded console template, and the provider, recovery, login, index-mint and
Compute-only changes supplied in this conversation. Your full checkout has newer
feature code that is not in that archive.

For a differing checkout, use the accompanying generator:

    python3 ~/Downloads/make_ecai_sidebar_settings_patch.py \
      --root . --output /tmp/ecai-sidebar-settings.local.patch
    git apply --check /tmp/ecai-sidebar-settings.local.patch && \
      git apply /tmp/ecai-sidebar-settings.local.patch

The generator reads current files and writes only a patch. It preserves additional
navigation entries, longer script versions, role hooks and unrelated code. Unknown
footer content, duplicate routes, missing/ambiguous anchors, existing settings
implementations or symlinks abort before output is replaced. Do not reuse an old
output after a generator error. Review the diff before applying. No staging,
committing, Git reset, service access or source edits are performed by generation.

Do not reapply the earlier feature patches or replace the whole console template
with an older copy. Deploy the updated template, console controller and both new
assets together. The controller imports the new settings module. A missing module
prevents it from loading, so confirm both new files exist in the running ECAI priv
static directory. Normal asset-release deployment and a hard refresh are required;
no new server routes or router reload are introduced by this patch. There is no
reason to clear account/browser storage.

## Validation

    python3 apps/ecai/test/test_console_sidebar.py
    python3 apps/ecai/test/test_console_sidebar_browser.py
    node --check apps/ecai/priv/static/js/ecai-console.js
    node --check apps/ecai/priv/static/js/ecai-console-settings.js

Browser tests require Playwright and Chromium; ECAI_CHROMIUM can select the binary.
ECAI_SIDEBAR_SCREENSHOTS optionally saves responsive previews.

These tests use the production template, console routing, Compute controller and
settings module in a DOM-only adapter. Browser HTTP navigation is blocked in the
validation environment: import URLs are resolved to data URLs, location/history
and API/session responses are mocked, and external auth/video/market controllers
are stubbed. The node theme is a labelled light/dark token fixture because the
live DamageBDD theme stylesheet is not supplied. No live auth, cloud or blockchain
calls are tested. Newer feature controllers absent from the archive are preserved
by generation, not claimed to have been integration-tested.
