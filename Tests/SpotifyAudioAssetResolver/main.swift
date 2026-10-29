import Foundation

// The host test has no Spotify process; the production value is captured in DataLoaderServiceHooks.
var spotifyAccessToken: String?

private func require(_ condition: @autoclosure () -> Bool, _ description: String) {
    guard condition() else { fatalError(description) }
}

private func varint(_ input: UInt64) -> Data {
    var value = input
    var result = Data()
    repeat {
        let byte = UInt8(value & 0x7f)
        value >>= 7
        result.append(value == 0 ? byte : byte | 0x80)
    } while value != 0
    return result
}

private func field(_ number: UInt64, _ value: UInt64) -> Data {
    var result = varint(number << 3)
    result.append(varint(value))
    return result
}

private func field(_ number: UInt64, _ bytes: Data) -> Data {
    var result = varint((number << 3) | 2)
    result.append(varint(UInt64(bytes.count)))
    result.append(bytes)
    return result
}

private func plus(_ parts: Data...) -> Data {
    parts.reduce(into: Data()) { $0.append($1) }
}

private func response(uri: String, fileID: Data, format: UInt64 = 0,
                      kind: UInt64 = 10, providerStatus: UInt64 = 200,
                      entryStatus: UInt64 = 200) -> Data {
    let audioFile = plus(field(1, fileID), field(2, format))
    let content = kind == 10 ? field(12, audioFile) : field(1, field(1, audioFile))
    let entry = plus(field(1, field(1, entryStatus)), field(2, Data(uri.utf8)),
                     field(3, field(2, content)))
    let array = plus(field(1, field(1, providerStatus)), field(2, kind), field(3, entry))
    return field(2, array)
}

private func requireThrows(_ description: String, _ operation: () throws -> Void) {
    do {
        try operation()
        fatalError("Expected failure: \(description)")
    } catch { }
}

let uri = "spotify:track:0123456789ABCDEFGHIJKL"
let otherURI = "spotify:track:ABCDEFGHIJKL0123456789"
let fileID = Data((0..<20).map(UInt8.init))

require(SpotifyAudioAssetResolver.isCanonicalTrackURI(uri), "canonical URI rejected")
require(!SpotifyAudioAssetResolver.isCanonicalTrackURI("https://open.spotify.com/track/0123456789ABCDEFGHIJKL"), "web URL accepted")
require(!SpotifyAudioAssetResolver.isCanonicalTrackURI("spotify:track:0123456789ABCDEFGHIJK!"), "invalid ID accepted")

let request = SpotifyAudioAssetResolver.makeTrackRequest(uri)
let expectedRequest = field(2, plus(field(1, Data(uri.utf8)),
                                    field(2, field(1, 10)), field(2, field(1, 5))))
require(request == expectedRequest, "metadata request wire shape changed")

let directFileID = try SpotifyAudioAssetResolver.parseVorbis96FileID(response(uri: uri, fileID: fileID), expectedTrackURI: uri)
require(directFileID == fileID, "TRACK_V4 format 0 not selected")
let wrappedFileID = try SpotifyAudioAssetResolver.parseVorbis96FileID(response(uri: uri, fileID: fileID, kind: 5), expectedTrackURI: uri)
require(wrappedFileID == fileID, "TRACK_V4 legacy wrapper not selected")

let mp3 = response(uri: uri, fileID: Data(repeating: 0xaa, count: 20), format: 1)
let vorbis = response(uri: uri, fileID: fileID)
let selectedFileID = try SpotifyAudioAssetResolver.parseVorbis96FileID(plus(mp3, vorbis), expectedTrackURI: uri)
require(selectedFileID == fileID, "format 0 must be chosen over MP3")

requireThrows("wrong track") {
    _ = try SpotifyAudioAssetResolver.parseVorbis96FileID(response(uri: otherURI, fileID: fileID), expectedTrackURI: uri)
}
requireThrows("provider status") {
    _ = try SpotifyAudioAssetResolver.parseVorbis96FileID(response(uri: uri, fileID: fileID, providerStatus: 403), expectedTrackURI: uri)
}
requireThrows("entry status") {
    _ = try SpotifyAudioAssetResolver.parseVorbis96FileID(response(uri: uri, fileID: fileID, entryStatus: 404), expectedTrackURI: uri)
}
requireThrows("short file ID") {
    _ = try SpotifyAudioAssetResolver.parseVorbis96FileID(response(uri: uri, fileID: Data(repeating: 1, count: 19)), expectedTrackURI: uri)
}
requireThrows("truncated protobuf") {
    _ = try SpotifyAudioAssetResolver.parseVorbis96FileID(Data([0x12, 0x80]), expectedTrackURI: uri)
}
requireThrows("oversized protobuf") {
    _ = try SpotifyAudioAssetResolver.parseVorbis96FileID(Data(repeating: 0, count: 1_048_577), expectedTrackURI: uri)
}

for url in ["https://audio-fa.scdn.co/a", "https://a.spotifycdn.com/a", "https://a-spotify-com.akamaized.net/a"] {
    require(SpotifyAudioAssetResolver.isAllowedCDNURL(URL(string: url)!), "approved CDN rejected")
}
for url in ["http://audio-fa.scdn.co/a", "https://scdn.co.evil.test/a", "https://user@audio-fa.scdn.co/a",
            "https://audio-fa.scdn.co:444/a", "https://audio-fa.scdn.co/a#fragment"] {
    require(!SpotifyAudioAssetResolver.isAllowedCDNURL(URL(string: url)!), "unapproved CDN accepted")
}

private final class StubMetadataProtocol: URLProtocol {
    static var requestedHosts: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "spclient.wg.spotify.com" || request.url?.host == "gue1-spclient.spotify.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url!.host!
        Self.requestedHosts.append(host)
        let body = response(uri: uri, fileID: fileID)
        let reply = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

spotifyAccessToken = "TOKEN"
let preflightConfiguration = URLSessionConfiguration.ephemeral
preflightConfiguration.protocolClasses = [StubMetadataProtocol.self]
var preflightResult: Result<SpotifyAudioAssetResolver.EncryptedAsset,
                            SpotifyAudioAssetResolver.ResolverError>?
var preflightSawFileID = false
SpotifyAudioAssetResolver.download(trackURI: uri, fileIDPreflight: { candidate in
    preflightSawFileID = candidate == fileID
    return false
}, configuration: preflightConfiguration) { preflightResult = $0 }
let preflightDeadline = Date().addingTimeInterval(5)
while preflightResult == nil && Date() < preflightDeadline {
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
}
guard case .failure(.playbackKeyUnavailable) = preflightResult else {
    fatalError("missing playback key did not stop resolution")
}
require(preflightSawFileID && StubMetadataProtocol.requestedHosts == ["spclient.wg.spotify.com"],
        "storage request began before file-ID preflight")

private final class StubCDNProtocol: URLProtocol {
    static var chunks: [Data] = []
    static var advertisedLength: Int?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "audio-fa.scdn.co"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var headers: [String: String] = [:]
        if let length = Self.advertisedLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private func receiveStub(chunks: [Data], advertisedLength: Int? = nil,
                         maximumBytes: Int64) -> (Result<SpotifyAudioAssetResolver.StagedDownload,
                                                       SpotifyAudioAssetResolver.ResolverError>, URL) {
    StubCDNProtocol.chunks = chunks
    StubCDNProtocol.advertisedLength = advertisedLength
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubCDNProtocol.self]
    let receiver = SpotifyAudioAssetResolver.BoundedCDNReceiver(maxBytes: maximumBytes, minimumBytes: 168)
    let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("eevee-receiver-test-\(UUID().uuidString).encrypted")
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<SpotifyAudioAssetResolver.StagedDownload,
                        SpotifyAudioAssetResolver.ResolverError>?
    receiver.receive(URL(string: "https://audio-fa.scdn.co/sample")!, in: session, to: destination) {
        outcome = $0
        done.signal()
    }
    require(done.wait(timeout: .now() + 5) == .success, "streaming receiver timed out")
    session.finishTasksAndInvalidate()
    return (outcome!, destination)
}

let validStream = receiveStub(chunks: [Data(repeating: 0xa5, count: 128),
                                       Data(repeating: 0x5a, count: 72)], maximumBytes: 256)
if case .success(let staged) = validStream.0 {
    require(staged.byteCount == 200, "streamed byte count changed")
    let stagedBytes = try Data(contentsOf: staged.fileURL)
    require(stagedBytes.count == 200, "streamed file incomplete")
    try FileManager.default.removeItem(at: staged.fileURL)
} else {
    fatalError("valid bounded stream failed")
}

// No Content-Length: the second chunk must be rejected before it is written.
let unboundedStream = receiveStub(chunks: [Data(repeating: 1, count: 200),
                                           Data(repeating: 2, count: 100)], maximumBytes: 256)
if case .failure(.incompleteDownload) = unboundedStream.0 {
    require(!FileManager.default.fileExists(atPath: unboundedStream.1.path), "overflow left a staged file")
} else {
    fatalError("missing Content-Length bypassed the byte cap")
}

// A plausible but false Content-Length must not override the observed-byte cap.
let falseLengthStream = receiveStub(chunks: [Data(repeating: 1, count: 200),
                                              Data(repeating: 2, count: 100)],
                                    advertisedLength: 200, maximumBytes: 256)
if case .failure(.incompleteDownload) = falseLengthStream.0 {
    require(!FileManager.default.fileExists(atPath: falseLengthStream.1.path), "false length left a staged file")
} else {
    fatalError("false Content-Length bypassed the byte cap")
}

print("Spotify audio asset resolver tests passed")
