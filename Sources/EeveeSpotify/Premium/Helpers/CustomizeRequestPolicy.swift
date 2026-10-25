import Foundation

enum CustomizeRequestPolicy {
    static func prepare(_ request: URLRequest, needsBody: Bool) -> URLRequest {
        guard needsBody, request.url?.isCustomize == true else { return request }
        var request = request
        // A cold patched cache cannot recover the account configuration from a 304.
        request.setValue(nil, forHTTPHeaderField: "If-None-Match")
        request.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}
