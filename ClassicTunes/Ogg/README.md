# Ogg Vorbis and Opus decoding

AVFoundation cannot open Ogg containers or decode Vorbis, so ClassicTunes reads and decodes
`.ogg`, `.oga` and `.opus` files with the C code in this folder. `ClassicOgg.h` is the interface
Swift sees (through `ClassicTunes-Bridging-Header.h`).

## Third-party code

| Path | Project | Version | License |
| --- | --- | --- | --- |
| `opus/` | [libopus](https://github.com/xiph/opus), Xiph.Org Foundation and contributors | 1.5.2 (release tarball) | BSD-3-Clause, see `opus/COPYING` |
| `stb_vorbis.c` | [stb_vorbis](https://github.com/nothings/stb), Sean Barrett | v1.22, `master` of nothings/stb as downloaded on 2026-11-09 | Public domain / MIT (dual, see end of file) |

`opus/` only contains what audio decoding needs: namely, 73 `.c` files (CELT and SILK decoders, the
packet parser and the multistream decoder) and every header from `include/`, `celt/`, `silk/` and
`src/`. The encoder, the SIMD and assembly code and the build system are left out, which is why
the folder can be compiled as-is by Xcode. `config.h` is the only bespoke written file for this project
and uses the build flags libopus uses (`OPUS_BUILD`, `USE_ALLOCA`, `HAVE_LRINT`, `HAVE_LRINTF`).
## Project code

`ClassicOgg.c` and `ClassicOgg.h` (about 360 lines with `config.h`) are also the other files here that
are bespoke to this project: an Ogg page reader, a scan for tags, length and format, and a decoder
that writes 16-bit PCM WAV files. Vorbis goes through stb_vorbis and Opus through libopus.

## Why commit `a58a89d` is so large

If you have looked at the GitHub, you might have noticed a massive git commit with over 41,000
lines of code. Why is that?

Commit `a58a89d8a52a80e3231c051699b31fabe69dda7c` ("Ogg and Opus support with custom
interpreters") shows 151 files changed and +41,514 lines. About 41,000 of those lines are the
vendored libraries above (libopus 35,291 lines in 135 files, stb_vorbis 5,584 lines). The
project's own changes in that commit are small by comparison: the wrapper in this folder, the
Swift side (`Utilities/OggAudio.swift`, library import, playback cache, sync conversion) and the
Xcode build settings for the bridging header and header search paths.

The reason these libraries are not under git submodules and are loose files is because Xcode compiles
every `.c` file in a synchronized folder and the full upstream tree includes encoder and architecture-specific
code that must **not** be built. Also I don't like using submodules.

Henceforth, a `.gitattributes` at the repository root marks them as vendored  so GitHub will collapse them
in the diffs.

## Updating

Download the new release, copy the same set of files over `opus/`, build, and play an Opus and a
Vorbis file. For stb_vorbis, replace `stb_vorbis.c` and update the version in the table above.
