import Foundation

func spotifyDestination(for item: JSONObject) -> URL? {
  let uri: String
  if isLikedSongsPlaylist(item) || text(dict(item["target"])["kind"]) == "songs" {
    uri = PlaybackContext.likedSongs.uri
  } else {
    let playURI = text(item["play_uri"])
    uri = playURI.isEmpty ? text(item["uri"]) : playURI
  }
  guard validPlaybackURI(uri) else { return nil }
  return URL(string: isLikedSongsURI(uri) ? PlaybackContext.likedSongs.uri : uri)
}
