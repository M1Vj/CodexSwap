import Foundation
import NIOCore
import NIOHTTP1
import AsyncHTTPClient

// MARK: - Hardened Chat Completions passthrough
//
// Clients that already speak OpenAI's Chat Completions wire (opencode, scripts,
// other agents) can reach bridged models directly through the local proxy. The
// free gateways behind these models intermittently drop streams before the first
// byte, so this lane retries pre-stream failures with backoff and then streams
// bytes verbatim. Like the Responses bridge, it never touches account state.

enum AlphaPassthrough {
    static let maxAttempts = 3

    static func handle(
        entry: BridgedModel,
        body: Data,
        httpClient: HTTPClient,
        outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    ) async throws {
        guard let base = URL(string: entry.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return try await writePlainError(outbound, status: .internalServerError, message: "Bridged model has an invalid base URL")
        }
        var request = HTTPClientRequest(url: base.appendingPathComponent("chat/completions").absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        if !entry.apiKey.isEmpty {
            request.headers.add(name: "Authorization", value: "Bearer \(entry.apiKey)")
        }
        request.body = .bytes(ByteBuffer(bytes: body))

        var response: HTTPClientResponse?
        var lastStatus = HTTPResponseStatus.badGateway
        var lastErrorDetail = ""
        var transportFailure = false
        for attempt in 1...maxAttempts {
            do {
                response = try await httpClient.execute(request, timeout: .seconds(600))
                transportFailure = false
            } catch {
                lastErrorDetail = "\(error)"
                response = nil
                transportFailure = true
            }
            if let resp = response, resp.status == .ok {
                break
            }
            if let resp = response {
                lastStatus = resp.status
                // Drain small error bodies so the connection can be reused cleanly.
                var detail = ByteBuffer()
                for try await chunk in resp.body {
                    detail.writeImmutableBuffer(chunk)
                    if detail.readableBytes > 16 * 1024 { break }
                }
                lastErrorDetail = String(buffer: detail)
                response = nil
            }
            guard attempt < maxAttempts else { break }
            // Only transport failures and rate/server errors are worth retrying.
            let retryable = transportFailure || lastStatus.code == 429 || lastStatus.code >= 500
            guard retryable else { break }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
        }

        guard let upstream = response, upstream.status == .ok else {
            let message = lastErrorDetail.isEmpty ? "upstream returned \(lastStatus.code)" : lastErrorDetail
            return try await writePlainError(outbound, status: .badGateway, message: message)
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: upstream.headers.first(name: "Content-Type") ?? "application/json")
        headers.add(name: "Cache-Control", value: "no-cache")
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))
        for try await chunk in upstream.body {
            try await outbound.write(.body(.byteBuffer(chunk)))
        }
        try await outbound.write(.end(nil))
    }

    /// Matches a POST body against the enabled bridged catalog for this lane.
    static func resolveEntry(
        in rawBody: Data,
        contentEncoding: String? = nil,
        catalog: [BridgedModel]
    ) -> AlphaBridge.BridgedModelResolution {
        AlphaBridge.resolveEntry(
            in: rawBody,
            contentEncoding: contentEncoding,
            catalog: catalog
        )
    }

    static func writePlainError(
        _ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        status: HTTPResponseStatus,
        message: String
    ) async throws {
        let payload: [String: Any] = ["error": ["message": String(message.prefix(2000))]]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: String(data.count))
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: data))))
        try await outbound.write(.end(nil))
    }
}
