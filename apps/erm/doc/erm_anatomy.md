# erm anatomy viewer

A GTKGS anatomy viewer with automatic BodyParts3D and Open Anatomy downloads and a persistent local cache. Erlang handles networking, mesh preparation, camera, selection and visibility. The existing GTKGS picture widget displays software-rendered SVG frames.

## Launch

After applying the patch and running `rebar3 compile`, start the viewer:

```erlang
erm_anatomy:show().
erm_anatomy:status().
erm_anatomy:stop().
```

On first launch the window opens immediately, downloads the mapping table and official 99% reduced PART-OF mesh archive (about 62 MB), prepares the starter structures and displays them. Progress appears at the bottom of the window. Later launches verify and reuse cached downloads. Closing the window cancels the setup worker; failed setup leaves the window open with a Retry setup button.

The default starter structures are stomach, gallbladder, right kidney, left kidney and urinary bladder. This small set fits the current 50,000-triangle software-rendering budget. Large compound organs such as the complete heart or liver exceed that budget even in the reduced dataset. Unsupported or oversized selections fail visibly; meshes are never silently omitted or reduced by dropping faces.

Runtime dependencies are OTP `inets`, `ssl`, `public_key`, `crypto`, `stdlib`, `kernel`, a working OS CA certificate store, and the existing GTKGS stack. The patch declares inets, ssl and crypto in erm.app.src so release dependency resolution includes them; the downloader also starts inets and ssl when needed. No shell downloader, Python runtime or external unzip tool is used by the app.

## Configuration

No configuration is required for the default first launch. Optional entry inside the existing `{erm, [...]}` application settings:

```erlang
{anatomy, [
    {auto_fetch, true},
    {source, bodyparts3d_partof},
    {structures, [<<"stomach">>, <<"gallbladder">>,
                  <<"right kidney">>, <<"left kidney">>, <<"urinary bladder">>]},
    {download_timeout_ms, 120000},
    {up_axis, z}
]}.
```

Optional `data_dir` overrides the dataset cache root; by default it is `filename:join(filename:basedir(user_cache,"erm"),"anatomy")`, normally `~/.cache/erm/anatomy` on Linux. `cache_dir` separately controls temporary rendered frames (default `/tmp`). Structure requests accept exact English names (case insensitive) or FMA IDs. Set configuration before opening the viewer; close and reopen after changing it.

`auto_fetch=false` permits cached setup without network access and returns an explicit error when required downloads are missing or corrupt. This also works with a manually supplied dataset.

An optional `archive_sha256` accepts a lowercase hexadecimal string and enforces that digest for both new downloads and cache reuse. Without this setting, verified HTTPS authenticates the source and a locally recorded SHA-256 detects later cache corruption; it is not an upstream signed checksum.

## Known sources and mapping

```erlang
erm_anatomy_data:sources().
%% [bodyparts3d_partof, bodyparts3d_isa, openanatomy_brain,
%%  openanatomy_knee, openanatomy_abdomen]
```

Both source profiles use the official BodyParts3D archive, with matching taxonomy tables:

| Profile | Mesh archive | Mapping table |
| --- | --- | --- |
| `bodyparts3d_partof` | `partof_BP3D_4.0_obj_99.zip` (~62 MB) | `partof_element_parts.txt` |
| `bodyparts3d_isa` | `isa_BP3D_4.0_obj_99.zip` (~136 MB) | `isa_element_parts.txt` |

The tables map FMA concept IDs and readable names to **element file IDs**, often many per organ. The importer groups every mapped component under the organ's name. Representation IDs from the separate name table are not used as mesh filenames. Unknown names and missing archive components are errors.

Source URLs:

- https://dbarchive.biosciencedbc.jp/en/bodyparts3d/download.html
- https://dbarchive.biosciencedbc.jp/data/bodyparts3d/LATEST/partof_element_parts.txt
- https://dbarchive.biosciencedbc.jp/data/bodyparts3d/LATEST/isa_element_parts.txt
- https://dbarchive.biosciencedbc.jp/en/bodyparts3d/lic.html

Downloads and redirects are restricted to HTTPS port 443 on `dbarchive.biosciencedbc.jp`, `www.openanatomy.org` and `openanatomy.org`, with peer and hostname verification. Body sizes are bounded while streaming. Archive entries are inspected and selected files are extracted to memory, validated as OBJ, and written using element IDs. Archive paths are never used as extraction destinations. The manifest is published only after successful preparation.

Each selection has a directory containing its OBJ files, generated `manifest.config`, `source.config` provenance receipt and `ATTRIBUTION.txt`. The official current credit line is displayed in the UI and saved alongside the meshes: BodyParts3D, © The Database Center for Life Science licensed under CC Attribution 4.0 International.

The cache does not automatically poll for upstream revisions. Cached bytes are reused to preserve a working dataset. To deliberately refresh, close the viewer and remove the source profile's `meshes.zip`, `meshes.zip.sha256`, `elements.tsv` and `elements.tsv.sha256` from the cache, then reopen. Different bytes or structure selections create a different prepared directory.

## Manual datasets

An existing `manifest.config` directly in `data_dir` takes precedence and disables automatic preparation for that directory. Each entry uses binary `id` and `name`, integer RGB `color`, and either `file` or a nonempty list of `files` relative to that directory. The latter combines component meshes into one selectable structure. Example:

```erlang
[
 #{id => <<"FMA7148">>, name => <<"stomach">>,
   files => ["FJ2564.obj"], color => {190,100,100}}
].
```

All meshes must use shared world coordinates. `up_axis=z` is the default; use `y` for Y-up assets. Set `attribution` for a manual dataset. BodyParts3D attribution is supplied automatically for downloaded datasets.

## Controls and renderer limits

Search by name or ID and press Return. Select a list item to highlight it. Hide/show toggles that structure, isolate hides others, and show all restores visibility. Search filters the list only. Left/right/up/down rotate, zoom changes scale, and reset restores the camera. Bounds remain stable while hiding structures.

This is an opaque orthographic software renderer using triangle depth sorting. Intersecting geometry can have occlusion artifacts. It does not provide a GPU depth buffer, clipping, textures, transparency or medical image volumes. Picking follows the same triangle depth ordering as the renderer, so it shares its occlusion limitations. Upstream RGBA colours render opaquely. Nonconvex polygon faces should be triangulated before import.

Limits: 200 structures, 50,000 total triangles, 16 MiB per OBJ, 4,000 selected components and 256 MiB total extracted mesh bytes. Download caps are 100 MiB for PART-OF and 180 MiB for IS-A; metadata is capped at 2 MiB. Render operations are synchronous; dataset fetching and mesh loading run in a separate worker.

## Validation

The package compiles with warnings treated as errors on OTP 25. Included EUnit tests cover OBJ parsing/rendering, component mapping, selection errors, archive paths, missing meshes, offline cache reuse and corrupted-cache rejection. A live HTTPS download of the official mapping table and extraction/rendering of the official PART-OF starter meshes were also checked. Native C compilation and linking passed with warnings treated as errors. Native GTK display and physical mouse operation remain unverified: Xvfb could not open display sockets in this environment.

```sh
rebar3 eunit --module=erm_anatomy_mesh_tests,erm_anatomy_data_tests,erm_anatomy_vtk_tests,erm_anatomy_ui_tests
```


## Mouse controls and native rebuild

Apply `erm_anatomy_mouse_sources_rebased.patch` to the `latest-erm.tar(8).gz`
snapshot. This replaces the earlier patch that failed its apply check; that
failed check did not modify any files. The rebase preserves libshumate map
support and the existing atomic native install target.

Rebase validation: all 22 anatomy, map, GTKGS and controller EUnit tests passed
against this snapshot. Native compilation, linking, the hello capability check
and the Makefile install target passed without optional libshumate. Native map
rendering and physical mouse interaction remain unverified here.
The update changes the native C-node as well as Erlang modules. Build and install
that executable before restarting erm:

```sh
git apply --check ~/Downloads/erm_anatomy_mouse_sources_rebased.patch
git apply ~/Downloads/erm_anatomy_mouse_sources_rebased.patch
make -C apps/erm/c_src/gtknode4 install
rebar3 compile
```

The build requires the existing GTK4 development dependencies and Erlang `ei`
headers/library. The existing Makefile install target writes
`apps/erm/priv/bin/gtknode4`, which is the port supervisor's default executable.
If `gtknode4_cnode_executable` or a release points elsewhere, install the rebuilt
executable there through your normal build/package process. Restart the GTK stack
or erm after saving work in other GTK windows; Erlang module reloading alone
cannot replace a running native executable.

Start with `erm_anatomy:show().` The viewer checks the advertised
`pointer_events` capability. When an older native executable is still running,
it displays a rebuild hint and keeps the buttons usable. Inspect
`erm_anatomy:status().` for `mouse_supported`.

| Input inside the picture | Action |
| --- | --- |
| Left drag | Orbit; vertical rotation is bounded |
| Right or middle drag | Pan |
| Wheel / discrete touchpad scroll | Zoom between 0.1x and 8x |
| Left click without dragging | Select the frontmost rendered structure |
| Left double-click | Reset orientation, pan and zoom |

The renderer coalesces queued input into one pending redraw with a 33 ms delay;
this is a redraw limit, not a promise of 30 fps. Large meshes may render slower.
Drag updates use cumulative offsets so coalescing does not discard movement.
Picking accounts for picture scaling and letterboxing. Hidden parts cannot be
picked. Buttons, filtering and visibility controls remain available.

## Additional human anatomy atlases

Select an atlas in the sidebar and press **Fetch selected source**. Leave the
structure entry empty for the atlas's starter set, or enter exact names/IDs
separated by commas. The source selector stages a choice; fetching is explicit.
Only the chosen source is downloaded. Source changes cancel any previous setup
worker; stale completion messages cannot replace the current selection.

| Source | Catalogue | Starter set | Verified starter triangles |
| --- | --- | --- | --- |
| `openanatomy_brain` | 331 structures | Left/right hippocampus and amygdala | 14,890 |
| `openanatomy_knee` | 48 structures | Anterior/posterior cruciate ligaments | 40,564 |
| `openanatomy_abdomen` | 94 structures | Left/right kidney and gallbladder | 43,178 |

These are separate datasets with their own coordinates; the viewer replaces the
current dataset when switching sources. Catalogue counts reflect the metadata
checked on 10 October 2026 and can change upstream. Counts do not mean every
possible selection fits the renderer: the existing 50,000-triangle total limit
still applies, and oversized choices fail visibly. No mesh faces are dropped.

```erlang
erm_anatomy:load_source(openanatomy_brain).
erm_anatomy:load_source(openanatomy_knee, [<<"anterior cruciate ligament">>]).
{ok, Catalogue} = erm_anatomy_data:catalog(openanatomy_abdomen, #{}).
```

`load_source/1,2` needs a running viewer and starts setup asynchronously; watch
`status/0` for `ready` or `failed`. `catalog/2` returns the source's names and IDs
without fetching meshes. Its options accept `data_dir` and `auto_fetch`, just
like `ensure/2`. It is a synchronous operation intended for a shell or worker.
To select a default at startup, set `{source, openanatomy_brain}` in the anatomy
configuration. Explicit `structures` override that source's starter set.

The adapters read each official `atlasStructure.json`, resolve geometry
selectors, and fetch only the selected legacy VTK surface files. MRI/CT volumes
are not downloaded. The bounded Erlang VTK reader handles big-endian binary and
ASCII POLYDATA with polygons and triangle strips. It does not require VTK,
Python or a conversion process at runtime. XML VTK, VTK 5.x offset arrays and
volume datasets are not supported. The existing `jsx` application decodes atlas
metadata. Individual mesh downloads are limited to 16 MiB; metadata is limited
to 2 MiB. Meshes are cached and checked using SHA-256 sidecars. `archive_sha256`
continues to apply to BodyParts3D archives only.

Open Anatomy attribution, source URLs, checksums and the full upstream licence
page (`LICENSE.html`) are saved beside every prepared selection. The source
pages identify the licence as the **3D Slicer License, Part B**. Keep the licence
and attribution with redistributed data. These datasets are supplied for
research/education; no clinical suitability is claimed.

Official source pages:

- https://www.openanatomy.org/atlas-pages/atlas-spl-nac-brain.html
- https://www.openanatomy.org/atlas-pages/atlas-spl-knee.html
- https://www.openanatomy.org/atlas-pages/atlas-spl-abdomen.html
- https://www.openanatomy.org/atlas-pages/slicer-license.html

## Input regression checks

`erm_anatomy_ui_tests` uses the real GTKGS/controller modules with a deterministic
backend that enforces the native single-child window constraint. It covers
rotation, pan, zoom bounds, reset, cancellation, source validation, cleanup and
reopening. It is a protocol/lifecycle test, not a physical mouse test. Run it in
an isolated EUnit VM with `gtknode4`, `gtknode4_sup`, `gtknode4_fake`, `gtkgs`,
`erm_log`, `jsx` and the anatomy modules on the code path, not inside your desktop
node.

`test/erm_anatomy_pointer_native.c` is a GTK smoke test that emits real controller
signals and inspects encoded Erlang events while checking disabled controls and
controller destruction. From the repository root:

```sh
ERL_ROOT=$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')
cc -Wall -Wextra -Werror -pthread \
  $(pkg-config --cflags gtk4) -I"$ERL_ROOT/usr/include" \
  apps/erm/test/erm_anatomy_pointer_native.c \
  $(pkg-config --libs gtk4 x11) -L"$ERL_ROOT/usr/lib" -lei \
  -o /tmp/erm-anatomy-pointer-test
/tmp/erm-anatomy-pointer-test --hello-only
G_DEBUG=fatal-criticals GTK_A11Y=none xvfb-run -a /tmp/erm-anatomy-pointer-test
```

The hello-only check needs no display and decodes the native capability map to
check its byte length and both pointer and libshumate capability entries. To
check a build with maps enabled, also pass `-DHAVE_LIBSHUMATE=1` and the compiler
and linker flags from `pkg-config --cflags --libs shumate-1.0`.

Validation for this update: 15 EUnit tests passed; all three sources passed live
HTTPS download, preparation, offline cache reuse and software-render checks;
native source and the smoke-test executable compiled and linked. The smoke test
could not be executed because this environment could not create X sockets.
