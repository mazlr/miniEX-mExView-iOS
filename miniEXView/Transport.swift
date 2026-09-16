import Foundation
import Network

protocol MiniEXTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onRawData: ((Data) -> Void)? { get set }
    var onState: ((String) -> Void)? { get set }
    var onWrite: ((Int, String?) -> Void)? { get set }
    func connect(host: String, port: UInt16)
    func send(_ data: Data)
    func disconnect()
}

/// All connection changes run on one serial queue. Old callbacks cannot
/// report a cancelled socket as the state of a newly opened connection.
final class TCPTransport: MiniEXTransport {
    var onData: ((Data) -> Void)?
    var onRawData: ((Data) -> Void)?
    var onState: ((String) -> Void)?
    var onWrite: ((Int, String?) -> Void)?

    private let queue = DispatchQueue(label: "miniEX.tcp")
    private var connection: NWConnection?
    private var ready = false

    func connect(host: String, port: UInt16) {
        queue.async { [self] in
            let previous = connection
            connection = nil
            ready = false
            previous?.cancel()

            let current = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            connection = current
            onState?("Connecting…")
            current.stateUpdateHandler = { [weak self, weak current] state in
                guard let self, let current, self.connection === current else { return }
                switch state {
                case .ready:
                    self.ready = true
                    self.onState?("Connected")
                    self.receive(from: current)
                case .waiting(let error):
                    self.ready = false
                    self.onState?("Waiting for network: \(error.localizedDescription)")
                case .failed(let error):
                    self.close(current, reason: "Socket error: \(error.localizedDescription)")
                case .cancelled:
                    self.close(current, reason: "Disconnected: connection cancelled")
                default:
                    break
                }
            }
            current.start(queue: queue)
        }
    }

    func send(_ data: Data) {
        queue.async { [self] in
            guard let current = connection, ready else {
                onWrite?(data.count, "Socket is not ready.")
                return
            }
            current.send(content: data, completion: .contentProcessed { [weak self, weak current] error in
                guard let self, let current, self.connection === current else { return }
                self.onWrite?(data.count, error?.localizedDescription)
                if let error { self.close(current, reason: "Write error: \(error.localizedDescription)") }
            })
        }
    }

    func disconnect() {
        queue.async { [self] in
            guard let current = connection else { return }
            close(current, reason: "Disconnected by user")
        }
    }

    private func receive(from current: NWConnection) {
        current.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak current] data, _, complete, error in
            guard let self, let current, self.connection === current else { return }
            if let data, !data.isEmpty { self.onRawData?(data); self.onData?(data) }
            if let error {
                self.close(current, reason: "Read error: \(error.localizedDescription)")
            } else if complete {
                self.close(current, reason: "Disconnected: device closed TCP (EOF)")
            } else {
                self.receive(from: current)
            }
        }
    }

    private func close(_ current: NWConnection, reason: String) {
        guard connection === current else { return }
        connection = nil
        ready = false
        current.cancel()
        onState?(reason)
    }
}
