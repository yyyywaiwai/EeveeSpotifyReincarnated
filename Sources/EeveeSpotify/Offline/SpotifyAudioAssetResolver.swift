import Foundation

/// Resolves a Spotify track to its 96 kb/s Vorbis asset and stages the encrypted file.
/// The staged file belongs to the caller and should be removed after decoding or failure.
enum SpotifyAudioAssetResolver {
    struct EncryptedAsset {
        let trackURI: String
        let fileID: Data
        let encryptedFileURL: URL
        let encryptedByteCount: Int64
    }

    enum ResolverError: Error {
        case invalidTrackURI
        case missingAccessToken
        case transport
        case unexpectedHTTPStatus
        case invalidResponse
        case audioFileMissing
        case playbackKeyUnavailable
        case invalidCDNURL
        case incompleteDownload
        case fileSystem
    }

    private static let metadataURL = URL(string: "https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata")!
    private static let maxMetadataBytes = 1_048_576
    private static let maxEncryptedBytes: Int64 = 128 * 1_048_576
    private static let minimumEncryptedBytes: Int64 = 168 // 167-byte PlayPlay header plus audio.

    /// Completion is delivered on the main queue. No credential or CDN URL is persisted.
    static func download(trackURI: String, fileIDPreflight: @escaping (Data) -> Bool,
                         configuration: URLSessionConfiguration = .ephemeral,
                         completion: @escaping (Result<EncryptedAsset, ResolverError>) -> Void) {
        guard isCanonicalTrackURI(trackURI) else {
            DispatchQueue.main.async { completion(.failure(.invalidTrackURI)) }
            return
        }
        guard let token = spotifyAccessToken, !token.isEmpty,
              token.rangeOfCharacter(from: .newlines) == nil else {
            DispatchQueue.main.async { completion(.failure(.missingAccessToken)) }
            return
        }

        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        let receiver = BoundedCDNReceiver(maxBytes: maxEncryptedBytes, minimumBytes: minimumEncryptedBytes)
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)

        func finish(_ result: Result<EncryptedAsset, ResolverError>) {
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async { completion(result) }
        }

        var metadataRequest = URLRequest(url: metadataURL)
        metadataRequest.httpMethod = "POST"
        metadataRequest.httpBody = makeTrackRequest(trackURI)
        metadataRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        metadataRequest.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        metadataRequest.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")

        session.dataTask(with: metadataRequest) { data, response, error in
            guard error == nil else { finish(.failure(.transport)); return }
            guard let body = validatedSmallBody(data, response: response) else {
                finish(.failure(.unexpectedHTTPStatus)); return
            }
            let fileID: Data
            do {
                fileID = try parseVorbis96FileID(body, expectedTrackURI: trackURI)
            } catch let resolverError as ResolverError {
                finish(.failure(resolverError)); return
            } catch {
                finish(.failure(.invalidResponse)); return
            }
            guard fileIDPreflight(fileID) else {
                finish(.failure(.playbackKeyUnavailable)); return
            }

            let fileIDHex = fileID.map { String(format: "%02x", $0) }.joined()
            let storageURL = URL(string: "https://gue1-spclient.spotify.com/storage-resolve/v2/files/audio/interactive/10/\(fileIDHex)?version=10000000&product=9&platform=39&alt=json")!
            var storageRequest = URLRequest(url: storageURL)
            storageRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            storageRequest.setValue("application/json", forHTTPHeaderField: "Accept")

            session.dataTask(with: storageRequest) { data, response, error in
                guard error == nil else { finish(.failure(.transport)); return }
                guard let body = validatedSmallBody(data, response: response) else {
                    finish(.failure(.unexpectedHTTPStatus)); return
                }
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let urls = object["cdnurl"] as? [String],
                      let first = urls.first,
                      let cdnURL = URL(string: first), isAllowedCDNURL(cdnURL) else {
                    finish(.failure(.invalidCDNURL)); return
                }

                // Stream to disk and cancel before a missing or false Content-Length can exhaust storage.
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("eevee-offline-\(UUID().uuidString).encrypted", isDirectory: false)
                receiver.receive(cdnURL, in: session, to: destination) { result in
                    switch result {
                    case .success(let staged):
                        finish(.success(EncryptedAsset(trackURI: trackURI, fileID: fileID,
                                                       encryptedFileURL: staged.fileURL,
                                                       encryptedByteCount: staged.byteCount)))
                    case .failure(let failure):
                        finish(.failure(failure))
                    }
                }
            }.resume()
        }.resume()
    }

    static func isCanonicalTrackURI(_ uri: String) -> Bool {
        let prefix = "spotify:track:"
        guard uri.hasPrefix(prefix), uri.utf8.count == prefix.utf8.count + 22 else { return false }
        return uri.utf8.dropFirst(prefix.utf8.count).allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    static func isAllowedCDNURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.fragment == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com") ||
            host.hasSuffix("-spotify-com.akamaized.net")
    }

    private static func validatedSmallBody(_ data: Data?, response: URLResponse?) -> Data? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data = data, !data.isEmpty, data.count <= maxMetadataBytes,
              http.expectedContentLength < 0 || Int64(data.count) == http.expectedContentLength else { return nil }
        return data
    }

    // The request and parser mirror the in-app extended-metadata wire trace for 9.1.88.
    static func makeTrackRequest(_ uri: String) -> Data {
        let track = protobufBytesField(1, Data(uri.utf8))
        let queries = [10, 5].map { protobufBytesField(2, protobufVarintField(1, UInt64($0))) }
        return protobufBytesField(2, queries.reduce(into: track) { $0.append($1) })
    }

    static func parseVorbis96FileID(_ data: Data, expectedTrackURI uri: String) throws -> Data {
        guard isCanonicalTrackURI(uri) else { throw ResolverError.invalidTrackURI }
        let wanted = Data(uri.utf8)
        for rawArray in try fields(data).bytesValues(2) {
            let array = try fields(rawArray)
            guard let kind = try array.lastVarint(2), kind == 10 || kind == 5 else { continue }
            let provider = try fields(array.concatenatedBytes(1))
            guard try provider.lastVarint(1) == 200 else { continue }
            for rawEntry in try array.bytesValues(3) {
                let entry = try fields(rawEntry)
                let header = try fields(entry.concatenatedBytes(1))
                guard try header.lastVarint(1) == 200,
                      try entry.lastBytes(2) == wanted else { continue }
                let any = try fields(entry.concatenatedBytes(3))
                guard let payload = try any.lastBytes(2), !payload.isEmpty else { continue }
                let content = try fields(payload)
                let rawFiles: [Data]
                if kind == 10 {
                    rawFiles = try content.bytesValues(12)
                } else {
                    rawFiles = try content.bytesValues(1).map { try fields($0).concatenatedBytes(1) }
                }
                for rawFile in rawFiles {
                    let file = try fields(rawFile)
                    guard let fileID = try file.lastBytes(1), fileID.count == 20,
                          let format = try file.lastVarint(2) else { throw ResolverError.invalidResponse }
                    if format == 0 { return fileID } // OGG_VORBIS_96, storage format 10.
                }
            }
        }
        throw ResolverError.audioFileMissing
    }

    private static func protobufVarint(_ value: UInt64) -> Data {
        var value = value
        var output = Data()
        repeat {
            let byte = UInt8(value & 0x7f)
            value >>= 7
            output.append(value == 0 ? byte : byte | 0x80)
        } while value != 0
        return output
    }

    private static func protobufVarintField(_ number: UInt64, _ value: UInt64) -> Data {
        var output = protobufVarint(number << 3)
        output.append(protobufVarint(value))
        return output
    }

    private static func protobufBytesField(_ number: UInt64, _ bytes: Data) -> Data {
        var output = protobufVarint((number << 3) | 2)
        output.append(protobufVarint(UInt64(bytes.count)))
        output.append(bytes)
        return output
    }

    fileprivate struct Field {
        let number: Int
        let wire: Int
        let value: UInt64?
        let bytes: Data?
    }

    private static func fields(_ data: Data) throws -> [Field] {
        guard data.count <= maxMetadataBytes else { throw ResolverError.invalidResponse }
        let bytes = [UInt8](data)
        var offset = 0
        var output: [Field] = []

        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw ResolverError.invalidResponse }
                let byte = bytes[offset]
                offset += 1
                if index == 9 && byte > 1 { throw ResolverError.invalidResponse }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte & 0x80 == 0 { return value }
            }
            throw ResolverError.invalidResponse
        }

        func take(_ count: Int) throws -> Data {
            guard count <= bytes.count - offset else { throw ResolverError.invalidResponse }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }

        while offset < bytes.count {
            guard output.count < 16_384 else { throw ResolverError.invalidResponse }
            let tag = try varint()
            let number = tag >> 3
            guard number > 0, number <= 0x1fff_ffff else { throw ResolverError.invalidResponse }
            let wire = Int(tag & 7)
            switch wire {
            case 0:
                output.append(Field(number: Int(number), wire: wire, value: try varint(), bytes: nil))
            case 1:
                _ = try take(8)
                output.append(Field(number: Int(number), wire: wire, value: nil, bytes: nil))
            case 2:
                let length = try varint()
                guard length <= UInt64(maxMetadataBytes) else { throw ResolverError.invalidResponse }
                output.append(Field(number: Int(number), wire: wire, value: nil, bytes: try take(Int(length))))
            case 5:
                _ = try take(4)
                output.append(Field(number: Int(number), wire: wire, value: nil, bytes: nil))
            default:
                throw ResolverError.invalidResponse
            }
        }
        return output
    }

    struct StagedDownload {
        let fileURL: URL
        let byteCount: Int64
    }

    /// Data-task delegate, so the cap applies to every received chunk before it reaches disk.
    final class BoundedCDNReceiver: NSObject, URLSessionDataDelegate {
        private let maxBytes: Int64
        private let minimumBytes: Int64
        private var taskID: Int?
        private var fileURL: URL?
        private var file: FileHandle?
        private var count: Int64 = 0
        private var expectedLength: Int64 = -1
        private var failure: ResolverError?
        private var completion: ((Result<StagedDownload, ResolverError>) -> Void)?

        init(maxBytes: Int64, minimumBytes: Int64) {
            self.maxBytes = maxBytes
            self.minimumBytes = minimumBytes
        }

        func receive(_ url: URL, in session: URLSession, to destination: URL,
                     completion: @escaping (Result<StagedDownload, ResolverError>) -> Void) {
            guard taskID == nil, maxBytes >= minimumBytes, isAllowedCDNURL(url) else {
                completion(.failure(.invalidCDNURL)); return
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]),
                  let handle = try? FileHandle(forWritingTo: destination) else {
                try? FileManager.default.removeItem(at: destination)
                completion(.failure(.fileSystem)); return
            }
            fileURL = destination
            file = handle
            self.completion = completion
            let task = session.dataTask(with: URLRequest(url: url)) // No Authorization header.
            taskID = task.taskIdentifier
            task.resume()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard dataTask.taskIdentifier == taskID else { completionHandler(.allow); return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = http.url, isAllowedCDNURL(finalURL),
                  http.expectedContentLength < 0 ||
                    (http.expectedContentLength >= minimumBytes && http.expectedContentLength <= maxBytes) else {
                failure = .incompleteDownload
                completionHandler(.cancel)
                return
            }
            expectedLength = http.expectedContentLength
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard dataTask.taskIdentifier == taskID, failure == nil else { return }
            guard let file = file else {
                failure = .fileSystem
                dataTask.cancel()
                return
            }
            guard Int64(data.count) <= maxBytes - count else {
                failure = .incompleteDownload
                dataTask.cancel()
                return
            }
            do {
                try file.write(contentsOf: data)
                count += Int64(data.count)
            } catch {
                failure = .fileSystem
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard task.taskIdentifier == taskID else { return }
            if let file = file {
                do { try file.close() } catch { failure = .fileSystem }
            }
            let destination = fileURL
            let measuredSize = destination.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.int64Value
            }
            let result: Result<StagedDownload, ResolverError>
            if let failure = failure {
                result = .failure(failure)
            } else if error != nil {
                result = .failure(.transport)
            } else if let destination = destination, measuredSize == count,
                      count >= minimumBytes, count <= maxBytes,
                      expectedLength < 0 || count == expectedLength {
                result = .success(StagedDownload(fileURL: destination, byteCount: count))
            } else {
                result = .failure(.incompleteDownload)
            }
            if case .failure = result, let destination = destination {
                try? FileManager.default.removeItem(at: destination)
            }
            let callback = completion
            taskID = nil
            fileURL = nil
            file = nil
            count = 0
            expectedLength = -1
            failure = nil
            completion = nil
            callback?(result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let original = task.originalRequest?.url,
                  let destination = request.url else { completionHandler(nil); return }
            if original.host == metadataURL.host || original.host == "gue1-spclient.spotify.com" {
                guard destination.scheme?.lowercased() == "https",
                      destination.host == original.host,
                      destination.port == nil || destination.port == 443 else {
                    completionHandler(nil); return
                }
                completionHandler(request)
            } else if isAllowedCDNURL(original), isAllowedCDNURL(destination) {
                var cleanRequest = request
                cleanRequest.setValue(nil, forHTTPHeaderField: "Authorization")
                completionHandler(cleanRequest)
            } else {
                completionHandler(nil)
            }
        }
    }
}

private extension Array where Element == SpotifyAudioAssetResolver.Field {
    func values(_ number: Int, wire: Int) throws -> [SpotifyAudioAssetResolver.Field] {
        var result: [SpotifyAudioAssetResolver.Field] = []
        for field in self where field.number == number {
            guard field.wire == wire else { throw SpotifyAudioAssetResolver.ResolverError.invalidResponse }
            result.append(field)
        }
        return result
    }

    func bytesValues(_ number: Int) throws -> [Data] {
        try values(number, wire: 2).compactMap(\.bytes)
    }

    func lastBytes(_ number: Int) throws -> Data? {
        try bytesValues(number).last
    }

    func lastVarint(_ number: Int) throws -> UInt64? {
        try values(number, wire: 0).last?.value
    }

    func concatenatedBytes(_ number: Int) throws -> Data {
        try bytesValues(number).reduce(into: Data()) { $0.append($1) }
    }
}
