import Foundation

// Host fixture: the production credential pair lives in DataLoaderServiceHooks.
var spotifyCatalogCredential: SpotifyCatalogCredential?
let fixtureCredential = SpotifyCatalogCredential(accessToken: "FIXTURE_TOKEN",
                                                 clientToken: "FIXTURE_CLIENT_TOKEN")

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

private func expectError(_ expected: OfflineCollectionCatalog.CatalogError,
                         _ name: String, operation: () throws -> Void) {
    do {
        try operation()
        fatalError("Expected \(name) to fail")
    } catch let actual as OfflineCollectionCatalog.CatalogError {
        require(String(describing: actual) == String(describing: expected), "Wrong error for \(name): \(actual)")
    } catch {
        fatalError("Unexpected error for \(name): \(error)")
    }
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func trackData(_ index: Int) -> [String: Any] {
    ["uri": String(format: "spotify:track:%022d", index),
     "name": "Title \(index)",
     "artists": ["items": [["profile": ["name": "Artist \(index)"]]]]]
}

private func albumResponse(_ uri: String, total: Any, offset: Int = 0,
                           count: Int = 1, entityType: String = "Album") -> Data {
    let items: [[String: Any]] = (0..<count).map { index in
        ["track": trackData(offset + index)]
    }
    return json(["data": ["albumUnion": [
        "__typename": entityType,
        "uri": uri,
        "tracksV2": ["totalCount": total, "items": items]
    ]]])
}

private func albumTrackResponse(_ uri: String, track: [String: Any]) -> Data {
    json(["data": ["albumUnion": [
        "__typename": "Album", "uri": uri,
        "tracksV2": ["totalCount": 1, "items": [["track": track]]]
    ]]])
}

private func playlistResponse(_ uri: String, total: Any, types: [String]) -> Data {
    let items: [[String: Any]] = types.enumerated().map { index, type in
        ["itemV2": ["data": trackData(index).merging(["__typename": type]) { _, new in new }]]
    }
    return json(["data": ["playlistV2": [
        "__typename": "Playlist", "uri": uri,
        "content": ["totalCount": total, "items": items]
    ]]])
}

let albumURI = "spotify:album:0123456789ABCDEFGHIJKL"
let playlistURI = "spotify:playlist:0123456789ABCDEFGHIJKL"
let wrongAlbumURI = "spotify:album:ABCDEFGHIJKL0123456789"
require(OfflineCollectionCatalog.kind(for: albumURI) == .album, "album URI rejected")
require(OfflineCollectionCatalog.kind(for: playlistURI) == .playlist, "playlist URI rejected")
require(OfflineCollectionCatalog.kind(for: "spotify:show:0123456789ABCDEFGHIJKL") == nil,
        "unsupported collection accepted")
require(OfflineCollectionCatalog.kind(for: "https://open.spotify.com/album/0123456789ABCDEFGHIJKL") == nil,
        "web URL accepted")

let albumRequest = try OfflineCollectionCatalog.makeRequest(uri: albumURI, kind: .album,
                                                              offset: 0, credential: fixtureCredential)
require(albumRequest.url?.absoluteString == "https://api-partner.spotify.com/pathfinder/v2/query",
        "wrong host/path")
require(albumRequest.httpMethod == "POST", "wrong method")
require(albumRequest.value(forHTTPHeaderField: "Authorization") == "Bearer FIXTURE_TOKEN",
        "authorization omitted")
require(albumRequest.value(forHTTPHeaderField: "Client-Token") == "FIXTURE_CLIENT_TOKEN",
        "paired client token omitted")
let albumBody = try JSONSerialization.jsonObject(with: albumRequest.httpBody!) as! [String: Any]
let albumVars = albumBody["variables"] as! [String: Any]
let albumExt = albumBody["extensions"] as! [String: Any]
let albumQuery = albumExt["persistedQuery"] as! [String: Any]
require(albumBody["operationName"] as? String == "getAlbum", "wrong album operation")
require(albumVars["uri"] as? String == albumURI && albumVars["offset"] as? Int == 0 &&
        albumVars["limit"] as? Int == 100, "wrong album variables")
require(albumQuery["version"] as? Int == 1 &&
        albumQuery["sha256Hash"] as? String ==
        "b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10",
        "wrong album query hash")
let singleAlbumRequest = try OfflineCollectionCatalog.makeRequest(
    uri: albumURI, kind: .album, offset: 0, limit: 1, credential: fixtureCredential)
let singleAlbumBody = try JSONSerialization.jsonObject(with: singleAlbumRequest.httpBody!) as! [String: Any]
require((singleAlbumBody["variables"] as! [String: Any])["limit"] as? Int == 1,
        "native one-album probe requested more than one item")

let playlistRequest = try OfflineCollectionCatalog.makeRequest(uri: playlistURI, kind: .playlist,
                                                                 offset: 100, credential: fixtureCredential)
let playlistBody = try JSONSerialization.jsonObject(with: playlistRequest.httpBody!) as! [String: Any]
let playlistVars = playlistBody["variables"] as! [String: Any]
let playlistQuery = (playlistBody["extensions"] as! [String: Any])["persistedQuery"] as! [String: Any]
require(playlistBody["operationName"] as? String == "fetchPlaylist", "wrong playlist operation")
require(playlistVars["uri"] as? String == playlistURI && playlistVars["offset"] as? Int == 100 &&
        playlistVars["enableWatchFeedEntrypoint"] as? Bool == true, "wrong playlist variables")
require(playlistQuery["sha256Hash"] as? String ==
        "bb67e0af06e8d6f52b531f97468ee4acd44cd0f82b988e15c2ea47b1148efc77",
        "wrong playlist query hash")

let albumPage = try OfflineCollectionCatalog.parsePage(albumResponse(albumURI, total: 1),
                                                        uri: albumURI, kind: .album, offset: 0)
require(albumPage.totalCount == 1 && albumPage.trackURIs == ["spotify:track:0000000000000000000000"],
        "single album parse failed")
require(albumPage.tracks[0].title == "Title 0" && albumPage.tracks[0].artist == "Artist 0",
        "album track labels lost")
let oneSongAlbum = OfflineCollectionCatalog.Collection(uri: albumURI, kind: .album,
                                                        tracks: albumPage.tracks)
require(oneSongAlbum.singleAlbumTrackURI(expectedAlbumURI: albumURI) == albumPage.trackURIs[0],
        "one-song collection action rejected")
require(oneSongAlbum.singleAlbumTrackURI(expectedAlbumURI: wrongAlbumURI) == nil,
        "wrong album bound to collection action")
require(OfflineCollectionCatalog.Collection(uri: playlistURI, kind: .playlist,
        tracks: albumPage.tracks).singleAlbumTrackURI(expectedAlbumURI: playlistURI) == nil,
        "one-song playlist misclassified as album")
require(OfflineCollectionCatalog.Collection(uri: albumURI, kind: .album,
        tracks: [albumPage.tracks[0], albumPage.tracks[0]])
        .singleAlbumTrackURI(expectedAlbumURI: albumURI) == nil,
        "two-entry album misclassified as one song")
let multiAlbumFirstItem = try OfflineCollectionCatalog.parsePage(
    albumResponse(albumURI, total: 2), uri: albumURI, kind: .album, offset: 0, limit: 1)
require(multiAlbumFirstItem.totalCount == 2 && multiAlbumFirstItem.trackURIs.count == 1,
        "first-item probe failed to identify a multi-song album")
let albumFirst = try OfflineCollectionCatalog.parsePage(albumResponse(albumURI, total: 101, count: 100),
                                                         uri: albumURI, kind: .album, offset: 0)
let albumSecond = try OfflineCollectionCatalog.parsePage(albumResponse(albumURI, total: 101, offset: 100),
                                                          uri: albumURI, kind: .album, offset: 100)
require(albumFirst.trackURIs.count == 100 && albumSecond.trackURIs.count == 1,
        "pagination boundary failed")
var albumPages = OfflineCollectionCatalog.PageAccumulator(uri: albumURI, kind: .album)
let partialAlbum = try albumPages.append(albumFirst)
require(partialAlbum == nil, "incomplete album published")
let fullAlbum = try albumPages.append(albumSecond)
require(fullAlbum?.totalCount == 101 && fullAlbum?.trackURIs.last == albumSecond.trackURIs[0],
        "full album pagination failed")
require(fullAlbum?.uniqueTrackURIs.count == 101, "unique album tracks lost")
require(fullAlbum?.tracks.last?.title == "Title 100" && fullAlbum?.tracks.last?.artist == "Artist 100",
        "album metadata lost across pages")
let playlistPage = try OfflineCollectionCatalog.parsePage(
    playlistResponse(playlistURI, total: 2, types: ["Track", "Track"]),
    uri: playlistURI, kind: .playlist, offset: 0)
require(playlistPage.totalCount == 2 && playlistPage.trackURIs.count == 2,
        "playlist parse failed")
require(playlistPage.tracks[0].title == "Title 0" && playlistPage.tracks[0].artist == "Artist 0",
        "playlist track labels lost")
let repeatedTrack = playlistPage.tracks[0]
let otherTrack = playlistPage.tracks[1]
var playlistPages = OfflineCollectionCatalog.PageAccumulator(uri: playlistURI, kind: .playlist)
let partialPlaylist = try playlistPages.append(.init(totalCount: 3,
                                                    tracks: [repeatedTrack, otherTrack]))
require(partialPlaylist == nil,
        "incomplete playlist published")
let fullPlaylist = try playlistPages.append(.init(totalCount: 3, tracks: [repeatedTrack]))
require(fullPlaylist?.trackURIs == [repeatedTrack.uri, otherTrack.uri, repeatedTrack.uri],
        "playlist occurrences lost")
require(fullPlaylist?.uniqueTrackURIs == [repeatedTrack.uri, otherTrack.uri],
        "repeated playlist track not deduplicated for WAV storage")
require(fullPlaylist?.uniqueTracks == [repeatedTrack, otherTrack],
        "first metadata occurrence not kept for a repeated track")

expectError(.invalidURI, "kind mismatch") {
    _ = try OfflineCollectionCatalog.makeRequest(uri: albumURI, kind: .playlist, offset: 0,
                                                 credential: fixtureCredential)
}
expectError(.missingAccessToken, "newline in token") {
    _ = try OfflineCollectionCatalog.makeRequest(uri: albumURI, kind: .album, offset: 0,
                                                 credential: SpotifyCatalogCredential(
                                                    accessToken: "BAD\nTOKEN", clientToken: "FIXTURE_CLIENT_TOKEN"))
}
expectError(.missingAccessToken, "newline in client token") {
    _ = try OfflineCollectionCatalog.makeRequest(uri: albumURI, kind: .album, offset: 0,
                                                 credential: SpotifyCatalogCredential(
                                                    accessToken: "FIXTURE_TOKEN", clientToken: "BAD\nTOKEN"))
}
expectError(.missingAccessToken, "empty client token") {
    _ = try OfflineCollectionCatalog.makeRequest(uri: albumURI, kind: .album, offset: 0,
                                                 credential: SpotifyCatalogCredential(
                                                    accessToken: "FIXTURE_TOKEN", clientToken: ""))
}
expectError(.invalidResponse, "URI mismatch") {
    _ = try OfflineCollectionCatalog.parsePage(albumResponse(wrongAlbumURI, total: 1),
                                               uri: albumURI, kind: .album, offset: 0)
}
expectError(.invalidResponse, "wrong entity") {
    _ = try OfflineCollectionCatalog.parsePage(albumResponse(albumURI, total: 1, entityType: "Artist"),
                                               uri: albumURI, kind: .album, offset: 0)
}
expectError(.invalidResponse, "truncated page") {
    _ = try OfflineCollectionCatalog.parsePage(albumResponse(albumURI, total: 2),
                                               uri: albumURI, kind: .album, offset: 0)
}
expectError(.invalidResponse, "bool count") {
    _ = try OfflineCollectionCatalog.parsePage(albumResponse(albumURI, total: true),
                                               uri: albumURI, kind: .album, offset: 0)
}
expectError(.invalidResponse, "oversized count") {
    _ = try OfflineCollectionCatalog.parsePage(albumResponse(albumURI, total: 5_001),
                                               uri: albumURI, kind: .album, offset: 0)
}
expectError(.invalidResponse, "GraphQL errors") {
    let body = json(["errors": [["message": "fixture"]], "data": [:]])
    _ = try OfflineCollectionCatalog.parsePage(body, uri: albumURI, kind: .album, offset: 0)
}
expectError(.invalidResponse, "oversized page") {
    _ = try OfflineCollectionCatalog.parsePage(Data(repeating: 0, count: 1_048_577),
                                               uri: albumURI, kind: .album, offset: 0)
}
var noName = trackData(0)
noName.removeValue(forKey: "name")
expectError(.invalidResponse, "missing track name") {
    _ = try OfflineCollectionCatalog.parsePage(albumTrackResponse(albumURI, track: noName),
                                               uri: albumURI, kind: .album, offset: 0)
}
var blankArtist = trackData(0)
blankArtist["artists"] = ["items": [["profile": ["name": " \n "]]]]
expectError(.invalidResponse, "blank artist") {
    _ = try OfflineCollectionCatalog.parsePage(albumTrackResponse(albumURI, track: blankArtist),
                                               uri: albumURI, kind: .album, offset: 0)
}
var tooLongName = trackData(0)
tooLongName["name"] = String(repeating: "x", count: 513)
expectError(.invalidResponse, "oversized track name") {
    _ = try OfflineCollectionCatalog.parsePage(albumTrackResponse(albumURI, track: tooLongName),
                                               uri: albumURI, kind: .album, offset: 0)
}
var multipleArtists = trackData(0)
multipleArtists["name"] = "  Title  "
multipleArtists["artists"] = ["items": [["profile": ["name": " Artist A "]],
                                        ["profile": ["name": "Artist B"]]]]
let multipleArtistPage = try OfflineCollectionCatalog.parsePage(
    albumTrackResponse(albumURI, track: multipleArtists), uri: albumURI, kind: .album, offset: 0)
require(multipleArtistPage.tracks[0].title == "Title" &&
        multipleArtistPage.tracks[0].artist == "Artist A, Artist B",
        "album labels not normalized")
var changedCountPages = OfflineCollectionCatalog.PageAccumulator(uri: playlistURI, kind: .playlist)
expectError(.invalidResponse, "unvalidated page label") {
    _ = try changedCountPages.append(.init(totalCount: 3,
        tracks: [.init(uri: otherTrack.uri, title: "\n", artist: "Artist")]))
}
let partialChangedCount = try changedCountPages.append(.init(totalCount: 3,
                                                              tracks: [repeatedTrack]))
require(partialChangedCount == nil,
        "partial playlist was published")
expectError(.invalidResponse, "count changed between pages") {
    _ = try changedCountPages.append(.init(totalCount: 2, tracks: [otherTrack]))
}
expectError(.invalidResponse, "page overflow") {
    _ = try changedCountPages.append(.init(totalCount: 3,
                                           tracks: [otherTrack, repeatedTrack, otherTrack]))
}
expectError(.invalidResponse, "noncanonical page track") {
    _ = try changedCountPages.append(.init(totalCount: 3,
        tracks: [.init(uri: "spotify:episode:0000000000000000000000", title: "Title", artist: "Artist")]))
}
expectError(.invalidResponse, "append after collection complete") {
    _ = try playlistPages.append(.init(totalCount: 3, tracks: [otherTrack]))
}
expectError(.unsupportedItem, "playlist episode") {
    _ = try OfflineCollectionCatalog.parsePage(
        playlistResponse(playlistURI, total: 1, types: ["Episode"]),
        uri: playlistURI, kind: .playlist, offset: 0)
}
expectError(.unsupportedItem, "playlist local track") {
    _ = try OfflineCollectionCatalog.parsePage(
        playlistResponse(playlistURI, total: 1, types: ["LocalTrack"]),
        uri: playlistURI, kind: .playlist, offset: 0)
}

print("OfflineCollectionCatalog host fixtures passed")
