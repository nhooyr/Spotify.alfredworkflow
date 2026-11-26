# Spotify.alfredworkflow [![ci](https://github.com/nhooyr/Spotify.alfredworkflow/actions/workflows/ci.yml/badge.svg)](https://github.com/nhooyr/Spotify.alfredworkflow/actions/workflows/ci.yml) [![GitHub Release](https://img.shields.io/github/v/release/nhooyr/Spotify.alfredworkflow?include_prereleases&display_name=tag&color=64C864)](https://github.com/nhooyr/Spotify.alfredworkflow/releases)

Search and play music from Spotify with the `spot mini` keyword or <kbd>Ctrl</kbd><kbd>Cmd</kbd><kbd>Space</kbd>.

![Spotify Mini Player](./docs/ss.png)

## Install

The workflow requires a **Spotify Premium** account and a **Spotify Client ID** from a Spotify developer
application.

1. Download **Spotify.alfredworkflow** from the [latest release](https://github.com/nhooyr/Spotify.alfredworkflow/releases), or build it with [`./build.sh`](./build.sh).

![Screenshot for install step 1](./docs/install-1.png)

2. Double click **Spotify.alfredworkflow** to install the workflow.

![Screenshot for install step 2](./docs/install-2.png)

3. Select the **Hotkey** object at the top of the workflow canvas to set a hotkey.
   I use <kbd>Ctrl</kbd><kbd>Cmd</kbd><kbd>Space</kbd>.

![Screenshot for install step 3](./docs/install-3.png)

4. Create a [Spotify developer application](https://developer.spotify.com/dashboard/applications) to get a
   **Spotify Client ID**. Enable the **Web API** and set the app’s redirect URI to
   `http://127.0.0.1:8765/spotify_callback`.

![Screenshot for install step 4](./docs/install-4.png)

5. Open the Spotify Mini Player and enter your **Spotify Client ID**.

   *note*: The workflow stores your **Spotify Client ID** and sign-in tokens in your local macOS Keychain,
   outside Alfred's synced preferences for optimal security.

![Screenshot for install step 5](./docs/install-5.png)

6. Sign-in will load automatically in your browser. Allow access.

   *note*: If you close the browser tab, press <kbd>Enter</kbd> on the **Connecting to Spotify...** menu to
   open sign-in again.

![Screenshot for install step 6](./docs/install-6.png)

7. The Spotify Mini Player will reopen automatically if sign-in was successful and begin syncing your Spotify
   library metadata.

![Spotify Mini Player](./docs/ss.png)

If you encounter a hiccup, open an issue at [github.com/nhooyr/Spotify.alfredworkflow](https://github.com/nhooyr/Spotify.alfredworkflow/issues).

## Usage

Browse **Playlists**, **Albums**, **Artists**, **Liked Songs** and **Queue**, or type
to search library music.

### Browsing and search

You can type or paste these paths directly. Category names accept singular or
plural forms and ignore case. Named folders resolve from library music; append
text after any folder path to filter its contents.

| Typed path | Action |
| --- | --- |
| `playlists/` | Browse playlists in Spotify’s custom order when available. |
| `playlists/<playlist>/` | Browse a playlist’s songs. |
| `albums/` | Browse albums saved to your library. |
| `albums/<album>/` | Browse an album’s songs. |
| `artists/` | Browse artists you follow. |
| `artists/<artist>/` | Browse an artist’s albums or play all their tracks. |
| `artists/<artist>/<album>/` | Browse an artist’s album. |
| `liked songs`, `liked songs/` or `songs/` | Browse Liked Songs. |
| `liked songs/all`, `songs/all` or `songs/liked songs` | Press <kbd>Enter</kbd> on **Liked Songs** at the top to play the collection. |
| `<playlist>/`, `<album>/` or `<artist>/` | Open a library folder directly, as from library search. |
| `<artist>/<album>/` | Open a library artist’s album directly. |
| `/` | Open Spotify catalogue search, ready for a query. |
| `/query` | Search Spotify’s full catalogue (for example, `/meow`). |
| `queue/` | Browse recently played songs, the current song and what’s next. |

Local results prioritise playlists, albums, artists, then songs. For one-track
albums, the song appears before its album in search.

**Search** updates catalogue results as you type. Reopening resumes the query;
removing the leading `/` returns to library search.

### Playback

* **＋/✓** likes or unlikes the current song.
* **Shuffle** toggles shuffle.
* **Repeat** cycles **off → all → one**
  ([Spotify Premium required](https://developer.spotify.com/documentation/web-api/reference/set-repeat-mode-on-users-playback)).

Active like, shuffle and repeat controls stay Spotify green.

**Queue** opens on the current song, with recently played songs above and upcoming
songs below. Select a song to play it. History is kept between launches; Spotify’s
recent history is included when your sign-in grants access.

The second header line always shows the current song’s artist and album.
The third line shows its playback source when known: playlist, album, artist,
or Liked Songs. This source can stay the same when Spotify continues with autoplay.

Playback uses the Web API online and keeps Spotify’s active output device, including
your phone or speaker. It starts Spotify on the Mac when no device is active.
AppleScript is used without internet access or when the API cannot report whether
Spotify is playing, and may bring Spotify forward.

### Offline and caching

Offline, browsing and search show downloaded music only, including artists with
downloaded songs. Connect once online before using this mode.

The player reuses Spotify’s desktop metadata and covers. Missing covers download
in the background while online; unavailable artwork shows a grey question mark.
Spotify manages downloaded audio; this workflow caches only metadata and artwork.

The bottom-left footer shows sync progress during the initial library import,
errors in red and brief queue confirmations. Queue confirmations clear when you
next use the menu, type, or close the player.

The workflow checks its own cache hourly. Above **1 GB**, it removes the oldest
unused artwork, protecting covers for your saved/downloaded library and anything
used in the last day. This is a soft limit so needed offline artwork is retained;
Spotify’s cache is never changed.

### Commands

The default keyword is `spot`. Change **Keyword** in the Workflow’s Configuration
to update every command below; for example, `spotify` gives you `spotify shuf`
and `spotify demo`.

| Keyword | Action |
| --- | --- |
| `spot mini` | Open Spotify Mini Player. |
| `spot like` | Save the current song to Liked Songs. |
| `spot unlike` | Remove the current song from Liked Songs. |
| `spot shuf` | Turn shuffle on. |
| `spot unshuf` | Turn shuffle off. |
| `spot refresh` | Refresh the desktop cache index and connected library. |
| `spot reauth` | Clear sign-in to reauthorize |
| `spot demo` | Toggle demo mode for taking screenshots. |
| `spot quit` | Quit Spotify Mini Player |

The like, unlike, shuf and unshuf commands set a state rather than toggling it.

Your Client ID and sign-in tokens are stored locally in macOS Keychain and cached in memory.

After `spot reauth`, open the Spotify Mini Player in Alfred to set up again.
This clears the Client ID and sign-in tokens from Keychain. The next open prompts for a Client ID again.

Cached artwork, saved library lists and playlist order are kept for the same account, including when Spotify
rate limits a refresh. A confirmed account change clears the previous account’s saved lists.

### Shortcuts

* <kbd>Ctrl</kbd><kbd>Cmd</kbd><kbd>Space</kbd> Open the player from any app.
* <kbd>Ctrl</kbd><kbd>Cmd</kbd><kbd>Left</kbd> / <kbd>Cmd</kbd><kbd>P</kbd> Previous Spotify track.
* <kbd>Ctrl</kbd><kbd>Cmd</kbd><kbd>Right</kbd> / <kbd>Cmd</kbd><kbd>N</kbd> Next Spotify track.
* <kbd>Ctrl</kbd><kbd>Cmd</kbd><kbd>Up</kbd> / <kbd>Ctrl</kbd><kbd>Cmd</kbd><kbd>Down</kbd> / <kbd>Cmd</kbd><kbd>S</kbd> Play/pause Spotify.
* <kbd>Cmd</kbd><kbd>L</kbd> Like/unlike the current Spotify song.
* <kbd>Cmd</kbd><kbd>Shift</kbd><kbd>Left</kbd> / <kbd>Cmd</kbd><kbd>Shift</kbd><kbd>Right</kbd> Seek backward/forward five seconds.
* <kbd>Enter</kbd> Browse the selection from its first item or play a song.
* <kbd>Opt</kbd><kbd>Enter</kbd> Play the selected song, album, playlist, artist or all Liked Songs directly; browse-only items open normally.
* <kbd>Cmd</kbd><kbd>Down</kbd> Open the selection, restoring its previous selection and filter.
* <kbd>Cmd</kbd><kbd>Up</kbd> Go up one level, restoring the parent selection and filter.
* <kbd>Cmd</kbd><kbd>1</kbd>–<kbd>9</kbd>, <kbd>Cmd</kbd><kbd>0</kbd> and <kbd>Cmd</kbd><kbd>-</kbd> Open the eleven fully visible menu items; shortcuts follow scrolling.
* <kbd>Fn</kbd><kbd>Up</kbd> / <kbd>Fn</kbd><kbd>Down</kbd> Scroll one page without changing the selection.
* <kbd>Cmd</kbd><kbd>5</kbd> Open **Search** from the home menu.
* <kbd>Cmd</kbd><kbd>6</kbd> Open **Queue** from the home menu.
* <kbd>Cmd</kbd><kbd>Enter</kbd> Add the selected song, album or playlist to Spotify’s queue while online.
* <kbd>Backspace</kbd> Delete text; at a folder path with no filter, go up and restore the parent selection.
* <kbd>Cmd</kbd><kbd>R</kbd> Refresh the library and desktop cache index in the mini player.
* <kbd>Cmd</kbd><kbd>Comma</kbd> Open the Workflow’s Configuration.
* <kbd>Esc</kbd> / <kbd>Cmd</kbd><kbd>W</kbd> Hide the player.
* <kbd>Cmd</kbd><kbd>Q</kbd> Quit the player, like `spot quit`.

Only the launch Hotkey is global and configurable. All other shortcuts are fixed
and active only in the mini player. Alfred clears the launch assignment on a fresh
import; set it once in the Hotkey object.

Press the launch Hotkey again while the player is focused to open Spotify. The
player stays ready in the background while Alfred is running.

Reopening selects your filter so typing replaces it; using the results
or controls clears that selection. Editing a filter selects the first result.
Switching Spaces hides the player while keeping its filter and window ready.

In demo mode, the player stays visible and focusable when it loses focus.
Run `spot demo` again to return to normal mode with the player open.
Press <kbd>Esc</kbd> to hide the player and reset demo mode.

The player follows your Alfred theme’s colours, cursor, fonts and window styling,
while retaining its layout. Built-in themes use the available background and
selection colours.
