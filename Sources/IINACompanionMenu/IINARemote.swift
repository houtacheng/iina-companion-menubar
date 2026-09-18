import AppKit
import Foundation

struct PlayerSummary: Identifiable, Equatable {
    let id: String
    var label: String
    var state: [String: Any]

    static func == (lhs: PlayerSummary, rhs: PlayerSummary) -> Bool { lhs.id == rhs.id }

    var displayName: String {
        let title = state["title"] as? String ?? ""
        return title.isEmpty ? (label.isEmpty ? "播放視窗" : label) : title
    }
}

struct PlaylistMenuItem: Identifiable {
    let index: Int
    let label: String
    let isPlaying: Bool
    var id: Int { index }
}

@MainActor
final class IINARemote: ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var lastError = ""
    @Published var players: [PlayerSummary] = []
    @Published var selectedPlayerID = ""
    @Published var state: [String: Any] = [:]

    private var host = "127.0.0.1"
    private var port = 19190
    private var token = ""
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var generation = 0
    private var started = false

    var connectionLabel: String {
        if isConnected { return "已連線 · \(host):\(port)" }
        if isConnecting { return "連線中 · \(host):\(port)" }
        return "未連線 · \(host):\(port)"
    }

    var title: String {
        let value = state["title"] as? String ?? ""
        return value.isEmpty ? "尚未播放媒體" : value
    }

    var isPlaying: Bool { (state["playback"] as? String) == "playing" }
    var isMuted: Bool { state["muted"] as? Bool ?? false }
    var playbackMode: String { state["playbackMode"] as? String ?? "none" }
    var progress: Double { number(state["progress"]) ?? 0 }
    var volume: Double { max(0, min(100, number(state["volume"]) ?? 0)) }
    var playlistItems: [PlaylistMenuItem] {
        guard let rawItems = state["playlistItems"] as? [[String: Any]] else { return [] }
        return rawItems.enumerated().map { offset, item in
            let index = (item["id"] as? NSNumber)?.intValue ?? offset
            let label = item["label"] as? String ?? "項目 \(index + 1)"
            return PlaylistMenuItem(index: index, label: label, isPlaying: item["isPlaying"] as? Bool ?? false)
        }
    }
    var formattedDuration: String { formatTime(number(state["duration"])) }
    var playbackLabel: String {
        switch state["playback"] as? String {
        case "playing": return "播放中"
        case "paused": return "已暫停"
        default: return "閒置"
        }
    }
    var formattedRemaining: String { formatTime(number(state["remaining"])) }

    func formattedPosition(forProgress progress: Double) -> String {
        guard let duration = number(state["duration"]), duration > 0 else {
            return formatTime(number(state["position"]))
        }
        return formatTime(duration * max(0, min(100, progress)) / 100)
    }

    func configure(host: String, port: Int, token: String) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() {
        guard !started else { return }
        started = true
        connect()
    }

    func reconnect() {
        disconnect(scheduleReconnect: false)
        connect()
    }

    func selectPlayer(_ id: String) {
        selectedPlayerID = id
        if let player = players.first(where: { $0.id == id }) { state = player.state }
        command("select_player", args: ["playerId": id], includePlayer: false)
    }

    func setPlaybackMode(_ mode: String) {
        command("set_playback_mode", args: ["mode": mode])
    }

    func command(_ name: String, args: [String: Any] = [:], includePlayer: Bool = true) {
        var outgoingArgs = args
        if includePlayer, !selectedPlayerID.isEmpty { outgoingArgs["playerId"] = selectedPlayerID }
        send([
            "type": "command",
            "command": name,
            "args": outgoingArgs,
            "requestId": UUID().uuidString,
        ])
    }

    func launchIINA() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.colliderli.iina") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        scheduleReconnect(after: 1)
    }

    private func connect() {
        guard socket == nil, !isConnecting else { return }
        guard !host.isEmpty, (1...65535).contains(port) else {
            lastError = "請檢查 IP 位址與 Port。"
            return
        }
        guard !token.isEmpty else {
            lastError = "請先輸入 IINA 外掛的配對金鑰。"
            return
        }
        guard let url = URL(string: "ws://\(host):\(port)") else {
            lastError = "連線位址無效。"
            return
        }

        generation += 1
        let currentGeneration = generation
        isConnecting = true
        lastError = ""
        reconnectTask?.cancel()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 5
        let newSession = URLSession(configuration: configuration)
        let newSocket = newSession.webSocketTask(with: url)
        session = newSession
        socket = newSocket
        newSocket.resume()

        send(["type": "auth", "token": token, "requestId": "menubar-auth"])
        receiveTask = Task { [weak self] in await self?.receiveLoop(generation: currentGeneration) }
    }

    private func receiveLoop(generation expectedGeneration: Int) async {
        while !Task.isCancelled, expectedGeneration == generation, let socket {
            do {
                let message = try await socket.receive()
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let data): text = String(decoding: data, as: UTF8.self)
                @unknown default: continue
                }
                handle(text)
            } catch {
                if expectedGeneration == generation {
                    connectionFailed("IINA 連線已中斷。")
                }
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "auth_result":
            guard object["ok"] as? Bool == true else {
                connectionFailed("配對金鑰不正確。")
                return
            }
            isConnected = true
            isConnecting = false
            lastError = ""
            if let initialState = object["state"] as? [String: Any] { state = initialState }
            send(["type": "get_players", "requestId": "menubar-players"])
            beginHeartbeat()
        case "players":
            guard let rawPlayers = object["players"] as? [[String: Any]] else { return }
            players = rawPlayers.compactMap { raw in
                guard let id = raw["id"] as? String else { return nil }
                return PlayerSummary(id: id,
                                     label: raw["label"] as? String ?? "",
                                     state: raw["state"] as? [String: Any] ?? [:])
            }
            if selectedPlayerID.isEmpty || !players.contains(where: { $0.id == selectedPlayerID }) {
                selectedPlayerID = players.first?.id ?? ""
            }
            if let player = players.first(where: { $0.id == selectedPlayerID }) { state = player.state }
        case "state", "command_result":
            let playerID = object["playerId"] as? String ?? selectedPlayerID
            guard let newState = object["state"] as? [String: Any] else { return }
            if let index = players.firstIndex(where: { $0.id == playerID }) {
                players[index].state = newState
            }
            if selectedPlayerID.isEmpty { selectedPlayerID = playerID }
            if playerID == selectedPlayerID { state = newState }
        case "error":
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                lastError = message
            }
        default:
            break
        }
    }

    private func beginHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.send(["type": "ping", "requestId": "menubar-ping"])
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        Task { [weak self] in
            do { try await socket.send(.string(text)) }
            catch { self?.connectionFailed("無法傳送指令，正在重新連線。") }
        }
    }

    private func connectionFailed(_ message: String) {
        lastError = message
        disconnect(scheduleReconnect: true)
    }

    private func disconnect(scheduleReconnect: Bool) {
        generation += 1
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
        isConnected = false
        isConnecting = false
        if scheduleReconnect { self.scheduleReconnect(after: 3) }
    }

    private func scheduleReconnect(after seconds: Double) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func formatTime(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--:--" }
        let seconds = max(0, Int(value.rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
