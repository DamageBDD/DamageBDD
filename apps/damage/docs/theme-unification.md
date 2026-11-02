# Cross-application theme paint repair

## Scope and source baseline

This incremental patch was built against the four fresh archives supplied for the
cross-app styling review: `latest-damage.tar.gz`, `latest-ecai.tar.gz`,
`latest-nosternity.tar.gz`, and `latest-bop.tar.gz`. It is not based on earlier
search/theme overlays. Run `git apply --check` before applying to a newer checkout.
Do not force failed hunks or replace an entire application directory.

The review covers the first-party palettes in those four applications. ERM was
not supplied: it inherits the shared renderer's roles, but its components were
not inspected or migrated. This is a paint and theme-integration change, not a
redesign of workflows, information architecture or typefaces.

## Findings and corrections

| Source | Finding in the uploaded files | Correction |
|---|---|---|
| `damage_theme_manifest.erl` | Six NFT colours and selected legacy aliases were emitted, but several `--ws-*` and component-local palettes remained independent. | Derive a common set of semantic roles; explicitly map workspace canvas, panels, inputs and paired accent text. |
| ECAI `ecai-console.css`, `ecai-math-paths.css`, `ecai-personalities.css` | Fixed white/light cards and hardcoded dark captions survived while inherited headings became pale. | Pair each owning component's surface and text with the same theme, including result/trace cards, review cards, personality bodies and the conversation personality bar. |
| ECAI `ecai-auth.css`, `ecai-compute-settings.css` | Local palettes and OS dark-mode rules could override node selection. | Keep isolated component aliases, but resolve them through semantic roles. The OS/local mode is now a fallback only. |
| Damage `dashboard-workspace.css`, `dashboard-wallet.css`, `schedules-v2.css`, `billing.css` | `.damage-dashboard`-scoped palettes overrode inherited body variables; several green/blue gradients and focus glows remained fixed. | Map the class-local aliases and primary/hover/focus/status paints, not only `:root`. Keep distinct semantic success/warning/error colours. |
| ECAI learning settings | Text-field styling also caught checkboxes and vertical form-label layout affected toggles. | Exclude checkboxes/radios from full-width text-field rules and keep labelled toggles inline. |
| Damage billing/wallet | Long invoice headers could collide and wallet metric labels could split inside words. | Use a contained horizontally scrolling invoice table and normal word wrapping for metric captions. |
| Nosternity `dashboard.css` and public shell | Minified fixed green/light palettes, an orphaned font-import fragment, and an inverse button using the text token as its background. | Repair the stylesheet prelude; use semantic paints and explicit accent/on-accent button pairing. |
| BoP `bop_app.erl`, assets and publishing snippet | Theme selection was supported by the package schema but BoP had no theme CSS route/loading path. Local dark mode owned the colours. | Add a read-only CSS route and loader; map both local-mode styles to node roles. Keep local light/dark fallback when the endpoint is absent. |
| Runtime-generated styles | Feature picker and payment/wallet helper code set old inline colours after stylesheet load. | Change only their paint strings. Preserve event handling, data, expiry behavior and QR encoding. |

The ECAI “branch not allowed”/learning-paused message in the supplied screenshot
is a runtime policy result. This patch does not loosen it or change allowed
branches, learning state, repository permissions, review approvals or publication.

## Semantic contract

NFT packages still use exactly six `damage-theme/v1` colours: `background`,
`surface`, `text`, `muted`, `accent`, and `border`. The validator, built-in package
records, canonical serialization and package-hash implementation are unchanged.
No NFT remint, contract deployment, IPFS republish or index rebuild is needed.

`damage_theme_manifest:css/2` derives `--theme-*` CSS roles at render time:

- Canvas/surface/input: `bg`, `surface`, `surface-alt`, `input`.
- Text/actions: `text`, `muted`, `link`, `accent`, `accent-hover`, `accent-soft`,
  `on-accent`, `focus`, `control-border` and `border`.
- Status pairs: `success`, `danger`, `warning`, `info`, their `*-soft` surfaces
  and `on-*` text; these are status meanings, not branding accents.
- Effects/native controls: `shadow`, `focus-glow`, `backdrop`, `color-scheme`.

Components consume those roles at the declaration that owns the paint, e.g.:

```css
.code-settings-card {
  background: var(--theme-surface, #fff);
  color: var(--theme-text, #14223d);
}
.wallet-primary-button {
  background: var(--theme-accent, #9fe15b);
  color: var(--theme-on-accent, #0b1608);
}
```

Fallback colours keep standalone pages usable if no theme CSS is served. They
are not active overrides of a loaded node palette. Existing `--ws-*`,
`--wallet-*`, `--compute-*`, auth, billing and ECAI aliases are kept for compatibility
and component isolation. There is no global `!important` recolouring layer.

For text, muted labels and links, the renderer retains the supplied colour when
it reaches its contrast target on both canvas and surface. Otherwise it moves
minimally toward the better black/white endpoint. It does **not** write that
colour back into the package. Arbitrary custom themes with incompatible opposing
surfaces may not admit one readable foreground; this is not a certification of
all custom NFTs or every possible state. Primary-action text is paired with its
actual accent fill; hover does not blindly brighten the fill under white text.

### Deliberate independent colour contexts

QR payloads and white quiet zones are unchanged. Personality artwork, logos,
media, previewed theme swatches, and the theme editor's preview palette remain
independent of the surrounding UI. Preview labels now use preview tokens too.
Third-party syntax grammars and print output are not blanket recoloured. Semantic
error/success colours remain distinguishable rather than becoming the branding
accent. The raw-paint test contains explicit exceptions for these contexts.

## Loading, caches and BoP deployment

Application shells load their palette after first-party styles. Standalone ECAI
chat/search/indexer pages, Damage node settings and Theme Studio load it as well.
Node settings uses the server-substituted `__APP__` identity, not a hardcoded
Damage palette. Local stylesheets are cache-versioned `theme=semantic-v2`.
Schedules recognise an already-versioned stylesheet instead of loading another
unversioned copy after the palette.

BoP adds `/api/themes/css` to its own Cowboy dispatch using the existing shared
handler. The supplied BoP static export assets are kept in both `priv/assets/`
and `priv/public/assets/`; the corresponding files are updated identically.

**Existing exported `.html` and `.html.asc` files are not rewritten.** Their
existing `theme.js` adds the palette link at runtime. Future Org exports get the
link directly from `priv/snippets/header.html`. If the stylesheet really loads,
BoP's local theme-toggle button is disabled and explains node ownership of the
palette. If it does not, local light/dark selection still works.

A separately hosted BoP static website must proxy the same-origin
`/api/themes/css` request to the configured node listener (whose shared Damage
services must be available). This patch does not change nginx or choose a proxy
upstream. A static site with no such route intentionally falls back to its local
palette. Do not expose an admin/configuration API just to serve this read-only
CSS endpoint.

## Apply and verify

Run from the monorepo root after downloading the patch:

```sh
git apply --check "$HOME/Downloads/damage-cross-app-theme-fix.patch"
git apply "$HOME/Downloads/damage-cross-app-theme-fix.patch"
rebar3 compile
rebar3 eunit --module=damage_theme_manifest_tests
rebar3 eunit --module=damage_theme_ecai_palette_tests
rebar3 eunit --module=damage_theme_semantic_tests
node --test apps/ecai/test/knowledge_search_model.test.mjs apps/ecai/test/knowledge_indexes_model.test.mjs
```

Restart normally after compilation so the new BoP route and changed templates are
loaded. Hard-refresh open apps; refresh BoP assets on its static host too. A full
restart is not a request to delete theme configuration or to remint anything.

### Optional browser/static checks

The tools in `test/theme-test-requirements.txt` are test-only dependencies. Use a
separate Python virtual environment and a local Chromium installation, or the
Playwright-managed Chromium browser. The test uses `chromium` from PATH when
present and otherwise uses Playwright's installed browser.

```sh
python3 -m unittest discover -s apps/damage/test -p test_theme_unification_contract.py -v

# Emits the real pure Erlang renderer's CSS without starting node services:
escript apps/damage/test/export_theme_css.escript /tmp/damage-theme-css
THEME_CSS_DIR=/tmp/damage-theme-css \
  THEME_SCREENSHOTS=/tmp/damage-theme-review \
  python3 apps/damage/test/test_theme_unification_browser.py
```

Without `THEME_CSS_DIR`, browser checks use an explicitly labelled offline Python
reference of the palette derivation, using the built-in colours read from source.
That is useful for CSS work but does not verify Erlang compilation or endpoint
execution. The generated JSON report states which mode was used.

The browser suite renders the actual templates and styles with offline fixture
records and no production JS/API activity. It exercises 33 views in three palettes
at 1440 and 390 pixels, plus real dialog/error/focus states and the BoP loader's
available/unavailable branches. It checks sampled rendered-text contrast and
page-level overflow; locally scrollable diagrams/tables are allowed. Intentional
artwork, invisible and disabled controls are excluded. It is not a full browser
accessibility audit or a live functional test of billing, signing, search, jobs,
LLM inference or mathematical replay.

`THEME_WIDTHS` and `THEME_PALETTES` can restrict iteration when debugging;
`THEME_VERBOSE=1` logs each view. For final verification run the default matrix.

## New component checklist

Use semantic colours for UI surfaces and text together. Give accent and status
fills their matching foreground. Do not reintroduce local hardcoded OS palettes,
inline colours or unversioned late stylesheets. Keep checkboxes/radios out of
text-input geometry selectors. An intentional art/QR/preview context should own
both halves of its independent palette and have an explicit test exception.
