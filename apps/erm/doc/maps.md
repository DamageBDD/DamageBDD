# ERM Maps

`erm_maps` is a GTKGS application backed by libshumate. Erlang owns the app
state and UI lifecycle; the existing `gtknode4` C-node owns the native
`ShumateSimpleMap` widget and network/tile rendering.

## Native dependency

The root `rebar.config` builds gtknode4 with map support during normal
`rebar3 compile`. Both the Linux and macOS port specs define
`HAVE_LIBSHUMATE=1` and use `pkg-config` to obtain the compiler and linker flags
for `gtk4` and `shumate-1.0`. No maps profile or separate native build is needed.
Libshumate development files are required for this build; a missing dependency
must not silently produce a C-node without map support. Package metadata also
includes the libshumate runtime dependency for Debian/Ubuntu and Arch packages.

Install the development packages alongside the existing Erlang/OTP toolchain:

```sh
# Arch Linux
sudo pacman -S --needed gtk4 libshumate pkgconf

# Ubuntu 24.04 / Mint 22
sudo apt-get install libgtk-4-dev libshumate-dev libx11-dev pkg-config erlang-dev
```

After applying this build change, discard the GTK object that may have been
compiled without `HAVE_LIBSHUMATE`. This is a one-time rebuild, not a normal
build step:

```sh
pkg-config --modversion shumate-1.0
rm -f apps/erm/c_src/gtknode4/gtknode4.o
rebar3 compile
test -x _build/default/lib/erm/priv/bin/gtknode4
```

For subsequent builds, run `rebar3 compile` (or `rebar3 as prod release`).
Restart the running ERM GTK subsystem after rebuilding so the process loads
the new executable. On Linux, `ldd _build/default/lib/erm/priv/bin/gtknode4`
should show `libshumate-1.0.so` with no missing libraries.

The standalone Makefile remains available for native-only development:
`make -C apps/erm/c_src/gtknode4`. It detects libshumate as an optional
capability and installs the executable into `apps/erm/priv/bin/gtknode4`.
When changing standalone build dependencies, use its `clean` target first.
An intentionally map-free build still rejects map creation through GTKGS
capability negotiation.

## Start

Enable the existing gtknode4 local C-node in ERM configuration, then:

```erlang
erm_maps:start().
```

Or provide a starting view:

```erlang
erm_maps:start(#{
    latitude => -33.8688,
    longitude => 151.2093,
    zoom_level => 12.0,
    source_id => <<"osm-mapnik">>
}).
```

The application defaults to the libshumate `osm-mapnik` source. The
`ShumateSimpleMap` widget provides the map gestures, license/attribution,
scale, compass and native zoom controls.

## Runtime API

```erlang
erm_maps:set_center(-33.8688, 151.2093).
erm_maps:set_view(-37.8136, 144.9631, 11.0).
erm_maps:set_zoom(13.0).
erm_maps:zoom_in().
erm_maps:zoom_out().
erm_maps:set_source(<<"osm-mapnik">>).
erm_maps:status().
erm_maps:hide().
erm_maps:show().
erm_maps:stop().
```

## GTKGS map object

The generic GTKGS layer now accepts a `map` widget with these native options:

- `source_id` — a source ID from libshumate's default map-source registry.
- `latitude` — center latitude in degrees.
- `longitude` — center longitude in degrees.
- `zoom_level` — fractional libshumate zoom level.
- `show_zoom_buttons` — show/hide ShumateSimpleMap's native zoom controls.

The same properties can be read with `gtkgs:read/2`. User panning and zooming
emits a `map_changed` GTKGS event whose payload contains `latitude`,
`longitude`, `zoom_level`, and `source_id`.

## Configuration

The application reads `erm.maps` and accepts the same keys as `start/1`:

```erlang
{maps, [
    {source_id, "osm-mapnik"},
    {latitude, 0.0},
    {longitude, 0.0},
    {zoom_level, 2.0},
    {show_zoom_buttons, true},
    {width, 1024},
    {height, 720},
    {ready_timeout, 15000}
]}.
```

`erm_maps:start/1` values override application configuration. The source ID is
resolved through libshumate's default `ShumateMapSourceRegistry`, so unsupported
source IDs fail instead of silently falling back to a different provider.
