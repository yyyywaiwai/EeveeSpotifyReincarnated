import Foundation
import CoreFoundation

struct SpotifyCatalogCredential {
    let accessToken: String
    let clientToken: String
}

/// A complete, URI-bound collection snapshot for a native download action.
/// It is deliberately not a download result: the WAV index is the authority for saved state.
enum OfflineCollectionCatalog {
    struct Track: Equatable {
        let uri: String
        let title: String
        let artist: String
    }

    enum Kind: String {
        case album
        case playlist

        var operation: String { self == .album ? "getAlbum" : "fetchPlaylist" }
        var hash: String {
            // Votify db14e4d, api.py. A changed persisted-query contract fails closed.
            self == .album
                ? "b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10"
                : "bb67e0af06e8d6f52b531f97468ee4acd44cd0f82b988e15c2ea47b1148efc77"
        }
        var responseKey: String { self == .album ? "albumUnion" : "playlistV2" }
        var itemsKey: String { self == .album ? "tracksV2" : "content" }
        var typeName: String { self == .album ? "Album" : "Playlist" }
    }

    struct Collection {
        let uri: String
        let kind: Kind
        let tracks: [Track]

        var totalCount: Int { tracks.count }
        var trackURIs: [String] { tracks.map(\.uri) }

        /// Playlist occurrences stay in tracks; one saved WAV is enough for repeated URIs.
        var uniqueTracks: [Track] {
            var seen = Set<String>()
            return tracks.filter { seen.insert($0.uri).inserted }
        }
        var uniqueTrackURIs: [String] { uniqueTracks.map(\.uri) }

        /// Only this exact scope can truthfully use the one-song WAV backend as a collection action.
        func singleAlbumTrackURI(expectedAlbumURI: String) -> String? {
            guard kind == .album, uri == expectedAlbumURI, tracks.count == 1 else { return nil }
            return tracks[0].uri
        }
    }

    struct Page {
        let totalCount: Int
        let tracks: [Track]
        var trackURIs: [String] { tracks.map(\.uri) }
    }

    struct PageAccumulator {
        let uri: String
        let kind: Kind
        private(set) var tracks: [Track] = []
        private(set) var expectedCount: Int?

        mutating func append(_ page: Page) throws -> Collection? {
            guard page.totalCount > 0, page.totalCount <= maxTracks,
                  expectedCount == nil || expectedCount == page.totalCount,
                  !page.tracks.isEmpty,
                  page.tracks.count <= page.totalCount - tracks.count,
                  page.tracks.allSatisfy({ isCanonicalEntityURI($0.uri, entity: "track") &&
                      validatedDisplayText($0.title) == $0.title &&
                      validatedDisplayText($0.artist) == $0.artist }) else {
                throw CatalogError.invalidResponse
            }
            expectedCount = page.totalCount
            tracks.append(contentsOf: page.tracks)
            guard tracks.count == page.totalCount else { return nil }
            return Collection(uri: uri, kind: kind, tracks: tracks)
        }
    }

    enum CatalogError: Error {
        case invalidURI
        case missingAccessToken
        case transport
        case unexpectedHTTPStatus
        case invalidResponse
        case unsupportedItem
        case ineligibleCollectionSize
    }

    static let pageLimit = 100
    static let maxTracks = 5_000
    static let maxPages = 50
    static let maxPageBytes = 1_048_576
    private static let endpoint = URL(string: "https://api-partner.spotify.com/pathfinder/v2/query")!

    static func kind(for uri: String) -> Kind? {
        if isCanonicalURI(uri, kind: .album) { return .album }
        if isCanonicalURI(uri, kind: .playlist) { return .playlist }
        return nil
    }

    static func isCanonicalURI(_ uri: String, kind: Kind) -> Bool {
        isCanonicalEntityURI(uri, entity: kind.rawValue)
    }

    private static func isCanonicalEntityURI(_ uri: String, entity: String) -> Bool {
        let prefix = "spotify:\(entity):"
        guard uri.hasPrefix(prefix), uri.utf8.count == prefix.utf8.count + 22 else { return false }
        return uri.utf8.dropFirst(prefix.utf8.count).allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    static func makeRequest(uri: String, kind: Kind, offset: Int, limit: Int = pageLimit,
                            credential: SpotifyCatalogCredential) throws -> URLRequest {
        guard isCanonicalURI(uri, kind: kind), offset >= 0, offset < maxTracks,
              limit > 0, limit <= pageLimit else {
            throw CatalogError.invalidURI
        }
        guard !credential.accessToken.isEmpty, !credential.clientToken.isEmpty,
              credential.accessToken.rangeOfCharacter(from: .newlines) == nil,
              credential.clientToken.rangeOfCharacter(from: .newlines) == nil else {
            throw CatalogError.missingAccessToken
        }
        var variables: [String: Any] = ["uri": uri, "offset": offset, "limit": limit]
        if kind == .playlist { variables["enableWatchFeedEntrypoint"] = true }
        let body: [String: Any] = [
            "operationName": kind.operation,
            "variables": variables,
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": kind.hash]]
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.clientToken, forHTTPHeaderField: "Client-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        return request
    }

    /// Parses one exact page of the pinned Pathfinder contract. No partial response is accepted.
    static func parsePage(_ data: Data, uri: String, kind: Kind, offset: Int,
                          limit: Int = pageLimit) throws -> Page {
        guard isCanonicalURI(uri, kind: kind), data.count > 0, data.count <= maxPageBytes,
              offset >= 0, offset < maxTracks, limit > 0, limit <= pageLimit,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["errors"] == nil,
              let responseData = root["data"] as? [String: Any],
              let entity = responseData[kind.responseKey] as? [String: Any],
              entity["__typename"] as? String == kind.typeName,
              entity["uri"] as? String == uri,
              let list = entity[kind.itemsKey] as? [String: Any],
              let total = strictCount(list["totalCount"]), total > 0, total <= maxTracks,
              let items = list["items"] as? [[String: Any]],
              offset < total,
              items.count == min(limit, total - offset) else {
            throw CatalogError.invalidResponse
        }

        var tracks: [Track] = []
        tracks.reserveCapacity(items.count)
        for item in items {
            let media: [String: Any]?
            if kind == .album {
                media = item["track"] as? [String: Any]
            } else {
                media = (item["itemV2"] as? [String: Any])?["data"] as? [String: Any]
            }
            guard let media else { throw CatalogError.invalidResponse }
            if kind == .playlist, media["__typename"] as? String != "Track" {
                throw CatalogError.unsupportedItem
            }
            guard let trackURI = media["uri"] as? String,
                  isCanonicalEntityURI(trackURI, entity: "track") else {
                throw CatalogError.invalidResponse
            }
            guard let title = validatedDisplayText(media["name"]),
                  let artists = media["artists"] as? [String: Any],
                  let artistItems = artists["items"] as? [[String: Any]],
                  !artistItems.isEmpty, artistItems.count <= 32 else {
                throw CatalogError.invalidResponse
            }
            let names = artistItems.compactMap {
                validatedDisplayText(($0["profile"] as? [String: Any])?["name"])
            }
            guard names.count == artistItems.count,
                  let artist = validatedDisplayText(names.joined(separator: ", ")) else {
                throw CatalogError.invalidResponse
            }
            tracks.append(Track(uri: trackURI, title: title, artist: artist))
        }
        return Page(totalCount: total, tracks: tracks)
    }

    private static func validatedDisplayText(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 512,
              !clean.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return clean
    }

    private static func strictCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let decimal = number.stringValue
        guard !decimal.isEmpty, decimal.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(decimal)
    }

    /// Fetches all pages with an in-memory Bearer/Client-Token pair captured from one app request.
    /// Completion is always on the main queue.
    // shortcut: equal totalCount cannot detect same-size edits during paging; the save job re-fetches before declaring completion, but a server revision is needed for atomicity.
    static func fetch(uri: String, completion: @escaping (Result<Collection, CatalogError>) -> Void) {
        guard let kind = kind(for: uri) else {
            DispatchQueue.main.async { completion(.failure(.invalidURI)) }
            return
        }
        fetch(uri: uri, kind: kind, limit: pageLimit, maxEligibleTracks: nil,
              completion: completion)
    }

    /// Native one-song album action: fetch at most one item, inspect totalCount,
    /// and stop before a second request if the collection is larger.
    static func fetchSingleAlbum(uri: String,
                                 completion: @escaping (Result<Collection, CatalogError>) -> Void) {
        guard isCanonicalURI(uri, kind: .album) else {
            DispatchQueue.main.async { completion(.failure(.invalidURI)) }
            return
        }
        fetch(uri: uri, kind: .album, limit: 1, maxEligibleTracks: 1,
              completion: completion)
    }

    private static func fetch(uri: String, kind: Kind, limit: Int, maxEligibleTracks: Int?,
                              completion: @escaping (Result<Collection, CatalogError>) -> Void) {
        guard let credential = spotifyCatalogCredential else {
            DispatchQueue.main.async { completion(.failure(.missingAccessToken)) }
            return
        }
        var accumulator = PageAccumulator(uri: uri, kind: kind)

        func finish(_ result: Result<Collection, CatalogError>) {
            DispatchQueue.main.async { completion(result) }
        }

        func nextPage(_ pageNumber: Int) {
            guard pageNumber < maxPages else { finish(.failure(.invalidResponse)); return }
            let request: URLRequest
            do {
                request = try makeRequest(uri: uri, kind: kind, offset: accumulator.tracks.count, limit: limit,
                                          credential: credential)
            } catch let error as CatalogError {
                finish(.failure(error)); return
            } catch {
                finish(.failure(.invalidResponse)); return
            }
            BoundedPathfinderPage.fetch(request, maxBytes: maxPageBytes) { result in
                switch result {
                case .failure(let error):
                    finish(.failure(error))
                case .success(let body):
                    let page: Page
                    do {
                        page = try parsePage(body, uri: uri, kind: kind, offset: accumulator.tracks.count,
                                             limit: limit)
                    } catch let error as CatalogError {
                        finish(.failure(error)); return
                    } catch {
                        finish(.failure(.invalidResponse)); return
                    }
                    if let maxEligibleTracks, page.totalCount > maxEligibleTracks {
                        finish(.failure(.ineligibleCollectionSize)); return
                    }
                    do {
                        if let collection = try accumulator.append(page) {
                            finish(.success(collection))
                        } else {
                            nextPage(pageNumber + 1)
                        }
                    } catch let error as CatalogError {
                        finish(.failure(error))
                    } catch {
                        finish(.failure(.invalidResponse))
                    }
                }
            }
        }
        nextPage(0)
    }
}

/// URLSession completion handlers buffer unbounded responses; this delegate cancels at a hard cap.
private final class BoundedPathfinderPage: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let maxBytes: Int
    private let completion: (Result<Data, OfflineCollectionCatalog.CatalogError>) -> Void
    private var session: URLSession?
    private var body = Data()
    private var accepted = false
    private var finished = false
    private var overflow = false
    private var expectedBytes: Int64 = -1
    private var expectedLengthIsIdentity = false

    private init(maxBytes: Int, completion: @escaping (Result<Data, OfflineCollectionCatalog.CatalogError>) -> Void) {
        self.maxBytes = maxBytes
        self.completion = completion
    }

    static func fetch(_ request: URLRequest, maxBytes: Int,
                      completion: @escaping (Result<Data, OfflineCollectionCatalog.CatalogError>) -> Void) {
        let receiver = BoundedPathfinderPage(maxBytes: maxBytes, completion: completion)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
        receiver.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "application/json",
              http.expectedContentLength < 0 || http.expectedContentLength <= maxBytes else {
            completionHandler(.cancel)
            return
        }
        accepted = true
        expectedBytes = http.expectedContentLength
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        expectedLengthIsIdentity = encoding == nil || encoding == "identity"
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard accepted, !overflow else { return }
        guard data.count <= maxBytes - body.count else {
            overflow = true
            dataTask.cancel()
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        let result: Result<Data, OfflineCollectionCatalog.CatalogError>
        if overflow { result = .failure(.invalidResponse) }
        else if !accepted { result = .failure(.unexpectedHTTPStatus) }
        else if error != nil { result = .failure(.transport) }
        else if body.isEmpty { result = .failure(.invalidResponse) }
        else if expectedLengthIsIdentity && expectedBytes >= 0 && Int64(body.count) != expectedBytes {
            result = .failure(.invalidResponse)
        }
        else { result = .success(body) }
        completion(result)
        self.session?.finishTasksAndInvalidate()
        self.session = nil
    }
}
