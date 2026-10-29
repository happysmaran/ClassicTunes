# ClassicTunes

<img src="docs/assets/classictunes.png" width="70%" alt="ClassicTunes main window" />

After the UI overhaul of the Music app in macOS 26 diverged from the long-standing iTunes design language, I tried to use older iTunes versions on a modern MacBook because I preferred its design and feature set. However, starting with Tahoe, most solutions for running older software began to break due to the deprecation of certain libraries. As such, I decided to make my own music player completely from scratch using Swift and SwiftUI.

**ClassicTunes** is an Apple Silicon–made app that faithfully recreates the look and feel of iTunes 7–10, featuring:

- Faithfully recreated Cover Flow
- MiniPlayer
- Playlists and Smart Playlists (with smart m3u support)
- Tunes Store (via the iTunes API)
- Lyrics support (with lrclib or metadata)
- iPod Syncing (1st-2nd gen Shuffles for now)
- Discord Rich Presence (with MusicPresence)
- Color and theme customization
- Classic iTunes 7–10 aesthetics

I ran out of things to say.

## Download

**[Download ClassicTunes 1.4](https://github.com/happysmaran/ClassicTunes/releases/download/1.4/ClassicTunes.zip)** · [Website](https://classictunes.smaran-vallabhaneni.com/) · [All releases](https://github.com/happysmaran/ClassicTunes/releases)

**System requirements:** macOS 14 Sonoma or later, Apple Silicon (M-series and A-series).

The app and the website are available in 11 languages: English, 简体中文, Français, Deutsch, हिन्दी, 日本語, 한국어, Português (Brasil), Русский, Español and తెలుగు.

## Screenshots

<p align="center">
  <img src="docs/assets/coverflow.png" width="49%" alt="Cover Flow" />
  <img src="docs/assets/visualizer.png" width="49%" alt="11 different visualizers" />
</p>

<p align="center">
  <img src="docs/assets/upnext_lyrics.png" width="49%" alt="Lyrics (with lrclib), Up Next view and Album Art view" />
  <img src="docs/assets/miniplayer.png" width="49%" alt="MiniPlayer" />
</p>

<p align="center">
  <img src="docs/assets/addto_playlist.png" width="49%" alt="Playlist and Smart Playlist management with smart m3u support" />
  <img src="docs/assets/tunes_store.png" width="49%" alt="Tunes Store integration" />
</p>

<p align="center">
  <img src="docs/assets/ipo_syncing.png" width="49%" alt="iPod syncing (1st-2nd gen Shuffles)" />
  <img src="docs/assets/discord_rpc.png" width="49%" alt="Discord Rich Presence (with MusicPresence)" />
</p>

<p align="center">
  <img src="docs/assets/customizatoin.png" width="49%" alt="Color and theme customization" />
  <img src="docs/assets/equalizer.png" width="49%" alt="Equalizer" />
</p>

<p align="center">
  <img src="docs/assets/metadata.png" width="49%" alt="Metadata editor for most audio formats" />
  <img src="docs/assets/darkmode.png" width="49%" alt="Dark mode" />
</p>

<p align="center">
  <img src="docs/assets/playlists.png" width="49%" alt="Playlists" />
  <img src="docs/assets/help.png" width="49%" alt="Built-in help guide" />
</p>