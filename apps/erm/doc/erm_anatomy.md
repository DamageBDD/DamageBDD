# erm anatomy viewer

A GTKGS anatomy viewer with automatic BodyParts3D downloads and a persistent local cache. Erlang handles networking, mesh preparation, camera, selection and visibility. The existing GTKGS picture widget displays software-rendered SVG frames.

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
%% [bodyparts3d_partof, bodyparts3d_isa]
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

Downloads and redirects are restricted to HTTPS on `dbarchive.biosciencedbc.jp`, with peer and hostname verification. Body sizes are bounded while streaming. Archive entries are inspected and selected files are extracted to memory, validated as OBJ, and written using element IDs. Archive paths are never used as extraction destinations. The manifest is published only after successful preparation.

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

This is an opaque orthographic software renderer using triangle depth sorting. Intersecting geometry can have occlusion artifacts. It does not provide a GPU depth buffer, mouse orbit, viewport picking, clipping, textures, transparency or medical image volumes. Nonconvex polygon faces should be triangulated before import.

Limits: 200 structures, 50,000 total triangles, 16 MiB per OBJ, 4,000 selected components and 256 MiB total extracted mesh bytes. Download caps are 100 MiB for PART-OF and 180 MiB for IS-A; metadata is capped at 2 MiB. Render operations are synchronous; dataset fetching and mesh loading run in a separate worker.

## Validation

The package compiles with warnings treated as errors on OTP 25. Included EUnit tests cover OBJ parsing/rendering, component mapping, selection errors, archive paths, missing meshes, offline cache reuse and corrupted-cache rejection. A live HTTPS download of the official mapping table and extraction/rendering of the official PART-OF starter meshes were also checked. Native GTK display operation remains unverified in this environment.

```sh
mkdir -p /tmp/erm-anatomy-test
erlc -Werror -o /tmp/erm-anatomy-test apps/erm/src/erm_anatomy*.erl apps/erm/test/erm_anatomy*_tests.erl
erl -noshell -pa /tmp/erm-anatomy-test -eval 'case eunit:test([erm_anatomy_mesh_tests,erm_anatomy_data_tests],[verbose]) of ok -> halt(0); _ -> halt(1) end.'
```
