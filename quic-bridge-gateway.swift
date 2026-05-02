import Foundation
import Network
import Security

private let listenPort = UInt16(ProcessInfo.processInfo.environment["DEXRELAY_QUIC_PORT"] ?? "4617") ?? 4617
private let bridgeURL = URL(string: ProcessInfo.processInfo.environment["DEXRELAY_QUIC_BRIDGE_URL"] ?? "ws://127.0.0.1:4615")!
private let identityPath = ProcessInfo.processInfo.environment["DEXRELAY_QUIC_IDENTITY_P12"] ?? ""
private let identityPassword = ProcessInfo.processInfo.environment["DEXRELAY_QUIC_IDENTITY_PASSWORD"] ?? "dexrelay"
private let queue = DispatchQueue(label: "app.dexrelay.quic-gateway")
private let maxFrameBytes = 32 * 1024 * 1024
private var activeSessions: [UUID: BridgeSession] = [:]

private func log(_ message: String) {
    FileHandle.standardError.write(Data("[quic-gateway] \(message)\n".utf8))
}

private func loadIdentity(path: String, password: String) -> sec_identity_t? {
    guard !path.isEmpty,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        return nil
    }

    var items: CFArray?
    let options = [kSecImportExportPassphrase as String: password] as CFDictionary
    let status = SecPKCS12Import(data as CFData, options, &items)
    guard status == errSecSuccess,
          let array = items as? [[String: Any]],
          let identity = array.first?[kSecImportItemIdentity as String] else {
        log("failed to load QUIC identity from \(path) (status \(status))")
        return nil
    }
    return sec_identity_create(identity as! SecIdentity)
}

private func framed(_ text: String) -> Data {
    let payload = Data(text.utf8)
    var length = UInt32(payload.count).bigEndian
    var data = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    data.append(payload)
    return data
}

private final class BridgeSession {
    let id = UUID()
    private let connection: NWConnection
    private let webSocket: URLSessionWebSocketTask
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
        self.webSocket = URLSession.shared.webSocketTask(with: bridgeURL)
        self.webSocket.maximumMessageSize = maxFrameBytes
    }

    func start() {
        webSocket.resume()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveQUIC()
                self?.receiveWebSocket()
            case .failed(let error):
                log("QUIC connection failed: \(error)")
                self?.close()
            case .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveQUIC() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                log("QUIC receive failed: \(error)")
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainQUICFrames()
            }
            if isComplete {
                self.close()
                return
            }
            self.receiveQUIC()
        }
    }

    private func drainQUICFrames() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= maxFrameBytes else {
                log("dropping QUIC session with invalid frame length \(length)")
                close()
                return
            }
            let frameLength = Int(length)
            guard buffer.count >= 4 + frameLength else { return }
            let frame = buffer.subdata(in: 4..<(4 + frameLength))
            buffer.removeSubrange(0..<(4 + frameLength))
            guard let text = String(data: frame, encoding: .utf8) else { continue }
            webSocket.send(.string(text)) { [weak self] error in
                if let error {
                    log("bridge websocket send failed: \(error)")
                    self?.close()
                }
            }
        }
    }

    private func receiveWebSocket() {
        webSocket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.sendQUIC(text)
                self.receiveWebSocket()
            case .success(.data(let data)):
                if let text = String(data: data, encoding: .utf8) {
                    self.sendQUIC(text)
                }
                self.receiveWebSocket()
            case .failure(let error):
                log("bridge websocket receive failed: \(error)")
                self.close()
            @unknown default:
                self.receiveWebSocket()
            }
        }
    }

    private func sendQUIC(_ text: String) {
        connection.send(content: framed(text), completion: .contentProcessed { [weak self] error in
            if let error {
                log("QUIC send failed: \(error)")
                self?.close()
            }
        })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        webSocket.cancel(with: .goingAway, reason: nil)
        connection.cancel()
        queue.async {
            activeSessions.removeValue(forKey: self.id)
        }
    }
}

guard let port = NWEndpoint.Port(rawValue: listenPort) else {
    fatalError("invalid DEXRELAY_QUIC_PORT \(listenPort)")
}
guard let identity = loadIdentity(path: identityPath, password: identityPassword) else {
    fatalError("missing QUIC identity; set DEXRELAY_QUIC_IDENTITY_P12")
}

let options = NWProtocolQUIC.Options(alpn: ["dexrelay-bridge"])
options.direction = .bidirectional
sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)

let parameters = NWParameters(quic: options)
parameters.allowLocalEndpointReuse = true

let listener = try NWListener(using: parameters, on: port)
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        log("listening on udp/\(listenPort), forwarding to \(bridgeURL.absoluteString)")
    case .failed(let error):
        log("listener failed: \(error)")
        exit(1)
    default:
        break
    }
}
listener.newConnectionHandler = { connection in
    let session = BridgeSession(connection: connection)
    activeSessions[session.id] = session
    session.start()
}
listener.start(queue: queue)

dispatchMain()
