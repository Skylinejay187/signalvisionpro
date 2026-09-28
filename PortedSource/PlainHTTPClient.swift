import Foundation
import Network

/// v325: crash-safe raw plain-HTTP helper for IPTV/Xtream panels that only expose http:// endpoints.
/// URLSession can be blocked by ATS if the generated/built plist is not applied by the sideload pipeline.
/// This helper is intentionally used only for http:// API text/json requests; https:// still uses URLSession.
final class PlainHTTPClient {
    enum PlainHTTPError: Error {
        case invalidURL
        case missingHost
        case connectionFailed
        case badResponse
        case timeout
    }

    private final class RequestState: @unchecked Sendable {
        typealias Output = (data: Data, statusCode: Int)

        private let lock = NSLock()
        private var connection: NWConnection?
        private var continuation: CheckedContinuation<Output, Error>?
        private var finished = false

        func install(connection: NWConnection, continuation: CheckedContinuation<Output, Error>) {
            lock.lock()
            if finished {
                lock.unlock()
                connection.cancel()
                return
            }
            self.connection = connection
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ result: Result<Output, Error>) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let connection = self.connection
            let continuation = self.continuation
            self.connection = nil
            self.continuation = nil
            lock.unlock()

            connection?.cancel()
            continuation?.resume(with: result)
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }
    }

    static func fetchData(from url: URL, accept: String = "*/*", userAgent: String = "DebridChannels-tvOS/325", maxBytes: Int = 4 * 1024 * 1024, timeout: TimeInterval = 30) async throws -> (data: Data, statusCode: Int) {
        guard url.scheme?.lowercased() == "http" else { throw PlainHTTPError.invalidURL }
        guard let hostName = url.host, !hostName.isEmpty else { throw PlainHTTPError.missingHost }
        let portNumber = UInt16(url.port ?? 80)
        guard let port = NWEndpoint.Port(rawValue: portNumber) else { throw PlainHTTPError.invalidURL }

        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { path += "?" + query }
        let hostHeader = (url.port == nil || url.port == 80) ? hostName : "\(hostName):\(portNumber)"
        let request = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nAccept: \(accept)\r\nAccept-Encoding: identity\r\nUser-Agent: \(userAgent)\r\nConnection: close\r\n\r\n"
        guard let requestData = request.data(using: .utf8) else { throw PlainHTTPError.invalidURL }

        let state = RequestState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let connection = NWConnection(host: NWEndpoint.Host(hostName), port: port, using: .tcp)
                state.install(connection: connection, continuation: continuation)
                var buffer = Data()

                func parseAndFinish() {
                    guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                        state.finish(.failure(PlainHTTPError.badResponse))
                        return
                    }
                    let headerData = buffer[..<headerRange.lowerBound]
                    let rawBody = Data(buffer[headerRange.upperBound...])
                    let headerText = String(data: headerData, encoding: .isoLatin1) ?? String(data: headerData, encoding: .utf8) ?? ""
                    let lines = headerText.components(separatedBy: "\r\n")
                    let statusCode = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
                    let lowerHeaders = headerText.lowercased()
                    let body: Data
                    if lowerHeaders.contains("transfer-encoding: chunked") {
                        body = decodeChunked(rawBody) ?? rawBody
                    } else {
                        body = rawBody
                    }
                    state.finish(.success((data: Data(body.prefix(maxBytes)), statusCode: statusCode)))
                }

                func receiveMore() {
                    if Task.isCancelled {
                        state.cancel()
                        return
                    }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                        if let error {
                            state.finish(.failure(error))
                            return
                        }
                        if let data, !data.isEmpty {
                            buffer.append(data)
                            if buffer.count > maxBytes + 512 * 1024 {
                                state.finish(.failure(PlainHTTPError.badResponse))
                                return
                            }
                        }
                        if isComplete {
                            parseAndFinish()
                        } else {
                            receiveMore()
                        }
                    }
                }

                connection.stateUpdateHandler = { connectionState in
                    switch connectionState {
                    case .ready:
                        connection.send(content: requestData, completion: .contentProcessed { error in
                            if let error {
                                state.finish(.failure(error))
                                return
                            }
                            receiveMore()
                        })
                    case .failed(let error):
                        state.finish(.failure(error))
                    case .cancelled:
                        if Task.isCancelled { state.cancel() }
                    default:
                        break
                    }
                }

                connection.start(queue: DispatchQueue.global(qos: .userInitiated))
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    state.finish(.failure(PlainHTTPError.timeout))
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        var output = Data()
        var index = data.startIndex
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: Data("\r\n".utf8)) else { return nil }
            let sizeData = data[index..<lineEnd.lowerBound]
            guard let sizeLine = String(data: sizeData, encoding: .ascii) else { return nil }
            let sizeHex = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeLine
            guard let size = Int(sizeHex.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return nil }
            index = lineEnd.upperBound
            if size == 0 { return output }
            guard data.distance(from: index, to: data.endIndex) >= size else { return nil }
            output.append(contentsOf: data[index..<data.index(index, offsetBy: size)])
            index = data.index(index, offsetBy: size)
            if data.distance(from: index, to: data.endIndex) >= 2 { index = data.index(index, offsetBy: 2) }
        }
        return output
    }
}
