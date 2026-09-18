import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class IINACompanionMenuApp: NSObject, NSApplicationDelegate {
    private let remote = IINARemote()
    private let updater = UpdateManager()
    private var statusItem: NSStatusItem!
    private var panel: StatusPanel!
    private var cancellables = Set<AnyCancellable>()
    private var preferredHeight: CGFloat = 370
    private var lockedPanelX: CGFloat?
    private var lockedPanelTop: CGFloat?

    static func main() {
        let application = NSApplication.shared
        let delegate = IINACompanionMenuApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "IINA Companion")
            button.action = #selector(togglePanel)
            button.target = self
        }

        let root = MenuContent(remote: remote, updater: updater) { [weak self] height in
            self?.resizePanel(to: height)
        }
        let host = NSHostingController(rootView: root)
        panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 370, height: preferredHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false

        remote.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.statusItem.button?.image = NSImage(
                    systemSymbolName: connected ? "play.rectangle.on.rectangle.fill" : "play.rectangle.on.rectangle",
                    accessibilityDescription: connected ? "IINA 已連線" : "IINA 未連線"
                )
            }
            .store(in: &cancellables)
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionPanel(height: preferredHeight)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func resizePanel(to height: CGFloat) {
        preferredHeight = height
        guard panel != nil else { return }
        if panel.isVisible {
            let x = lockedPanelX ?? panel.frame.minX
            let top = lockedPanelTop ?? panel.frame.maxY
            panel.setFrame(
                NSRect(x: x, y: top - height, width: 370, height: height),
                display: true,
                animate: false
            )
        } else {
            var frame = panel.frame
            frame.size.width = 370
            frame.size.height = height
            panel.setFrame(frame, display: false)
        }
    }

    private func positionPanel(height: CGFloat) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let width: CGFloat = 370
        let preferredX = buttonRect.midX - width / 2
        let x = min(max(preferredX, visible.minX + 4), visible.maxX - width - 4)
        let top = buttonRect.minY - 5
        lockedPanelX = x
        lockedPanelTop = top
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: false)
    }
}

private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

struct MenuContent: View {
    @ObservedObject var remote: IINARemote
    @ObservedObject var updater: UpdateManager
    let onPreferredHeight: (CGFloat) -> Void
    @AppStorage("host") private var host = "127.0.0.1"
    @AppStorage("port") private var port = 19190
    @AppStorage("token") private var token = ""
    @State private var showingSettings = false
    @State private var seekValue = 0.0
    @State private var isSeeking = false
    @State private var volumeValue = 50.0
    @State private var isAdjustingVolume = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if remote.isConnected {
                connectedControls
            } else {
                disconnectedView
            }

            Divider()

            HStack {
                Button(showingSettings ? "隱藏設定" : "連線設定") {
                    showingSettings.toggle()
                    DispatchQueue.main.async { onPreferredHeight(preferredHeight) }
                }
                .buttonStyle(.plain)

                Spacer()

                Text("v\(updater.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                updateButton

                Button("結束") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
            }

            if showingSettings { settings }
        }
        .padding(16)
        .frame(width: 370, height: preferredHeight, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: true)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            remote.configure(host: host, port: port, token: token)
            remote.start()
            updater.checkAutomatically()
            onPreferredHeight(preferredHeight)
        }
        .onChange(of: remote.progress) { newValue in
            if !isSeeking { seekValue = newValue }
        }
        .onChange(of: remote.volume) { newValue in
            if !isAdjustingVolume { volumeValue = newValue }
        }
        .onChange(of: remote.isConnected) { _ in
            onPreferredHeight(preferredHeight)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(remote.isConnected ? Color.green : Color.red)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("IINA Companion")
                    .font(.headline)
                Text(remote.connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if remote.isConnecting { ProgressView().controlSize(.small) }
        }
    }

    private var connectedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if remote.players.count > 1 {
                Picker("播放視窗", selection: Binding(
                    get: { remote.selectedPlayerID },
                    set: { remote.selectPlayer($0) }
                )) {
                    ForEach(remote.players) { player in
                        Text(player.displayName).tag(player.id)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(remote.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack {
                    Text(remote.playbackLabel)
                    Spacer()
                    Text("剩餘 \(remote.formattedRemaining)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Slider(value: $seekValue, in: 0...100, onEditingChanged: { editing in
                isSeeking = editing
                if !editing {
                    remote.command("set_position_percent", args: ["percent": seekValue])
                }
            })
                .tint(.orange)

            HStack {
                Text(remote.formattedPosition(forProgress: isSeeking ? seekValue : remote.progress))
                Spacer()
                Text(remote.formattedDuration)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                controlButton("backward.end.fill", "上一首") { remote.command("playlist_previous") }
                controlButton("gobackward.10", "後退 10 秒") { remote.command("seek_relative", args: ["seconds": -10]) }
                Button {
                    remote.command("toggle_play_pause")
                } label: {
                    Label(remote.isPlaying ? "暫停" : "播放",
                          systemImage: remote.isPlaying ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                controlButton("goforward.10", "前進 10 秒") { remote.command("seek_relative", args: ["seconds": 10]) }
                controlButton("forward.end.fill", "下一首") { remote.command("playlist_next") }
            }

            HStack(spacing: 8) {
                Button { remote.command("stop") } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                Button { remote.command("toggle_mute") } label: {
                    Label(remote.isMuted ? "取消靜音" : "靜音",
                          systemImage: remote.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                Button { remote.command("toggle_fullscreen") } label: {
                    Label("全螢幕", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            .labelStyle(.iconOnly)
            .help("停止、靜音、全螢幕")

            HStack(spacing: 9) {
                Button { remote.command("toggle_mute") } label: {
                    Image(systemName: remote.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.plain)
                .help(remote.isMuted ? "取消靜音" : "靜音")

                Slider(value: $volumeValue, in: 0...100, onEditingChanged: { editing in
                    isAdjustingVolume = editing
                    if !editing {
                        remote.command("set_volume", args: ["volume": volumeValue])
                    }
                })
                .tint(.orange)

                Text("\(Int(volumeValue.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Menu {
                    playbackModeButton("不循環（不自動下一首）", mode: "none")
                    playbackModeButton("單曲循環", mode: "single")
                    playbackModeButton("自動下一首（清單結束不循環）", mode: "auto_next")
                    playbackModeButton("清單循環", mode: "playlist_loop")
                    playbackModeButton("隨機播放", mode: "shuffle")
                } label: {
                    HStack {
                        Text("循環方式：\(playbackModeLabel)")
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                }
                .menuStyle(.borderlessButton)

                Button("Remote Controller") {
                    remote.command("controller_visibility", args: ["operation": "toggle"], includePlayer: false)
                }
            }

            playlist

            if let error = updater.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundColor(Color(updater.state == .upToDate ? NSColor.secondaryLabelColor : NSColor.systemRed))
            }
        }
    }

    private var playlist: some View {
        VStack(spacing: 0) {
            HStack {
                Label("播放清單", systemImage: "music.note.list")
                Spacer()
                Text("\(remote.playlistItems.count) 首")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)

            playlistDrawer
        }
    }

    private var playlistDrawer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()

            if remote.playlistItems.isEmpty {
                Text("播放清單目前是空的")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(remote.playlistItems) { item in
                            Button {
                                remote.command("playlist_play", args: ["index": item.index + 1])
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: item.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                                        .foregroundStyle(item.isPlaying ? .orange : .secondary)
                                        .frame(width: 18)
                                    Text(item.label)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(item.index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .background(item.isPlaying ? Color.orange.opacity(0.14) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 117)
            }
        }
        .frame(height: 125, alignment: .top)
        .clipped()
    }

    private var preferredHeight: CGFloat {
        let base: CGFloat = remote.isConnected ? 502 : 205
        let settingsHeight: CGFloat = showingSettings ? 112 : 0
        return base + settingsHeight
    }

    private var playbackModeLabel: String {
        switch remote.playbackMode {
        case "single": return "單曲循環"
        case "auto_next": return "自動下一首"
        case "playlist_loop": return "清單循環"
        case "shuffle": return "隨機播放"
        default: return "不循環"
        }
    }

    private func playbackModeButton(_ label: String, mode: String) -> some View {
        Button {
            remote.setPlaybackMode(mode)
        } label: {
            if remote.playbackMode == mode {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }


    @ViewBuilder
    private var updateButton: some View {
        switch updater.state {
        case .idle, .upToDate:
            Button("檢查更新") { updater.checkForUpdates() }
                .buttonStyle(.plain)
        case .checking:
            ProgressView().controlSize(.small)
        case .available(let version):
            Button("安裝 v\(version)") { updater.downloadAndInstall() }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
        case .downloading(let progress):
            ProgressView(value: progress)
                .frame(width: 64)
        case .installing:
            Text("安裝中…").font(.caption)
        case .failed:
            Button("重試更新") { updater.checkForUpdates() }
                .buttonStyle(.plain)
        }
    }

    private var disconnectedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(remote.lastError.isEmpty ? "正在等待 IINA 外掛…" : remote.lastError)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("啟動 IINA") { remote.launchIINA() }
                Button("重新連線") {
                    remote.configure(host: host, port: port, token: token)
                    remote.reconnect()
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("IINA 外掛連線")
                .font(.subheadline.weight(.semibold))
            HStack {
                TextField("IP 位址", text: $host)
                TextField("Port", value: $port, format: .number)
                    .frame(width: 76)
            }
            SecureField("配對金鑰", text: $token)
            HStack {
                Spacer()
                Button("儲存並重新連線") {
                    remote.configure(host: host, port: port, token: token)
                    remote.reconnect()
                    showingSettings = false
                    DispatchQueue.main.async { onPreferredHeight(preferredHeight) }
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func controlButton(_ image: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: image) }
            .help(help)
    }
}
