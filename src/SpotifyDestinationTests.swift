import Foundation

func runSpotifyDestinationRegressionTests() throws {
  func require(_ item: JSONObject, _ expected: String?, _ message: String) throws {
    guard spotifyDestination(for: item)?.absoluteString == expected else {
      throw SpotifyFailure(message: "Spotify destination regression test: " + message)
    }
  }
  for kind in ["track", "album", "artist", "playlist"] {
    let uri = "spotify:" + kind + ":" + String(repeating: "a", count: 22)
    try require(
      ["uri": uri, "kind": kind, "name": "Example"], uri,
      "selected real media opens its Spotify page")
    try require(
      actionItem("Play Example", "play", ["play_uri": uri]), uri,
      "a collection's Play row opens the collection without playing it")
    try require(
      ["uri": "queue:played:fixture", "kind": kind, "play_uri": uri], uri,
      "synthetic Queue row identities never become Spotify destinations")
  }
  let liked = PlaybackContext.likedSongs.uri
  for uri in [liked, "spotify:user:example:collection"] {
    try require(["uri": uri, "kind": "playlist"], liked, "Liked Songs URIs are canonicalized")
    try require(
      actionItem("Liked Songs", "play", ["play_uri": uri]), liked,
      "the Liked Songs Play row opens the canonical collection")
  }
  let playlist = "spotify:playlist:" + String(repeating: "p", count: 22)
  try require(
    ["uri": playlist, "kind": "playlist", "name": "lIkEd SoNgS"], liked,
    "the existing Liked Songs playlist synonym uses the same collection")
  try require(
    ["uri": playlist, "kind": "playlist", "name": "Liked Songs Public"], playlist,
    "similar playlist names retain their own Spotify destination")
  for item in homeItems {
    let expected = text(dict(item["target"])["kind"]) == "songs" ? liked : nil
    try require(item, expected, "only Liked Songs has a mapped home destination")
  }
  for invalid in [
    "", "queue:upcoming:fixture", "action:play:fixture", "folder:example", "spotify:search:example",
    "spotify:track:short", "spotify:track:" + String(repeating: "a", count: 23),
    "spotify:episode:" + String(repeating: "e", count: 22),
    "https://open.spotify.com/track/" + String(repeating: "a", count: 22), "file:///tmp/example",
  ] {
    try require(["uri": invalid], nil, "unmapped or malformed destinations open the app instead")
    try require(
      ["uri": playlist, "play_uri": invalid.isEmpty ? "action:invalid" : invalid], nil,
      "an invalid explicit playback destination cannot accidentally open a different item")
  }
  print(
    "Spotify destination regression tests passed: media, Play rows, Queue identities, Liked Songs aliases and unmapped destinations."
  )
}
