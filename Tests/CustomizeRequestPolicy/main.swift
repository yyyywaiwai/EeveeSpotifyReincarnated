import Foundation

var request = URLRequest(url: URL(string: "https://spclient.spotify.com/user-customization-service/v1/customize")!)
request.httpMethod = "POST"
request.httpBody = Data([1, 2, 3])
request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
request.setValue("fixture-etag", forHTTPHeaderField: "If-None-Match")
request.setValue("Mon, 26 Oct 2026 00:00:00 GMT", forHTTPHeaderField: "If-Modified-Since")

let cold = CustomizeRequestPolicy.prepare(request, needsBody: true)
assert(cold.value(forHTTPHeaderField: "If-None-Match") == nil)
assert(cold.value(forHTTPHeaderField: "If-Modified-Since") == nil)
assert(cold.cachePolicy == .reloadIgnoringLocalCacheData)
assert(cold.url == request.url && cold.httpMethod == request.httpMethod && cold.httpBody == request.httpBody)
assert(cold.value(forHTTPHeaderField: "Authorization") == request.value(forHTTPHeaderField: "Authorization"))
assert(CustomizeRequestPolicy.prepare(request, needsBody: false) == request)

var unrelated = request
unrelated.url = URL(string: "https://spclient.spotify.com/collection/v1/library")!
assert(CustomizeRequestPolicy.prepare(unrelated, needsBody: true) == unrelated)
var noURL = request
noURL.url = nil
assert(CustomizeRequestPolicy.prepare(noURL, needsBody: true) == noURL)
print("CustomizeRequestPolicy regression tests passed")
