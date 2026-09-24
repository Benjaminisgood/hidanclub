import HidanCore
import SwiftUI

/// Dance with one friend over a direct link: lobby (open a room / join one),
/// then a two-tile stage with the shared beat from the music bar.
struct PartyView: View {
    @ObservedObject var party: PartyService
    @ObservedObject var camera: LivePoseCamera
    @ObservedObject var music: MusicService
    @State private var joiningRoom: PartyService.NearbyRoom?
    @State private var codeDraft = ""
    @State private var addressDraft = ""
    @State private var manualCodeDraft = ""
    @State private var remoteMirrored = false

    var body: some View {
        Group {
            if party.isConnected { stage } else { lobby }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if party.role == .none { party.startBrowsing() } }
        .onDisappear { if party.role == .none { party.stopBrowsing() } }
        .onChange(of: party.role) { _, role in
            if role == .none, party.phase == .idle { party.startBrowsing() }
            if role != .none { joiningRoom = nil; codeDraft = "" }
        }
        .onChange(of: party.phase) { _, phase in
            if phase == .idle, party.role == .none { party.startBrowsing() }
        }
    }

    // MARK: Lobby

    private var lobby: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ClubPageTitle(title: "一起跳", eyebrow: "PARTY · P2P",
                              subtitle: "和好友在同一网络里直接连线：互相看见画面与关节，跟着同一个节拍一起开始。视频只在两台 Mac 之间传输，不经过服务器，也不保存。")
                if case .ended(let reason) = party.phase {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(ClubTheme.accent)
                        Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("知道了") { party.dismissEnded() }.controlSize(.small)
                    }
                    .padding(14).background(ClubTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if let error = party.errorMessage, party.role != .host {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        hostCard.frame(maxWidth: .infinity)
                        joinCard.frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 18) { hostCard; joinCard }
                }
                howItWorks
            }
            .padding(ClubTheme.pageInset)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hostCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("开房间").font(.headline)
                HStack(spacing: 10) {
                    Text("我的名字").font(.callout)
                    TextField("名字", text: $party.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .disabled(party.role != .none)
                        .accessibilityIdentifier("party.displayName")
                }
                if party.role == .host {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(party.roomCode)
                            .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit()).tracking(8)
                            .foregroundStyle(ClubTheme.accent)
                            .textSelection(.enabled)
                            .accessibilityLabel("房间码 \(party.roomCode)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("房间码").font(.caption.weight(.semibold))
                            Text("只告诉要一起跳的人").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("同一 Wi‑Fi 的好友会在「加入好友」里看到「\(party.displayName)」。手动加入时输入下面任一地址。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let port = party.port {
                        if party.localAddresses.isEmpty {
                            Text("端口 \(port) · 当前没有可用的局域网地址").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        ForEach(party.localAddresses, id: \.self) { address in
                            Text(Self.joinable(address, port: port)).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } else {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在开启…").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let request = party.pendingRequest {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.questionmark").font(.title3).foregroundStyle(ClubTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(request.name) 想加入").font(.callout.weight(.semibold))
                                Text("已通过房间码 · Hidan Club \(request.appVersion)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("拒绝") { party.declinePendingRequest() }
                            Button("接受") { party.approvePendingRequest() }.buttonStyle(.borderedProminent)
                        }
                        .padding(12).background(ClubTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("等待好友加入…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error = party.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("关闭房间", systemImage: "xmark.circle") { party.stopHosting() }
                } else {
                    Text("开启后，同一局域网的好友能搜到你的房间。加入需要你屏幕上的 4 位房间码，并由你确认。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("开启房间", systemImage: "door.left.hand.open") { party.startHosting() }
                        .buttonStyle(.borderedProminent)
                        .disabled(party.role != .none || party.displayName.isEmpty)
                        .accessibilityIdentifier("party.host")
                }
            }
        }
    }

    private var joinCard: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("加入好友").font(.headline)
                    Spacer()
                    if party.isBrowsing && party.role == .none {
                        ProgressView().controlSize(.small)
                        Text("正在搜索附近…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if party.role == .host {
                    Text("你已开启房间。关闭房间后可以加入别人。").font(.caption).foregroundStyle(.secondary)
                } else if party.phase == .connecting || party.phase == .waitingForApproval {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(party.phase == .connecting ? "正在连接…" : "已连上，等待对方接受…").font(.callout)
                        Spacer(minLength: 8)
                        Button("取消") { party.leave() }
                    }
                } else {
                    if party.nearby.isEmpty {
                        Text("还没发现附近的房间。请让好友先「开启房间」，并确认两台 Mac 在同一 Wi‑Fi；也可以用下面的地址加入。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(party.nearby) { room in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 10) {
                                Image(systemName: "person.wave.2").foregroundStyle(ClubTheme.accent)
                                Text(room.name).font(.callout.weight(.medium)).lineLimit(1)
                                if !room.compatible { Text("版本不同").font(.caption2).foregroundStyle(.orange) }
                                Spacer(minLength: 8)
                                Button(joiningRoom == room ? "取消" : "加入") {
                                    if joiningRoom == room { joiningRoom = nil } else { joiningRoom = room; codeDraft = "" }
                                }.disabled(!room.compatible)
                            }
                            if joiningRoom == room {
                                HStack(spacing: 8) {
                                    TextField("房间码", text: $codeDraft)
                                        .textFieldStyle(.roundedBorder).font(.body.monospacedDigit()).frame(width: 96)
                                        .onSubmit { party.join(room: room, code: codeDraft) }
                                    Button("连接") { party.join(room: room, code: codeDraft) }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(PartyRoomCode.normalize(codeDraft) == nil)
                                    Text("对方屏幕上的 4 位数字").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Divider()
                    Text("或按地址加入").font(.caption.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("192.168.1.8:52000", text: $addressDraft)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(maxWidth: 220)
                            .accessibilityIdentifier("party.address")
                        TextField("房间码", text: $manualCodeDraft)
                            .textFieldStyle(.roundedBorder).font(.body.monospacedDigit()).frame(width: 90)
                            .accessibilityIdentifier("party.code")
                        Button("加入") { party.join(addressText: addressDraft, code: manualCodeDraft) }
                            .disabled(PartyAddress.parse(addressDraft) == nil || PartyRoomCode.normalize(manualCodeDraft) == nil)
                    }
                    Text("对方房间下方列出的地址。同一 Wi‑Fi、有线直连或 VPN 内网都可以。")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var howItWorks: some View {
        ClubCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("怎么一起跳").font(.headline)
                step(1, "一台 Mac 开启房间，另一台在同一网络里搜到它，输入房间码，房主点「接受」。")
                step(2, "各自开启摄像头，再选择共享「只共享骨架」或「画面与骨架」。默认不共享。")
                step(3, "房主用底部音乐条选节拍或音乐，点「一起开始」：两边同时倒数、同时起拍；客人可以随时关掉「跟随」。")
                Text("画面按 H.264 直接发给对方，不经过服务器、不保存、不录音。房间码派生的密钥加密整条链路。导入的音乐不会发给对方，对方听到的是同速的原创节拍。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(ClubTheme.accent, in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func joinable(_ address: String, port: UInt16) -> String {
        // "192.168.1.8 (en0)" → "192.168.1.8:52000 (en0)"
        guard let space = address.firstIndex(of: " ") else { return "\(address):\(port)" }
        return "\(address[..<space]):\(port) \(address[space...].dropFirst())"
    }

    // MARK: Stage

    private var peerName: String { party.peer?.name ?? "好友" }

    private var stage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("与 \(peerName) 一起跳", systemImage: "person.2.wave.2").font(.title3.weight(.semibold)).lineLimit(1)
                Text(party.role == .host ? "你是房主" : "你是客人").font(.caption).foregroundStyle(.secondary)
                if let rtt = party.statistics.roundTripMilliseconds {
                    Text(rtt < 1 ? "延迟 <1 ms" : "延迟 \(Int(rtt.rounded())) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("离开", systemImage: "rectangle.portrait.and.arrow.right") { party.leave() }.controlSize(.small)
            }
            HStack(spacing: 12) {
                tile(title: "我", detail: localDetail) {
                    LivePoseCameraSurface(camera: camera)
                }
                tile(title: peerName, detail: remoteDetail) {
                    PartyRemoteSurface(frames: party.remoteFrames, mirrored: remoteMirrored, peerName: peerName, sharing: party.remoteSharing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 260)
            .overlay {
                if let countdown = party.countdown { PartyCountdownOverlay(countdown: countdown) }
            }
            // Natural height for the tray; the tiles take whatever remains above it.
            PlayerControlCard {
                VStack(alignment: .leading, spacing: 10) {
                    ControlFlow(spacing: 10) {
                        Picker("共享", selection: $party.shareMode) {
                            ForEach(PartyShareMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                        .help("发给对方的内容。默认不共享；骨架不含画面。")
                        .accessibilityIdentifier("party.shareMode")
                        Picker("画质", selection: $party.quality) {
                            ForEach(PartyService.VideoQuality.allCases) { Text($0.title).tag($0) }
                        }
                        .frame(width: 190).help("发送画面的宽度与码率")
                        PlayerToggle(title: "对方镜像", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: $remoteMirrored)
                    }
                    LivePoseCameraControls(camera: camera, compact: true)
                    if party.shareMode != .off && !camera.isRunning {
                        Text("开启摄像头后才会开始共享。").font(.caption2).foregroundStyle(.orange)
                    }
                    Divider()
                    beatControls
                    Text(statisticsText).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    if let failure = party.sharingStatus {
                        Text("发送画面出错：\(failure)").font(.caption2).foregroundStyle(.orange)
                    }
                    if let error = party.errorMessage {
                        Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
    }

    @ViewBuilder private var beatControls: some View {
        if party.role == .host {
            ControlFlow(spacing: 8) {
                Button("一起开始 · 3 秒倒数", systemImage: "play.fill") { party.startTogether() }
                    .buttonStyle(.borderedProminent).disabled(party.countdown != nil)
                    .accessibilityIdentifier("party.startTogether")
                Button("停止", systemImage: "stop.fill") { party.stopTogether() }
                Text(hostBeatCaption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            ControlFlow(spacing: 8) {
                Toggle("跟随 \(peerName) 的节拍", isOn: $party.followHostBeat).toggleStyle(.switch).controlSize(.small)
                if let beat = party.hostBeat {
                    Text(guestBeatCaption(beat)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("对方还没有开始播放。").font(.caption).foregroundStyle(.secondary)
                }
                if let start = party.nextBarStartLocal {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        Label("等下一个八拍进入 · \(String(format: "%.1f", max(0, start - PartyService.now()))) 秒", systemImage: "metronome")
                            .font(.caption.monospacedDigit()).foregroundStyle(ClubTheme.accent)
                    }
                }
            }
            if party.hostBeat?.isTrack == true {
                Text("对方在听自己导入的音乐；你这边是同速的原创节拍，音乐文件不会传过来。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hostBeatCaption: String {
        let snapshot = music.partyBeatSnapshot
        let tempo = snapshot.bpm.map { "\(Int($0.rounded())) BPM" } ?? "BPM 未知"
        return "底部音乐条就是共享节拍：\(snapshot.sourceName) · \(tempo) · \(snapshot.isPlaying ? "播放中" : "已停止")"
    }

    private func guestBeatCaption(_ beat: PartyBeatState) -> String {
        let tempo = beat.bpm.map { "\(Int($0.rounded())) BPM" } ?? "BPM 未知"
        return "对方：\(beat.sourceName) · \(tempo) · \(beat.playing ? "播放中" : "已停止")"
    }

    private var localDetail: String {
        switch party.shareMode {
        case .off: return camera.isRunning ? "只有你自己看得到" : "摄像头未开启"
        case .skeleton: return camera.isRunning ? "对方只看到骨架" : "开启摄像头后共享骨架"
        case .video: return camera.isRunning ? "正在发送画面与骨架" : "开启摄像头后共享画面"
        }
    }

    private var remoteDetail: String {
        switch party.remoteSharing {
        case .off: return "对方未共享"
        case .skeleton: return "对方只共享骨架"
        case .video: return "接收 \(Int(party.statistics.receivedFramesPerSecond.rounded())) fps"
        }
    }

    private var statisticsText: String {
        let s = party.statistics
        var parts: [String] = []
        if s.outputWidth > 0 { parts.append("发送 \(s.outputWidth)×\(s.outputHeight) · \(Int(s.sentFramesPerSecond.rounded())) fps · \(Int(s.sentKilobitsPerSecond.rounded())) kbps") }
        if s.receivedFramesPerSecond > 0 || s.receivedKilobitsPerSecond > 0 { parts.append("接收 \(Int(s.receivedFramesPerSecond.rounded())) fps · \(Int(s.receivedKilobitsPerSecond.rounded())) kbps") }
        if let offset = s.clockOffsetMilliseconds { parts.append("时钟差 \(Int(offset.rounded())) ms") }
        if s.droppedForBackpressure > 0 { parts.append("网络慢时跳过 \(s.droppedForBackpressure) 帧") }
        parts.append("直连 · 加密 · 不保存")
        return parts.joined(separator: "   ")
    }

    private func tile<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: title == "我" ? "web.camera" : "person.wave.2").font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The friend's picture and joints. Mirroring is a viewing choice; the data is untouched.
struct PartyRemoteSurface: View {
    @ObservedObject var frames: PartyRemoteFrames
    var mirrored: Bool
    var peerName: String
    var sharing: PartyShareMode

    var body: some View {
        GeometryReader { proxy in
            let rect = LivePoseCameraSurface.imageRect(in: proxy.size, aspectRatio: frames.aspectRatio)
            ZStack {
                Color(red: 0.045, green: 0.055, blue: 0.075)
                if let image = frames.value.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                        .position(x: rect.midX, y: rect.midY)
                } else if frames.value.pose != nil {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                if let pose = frames.value.pose {
                    LivePoseCameraSkeleton(observation: pose, mirrored: mirrored, imageRect: rect)
                }
                if frames.value.image == nil && frames.value.pose == nil {
                    VStack(spacing: 9) {
                        Image(systemName: sharing == .off ? "person.crop.rectangle" : "dot.radiowaves.left.and.right")
                            .font(.system(size: 30, weight: .light))
                        Text(sharing == .off ? "\(peerName) 还没有共享" : "等待 \(peerName) 的画面…").font(.subheadline.weight(.medium))
                        Text(sharing == .off ? "对方选择共享后，这里会出现画面或骨架。" : "对方开启摄像头后就会出现。")
                            .font(.caption).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                    }
                    .padding(18).foregroundStyle(.white)
                }
                VStack {
                    HStack(spacing: 6) {
                        Circle().fill(frames.value.image != nil || frames.value.pose != nil ? Color.green : Color.gray).frame(width: 6, height: 6)
                        Text(badge).font(.system(size: 10, weight: .medium))
                        Spacer()
                        if mirrored { Text("镜像").font(.system(size: 10)) }
                    }
                    Spacer()
                }
                .padding(10).foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("\(peerName) 的实时画面；绿色表示左侧关节，紫色表示右侧关节。")
    }

    private var badge: String {
        if frames.value.image != nil { return "\(peerName) · 实时画面 \(frames.value.width)×\(frames.value.height)" }
        if frames.value.pose != nil { return "\(peerName) · 只有骨架" }
        return peerName
    }
}

struct PartyCountdownOverlay: View {
    let countdown: PartyService.Countdown

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let remaining = countdown.startsAtLocal - PartyService.now()
            let go = countdown.fired || remaining <= 0
            VStack(spacing: 6) {
                Text(go ? "GO!" : String(max(1, Int(remaining.rounded(.up)))))
                    .font(.system(size: 96, weight: .black, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(go ? "一起跳！" : caption).font(.callout.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 36).padding(.vertical, 24)
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 24))
        }
        .allowsHitTesting(false)
        .accessibilityLabel("倒数开始")
    }

    private var caption: String {
        let tempo = countdown.bpm.map { " · \(Int($0.rounded())) BPM" } ?? ""
        return "\(countdown.sourceName)\(tempo)"
    }
}
