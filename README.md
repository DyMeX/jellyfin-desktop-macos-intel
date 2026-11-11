# Jellyfin Desktop for Intel Macs

Unofficial x86_64 builds of [Jellyfin Desktop](https://github.com/jellyfin/jellyfin-desktop) for Intel Macs.

Since 2.x the upstream project ships macOS builds for Apple Silicon only: Homebrew no longer has
prebuilt mpv for Intel and building it there timed out the CI
([jellyfin/jellyfin-desktop#1302](https://github.com/jellyfin/jellyfin-desktop/issues/1302)).
This repository builds the same upstream source for Intel and publishes a DMG.

**Download:** [Releases](../../releases) - pick the DMG for the version you want.

## Requirements

- Intel Mac (x86_64), macOS 13 Ventura or newer (Qt 6.10+ does not support older macOS).
- A Jellyfin server.

## Install

1. Open the DMG and drag **Jellyfin Desktop** to Applications.
2. The app is ad-hoc signed, not notarized by Apple. On first launch right-click it and choose
   **Open**, or run:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Jellyfin Desktop.app"
   ```

Each release lists the SHA-256 of the DMG and links to the GitHub Actions run that built it.

## How it is built

[`build.sh`](build.sh) builds everything the player needs from source with
`MACOSX_DEPLOYMENT_TARGET=13.0`, so no Homebrew libraries end up in the app:

| Component | Version |
|---|---|
| Jellyfin Desktop | upstream release tag, source unchanged |
| Qt | 6.11.3 (official binaries via aqtinstall) |
| mpv (libmpv) | 0.42.0 |
| FFmpeg | 9.0.2, LGPL build: VideoToolbox hardware decoding, dav1d for AV1, Secure Transport for HTTPS |
| libplacebo, libass, HarfBuzz, FreeType, FriBidi, Little CMS, SDL2 | see [`versions.env`](versions.env) |

Differences from the official Apple Silicon build:

- mpv is built without Lua/JavaScript scripting, VapourSynth, Vulkan, Blu-ray/DVD and archive support - none of them is used by Jellyfin Desktop.
- FFmpeg has no x264/x265 encoders (the player only decodes).
- The built-in update check is disabled; watch this repository's releases instead.
- One small mpv patch ([`patches/mpv`](patches/mpv)): mpv 0.42 does not compile on macOS without Vulkan.

[`scripts/verify-bundle.sh`](scripts/verify-bundle.sh) fails the build if any binary in the app is not
x86_64, needs a macOS newer than 13 or links to a library outside the bundle.

A [workflow](.github/workflows/build.yml) checks upstream daily and builds new releases on a
`macos-15-intel` runner. Upstream pre-releases are published as pre-releases here too.

### Build it yourself

On an Intel Mac with Xcode Command Line Tools and Homebrew:

```sh
brew install cmake ninja nasm pkgconf
./build.sh                          # latest pinned tag, ~1 h on first run
JELLYFIN_TAG=v2.1.0-pre1 ./build.sh # specific upstream tag
```

The DMG lands in `dist/`.

## Troubleshooting

**Audio plays, picture is black or a flat colour.** Jellyfin Desktop draws mpv video *under* the web
interface, which turns transparent during playback. Custom CSS on the server (Dashboard → General →
Custom CSS) that forces a background with `!important` on `html`, `body` or `.backgroundContainer`
covers the video. Exclude the playback state, for example:

```css
html:not(.transparentDocument), html:not(.transparentDocument) body,
.backgroundContainer:not(.backgroundContainer-transparent) { background-color: #141414 !important; }
```

Other problems: check `~/Library/Logs/Jellyfin Desktop/` and report app bugs
[upstream](https://github.com/jellyfin/jellyfin-desktop/issues); report packaging problems (crash on
start, missing libraries, Intel-only issues) [here](../../issues).

## License

Build scripts and patches: GPL-2.0, same as Jellyfin Desktop ([LICENSE](LICENSE)).
The DMG contains Jellyfin Desktop (GPL-2.0), Qt (LGPL-3.0), mpv (GPL-2.0+), FFmpeg (LGPL-2.1+) and the other
libraries listed above under their own licenses; their source is available from the upstream
projects at the versions in [`versions.env`](versions.env).

This is not an official Jellyfin release and is not affiliated with or endorsed by the Jellyfin project.
