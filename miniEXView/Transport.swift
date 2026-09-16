import Foundation
import Network

protocol MiniEXTransport: AnyObject {
    var onData: ((Data) -> Void)? { get set }; var onState: ((String) -> Void)? { get set }
    var onWrite: ((Int, String?) -> Void)? { get set }
    func connect(host: String, port: UInt16); func send(_ data: Data); func disconnect()
}

final class TCPTransport: MiniEXTransport {
    var onData: ((Data) -> Void)?; var onState: ((String) -> Void)?
    var onWrite: ((Int, String?) -> Void)?
    private let queue = DispatchQueue(label: "miniEX.tcp"); private var connection: NWConnection?
    func connect(host: String, port: UInt16) {
        disconnect(); let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp); connection = c
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?("Připojeno"); self?.receive()
            case .waiting(let e): self?.onState?("Čekám: \(e.localizedDescription)")
            case .failed(let e): self?.onState?("Chyba: \(e.localizedDescription)")
            case .cancelled: self?.onState?("Odpojeno")
            default: break
            }
        }; c.start(queue: queue); onState?("Připojuji…")
    }
    func send(_ data: Data) {
        guard let connection else { onWrite?(data.count, "Socket není otevřen."); return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            self?.onWrite?(data.count, error?.localizedDescription)
        })
    }
    func disconnect() { connection?.cancel(); connection = nil; onState?("Odpojeno") }
    private func receive() { connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
        if let data, !data.isEmpty { self?.onData?(data) }; if let error { self?.onState?("Chyba čtení: \(error.localizedDescription)") }; if !done { self?.receive() }
    } }
}
