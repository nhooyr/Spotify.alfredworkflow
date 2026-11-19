# Spotify.alfredworkflow

Search and play music from Spotify with the `spot` keyword or <kbd>⌃</kbd><kbd>⌘</kbd><kbd>Space</kbd>.

![Spotify Mini Player](./docs/ss.png)

## Install

The workflow requires a **Spotify Premium** account and a **Spotify Client ID** from a Spotify developer
application.

1. Create a [Spotify developer application](https://developer.spotify.com/dashboard/applications) to get a
   **Spotify Client ID**. Enable the **Web API** and set the app’s redirect URI to
   `http://127.0.0.1:8765/spotify_callback`.

![Install screenshot for step 1](./docs/install-1.png)

2. Double click [Spotify.alfredworkflow](./dist/Spotify.alfredworkflow) to install the workflow.
   In the Spotify.alfredworkflow’s configuration, enter the **Spotify Client ID**.

![Install screenshot for step 2](./docs/install-2.png)

3. Optional but set a hotkey for the Spotify Mini Player in the workflow’s configuration.
   I suggest <kbd>⌃</kbd><kbd>⌘</kbd><kbd>Space</kbd>.

![Install screenshot for step 3](./docs/install-3.png)

4. When you open the Spotify Mini Player, sign-in will open in your browser automatically. Allow access. The
   Mini Player will reopen automatically if successful. If you close the browser tab, press <kbd>↩</kbd> on
   the **Connecting to Spotify…** menu to open sign-in again.

![Install screenshot for step 4](./docs/install-3.png)

If you encounter a hiccup, open an issue at [github.com/nhooyr/Spotify.alfredworkflow](https://github.com/nhooyr/Spotify.alfredworkflow/issues).

## Usage

Browse **Playlists**, **Albums**, **Artists**, and **Songs**, or type to search.
You can type or paste these paths directly. Category names accept singular or
plural forms and ignore case. Named folders resolve from cached music; append
text after any folder path to filter its contents.

| Typed path | Action |
| --- | --- |
| `Playlists/` | Browse your playlists. |
| `Playlists/<playlist>/` | Browse a playlist’s songs. |
| `Albums/` | Browse your albums. |
| `Albums/<album>/` | Browse an album’s songs. |
| `Artists/` | Browse your artists. |
| `Artists/<artist>/` | Browse an artist’s albums, or play all their tracks. |
| `Artists/<artist>/<album>/` | Browse an artist’s album. |
| `Songs/` | Browse Liked Songs, with **All** at the top. |
| `Songs/All` | Press Return to play all Liked Songs. |
| `<playlist>/`, `<album>/`, or `<artist>/` | Open a cached folder directly, as from local search. |
| `<artist>/<album>/` | Open a cached artist’s album directly. |
| `/` | Open Spotify catalogue search, ready for a query. |
| `/query` | Search Spotify’s full catalogue. |

**Songs** contains your Liked Songs; choose **All** at the top to play the collection.
**Artists** lists only artists you follow. Offline, browsing and search show
downloaded music only, including artists with downloaded songs. A small grey
**offline** label appears at the bottom right.
The **＋/✓** button likes or unlikes the current song. Playlists use Spotify’s custom
order when available; local search prioritises playlists, albums, artists, then
songs and reuses cached music.
For one-track albums, the song appears before its album in search.
The second header line always shows the current song’s artist and album.
The third line shows its playback source when known: playlist, album, artist,
or Liked Songs. This source can stay the same when Spotify continues with autoplay.
Playback uses the Web API online and starts Spotify automatically when needed.
Offline, or when the desktop device is unavailable through the API, AppleScript
handles playback and may bring Spotify forward.

The shuffle button toggles shuffle; repeat cycles **off → all → one**
([Spotify Premium required](https://developer.spotify.com/documentation/web-api/reference/set-repeat-mode-on-users-playback)).
Active like, shuffle and repeat controls stay Spotify green.

Choose **Search** (`⌘5`), press `⌘↩` to carry over your current query, or start
with `/` to search the full catalogue (for example, `/meow`). Results update as
you type. Reopening resumes the query; removing the leading `/` returns to local
search.

The player reuses Spotify’s desktop metadata and covers, keeping copies for offline
browsing. Missing covers download in the background while online; unavailable
artwork shows a grey question mark. Connect once online, then play songs already
downloaded in Spotify without an internet connection.

The workflow checks its own cache hourly. Above **1 GB**, it removes the oldest
unused artwork, protecting covers for your saved/downloaded library and anything
used in the last day. This is a soft limit so needed offline artwork is retained;
Spotify’s cache is never changed.

The default keyword is `spot`. Change **Keyword** in the Workflow’s Configuration
to update every command below; for example, `spotify` gives you `spotify shuf`
and `spotify demo`.

| Keyword | Action |
| --- | --- |
| `spot` | Open the mini player. |
| `spot like` | Save the current song to Liked Songs. |
| `spot unlike` | Remove the current song from Liked Songs. |
| `spot shuf` | Turn shuffle on. |
| `spot noshuf` | Turn shuffle off. |
| `spot demo` | Toggle demo mode for macOS’s window picker. |
| `spot refresh` | Refresh the desktop cache index and connected library. |
| `spot reauth` | Clear sign-in; reconnect when the player next opens. |

The like, unlike, shuf and noshuf commands set a state rather than toggling it.

* <kbd>⌃</kbd><kbd>⌘</kbd><kbd>Space</kbd> Open the player from any app (the only global Hotkey).
* <kbd>⌃</kbd><kbd>⌘</kbd><kbd>←</kbd> / <kbd>⌃</kbd><kbd>⌘</kbd><kbd>→</kbd> Previous / next Spotify track in the mini player.
* <kbd>⌃</kbd><kbd>⌘</kbd><kbd>↑</kbd> / <kbd>⌃</kbd><kbd>⌘</kbd><kbd>↓</kbd> Play/pause Spotify in the mini player.
* <kbd>⌘</kbd><kbd>S</kbd> Play/pause Spotify in the mini player.
* <kbd>⌘</kbd><kbd>P</kbd> / <kbd>⌘</kbd><kbd>N</kbd> Previous / next track in the mini player.
* <kbd>↩</kbd> Browse the selection from its first item, or play a song.
* <kbd>⌥</kbd><kbd>↩</kbd> Play the selected song, album, playlist, artist, or all Liked Songs directly; browse-only items open normally.
* <kbd>⌘</kbd><kbd>↓</kbd> Open the selection, restoring its previous selection and filter.
* <kbd>⌘</kbd><kbd>↑</kbd> Go up one level, restoring the parent selection and filter.
* <kbd>⌘</kbd><kbd>↩</kbd> Search the full Spotify catalogue.
* <kbd>⌫</kbd> Delete text; at a folder path with no filter, go up and restore the parent selection.
* <kbd>⌘</kbd><kbd>R</kbd> Refresh the library and desktop cache index in the mini player.
* <kbd>⌘</kbd><kbd>,</kbd> Open the Workflow’s Configuration.
* <kbd>Esc</kbd> / <kbd>⌘</kbd><kbd>W</kbd> Hide the player.

Only the launch Hotkey at the top of the workflow canvas is configurable
(default: `⌃⌘Space`). All other shortcuts are fixed and active only in the mini
player. Alfred clears the launch assignment on a fresh import; set it once in
that Hotkey object.

Open the player with `spot` or the launch Hotkey. Press that Hotkey again while
the player is focused to open Spotify. The player stays ready in the background while Alfred
is running. Reopening selects your filter so typing replaces it; using the results
or controls clears that selection. Editing a filter selects the first result.
Spotify catalogue searches resume in the same mode.
Switching Spaces hides the player while keeping its filter and window ready.

Demo mode (`spot demo`) keeps the player focusable and visible while using macOS’s
screenshot tool. Run it again, or press Esc in the player, to exit.

The player follows your Alfred theme’s colours, cursor, fonts and window styling,
while retaining its layout. Built-in themes use the available background and
selection colours.

After `spot reauth`, choose **Open Spotify Mini Player** in Alfred to sign in again.
Your Spotify Client ID and cached music are kept.
