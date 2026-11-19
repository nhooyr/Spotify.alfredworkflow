# Spotify.alfredworkflow

Search and play your Spotify music via the `spotify` keyword.

![Spotify Mini Player](./docs/ss.png)

Browse **Playlists**, **Albums**, **Artists**, and **Songs**, or type to search.
**Songs** contains your Liked Songs; the **＋/✓** button likes or unlikes the
current song. Playlists use Spotify’s custom order when available; local search
prioritises playlists, albums, artists, then songs and reuses cached music.
Playing a song leaves Spotify in the background.

The shuffle button toggles shuffle; repeat cycles **off → all → one**
([Spotify Premium required](https://developer.spotify.com/documentation/web-api/reference/set-repeat-mode-on-users-playback)).
Active like, shuffle and repeat controls stay Spotify green.

Choose **Spotify** (`⌘5`), press `⌘↩` to carry over your current query, or start
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

| Keyword | Action |
| --- | --- |
| `spotify` | Open the mini player. |
| `spotify like` | Save the current song to Liked Songs. |
| `spotify unlike` | Remove the current song from Liked Songs. |
| `spotify shuffle` | Turn shuffle on. |
| `spotify sequential` | Turn shuffle off. |
| `spotify screenshot` | Toggle screenshot mode for macOS’s window picker. |
| `spotify reauth` | Clear sign-in; reconnect when the player next opens. |

The like, unlike, shuffle and sequential commands set a state rather than toggling it.

* <kbd>⌃</kbd><kbd>⌘</kbd><kbd>Space</kbd> Open the player (default Hotkey).
* <kbd>↩</kbd> Browse the selection or play a song.
* <kbd>⌘</kbd><kbd>1</kbd> … <kbd>⌘</kbd><kbd>9</kbd> Activate one of the first nine results.
* <kbd>⌘</kbd><kbd>↩</kbd> Search the full Spotify catalogue.
* <kbd>⌫</kbd> Delete selected text; at a folder path with no filter, go up one level.
* <kbd>⌘</kbd><kbd>R</kbd> Refresh the library and desktop cache index.
* <kbd>⌘</kbd><kbd>,</kbd> Open the Workflow’s Configuration.
* <kbd>Esc</kbd> / <kbd>⌘</kbd><kbd>W</kbd> Hide the player.

Configure the Hotkey for faster access. Press it again while the player is
focused to open Spotify. The player stays ready in the background while Alfred
is running. Reopening selects your filter so typing replaces it; using the results
or controls clears that selection. Spotify catalogue searches resume in the same mode.

`spotify screenshot` keeps the player focusable and visible while using macOS’s
screenshot tool. Run it again, or press Esc in the player, to exit.

The player follows your Alfred theme’s colours, cursor, fonts and window styling,
while retaining its layout. Built-in themes use the available background and
selection colours.

In the Workflow’s Configuration, enter your Spotify app’s **Client ID** and set
its redirect URI to `http://127.0.0.1/spotify_callback` (no port). **Client Secret**
is optional.

Sign-in opens in your browser automatically; use **Connect** to retry. After `spotify reauth`, choose
**Open Spotify Mini Player** in Alfred to sign in again. Your Client ID and
optional Client Secret are kept.
