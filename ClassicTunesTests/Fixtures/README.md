# iTunesDB fixtures

Both files are Base64 copies of synthetic databases from the iOpenPod project
(https://github.com/TheRealSavi/iOpenPod, GPL-3.0-or-later), `tests/fixtures/iTunesDB/`.

- `original-empty.b64`: 3,508-byte empty database, no tracks, one master playlist.
- `captured-album-index-36.b64`: 69,884-byte database with 60 fabricated tracks, an album
  index and a sorted library index. It has no tracks from a real device.

They are used to prove the chunk reader/writer reproduces real databases byte for byte.
