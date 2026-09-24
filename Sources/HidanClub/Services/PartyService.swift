import Combine
import CoreVideo
import CryptoKit
import Foundation
import HidanCore
import Network
import Security

/// Beat side of a party. MusicService conforms in PartyMusicBridge.swift; the
/// loopback QA probe attaches a fake so the sync logic runs without audio.
struct PartyBeatSnapshot: Equatable {
    var isPlaying: Bool
    var isPaused: Bool
    var isBeat: Bool
    var bpm: Double?
    var sourceName: String
    var isTrack: Bool
}

@MainActor protocol PartyBeatPlayer: AnyObject {
    var partyBeatSnapshot: PartyBeatSnapshot { get }
    var beatChanges: AnyPublisher<Void, Never> { get }
    func prepareSharedBeat(name: String, bpm: Double)
    func playSharedBeat()
    func pauseSharedBeat()
    func stopSharedBeat()
}

/// Latest decoded picture and same-frame joints from the friend. Only the
/// remote tile observes this; the rest of the page never redraws per frame.
@MainActor final class PartyRemoteFrames: ObservableObject {
    struct Value {
        var image: CGImage?
        var pose: LivePoseObservation?
        var width = 0
        var height = 0
        var updatedAt = 0.0
    }
    @Published private(set) var value = Value()
    var aspectRatio: CGFloat {
        guard value.width > 0, value.height > 0 else { return 16 / 9 }
        return CGFloat(value.width) / CGFloat(value.height)
    }
    fileprivate func apply(_ value: Value) { self.value = value }
    fileprivate func clearImage() { value.image = nil }
    fileprivate func reset() { value = Value() }
}

/// One friend, one direct link. The host opens a room on the local network
/// (Bonjour + peer-to-peer Wi-Fi) protected by a four-digit code that derives a
/// TLS pre-shared key; a guest joins from the nearby list or by typing
/// `address:port`. Video never leaves the two Macs and is never written to disk.
@MainActor final class PartyService: ObservableObject {
    enum Role: Equatable { case none, host, guest }
    enum Phase: Equatable {
        case idle, hosting, connecting, waitingForApproval, connected, ended(String)
        var isConnected: Bool { self == .connected }
    }
    struct PeerInfo: Equatable, Identifiable {
        let id: String
        let name: String
        let appVersion: String
        let protocolVersion: Int
    }
    struct NearbyRoom: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        let protocolVersion: Int?
        var compatible: Bool { protocolVersion == nil || protocolVersion == PartyProtocol.version }
    }
    struct Statistics: Equatable {
        var roundTripMilliseconds: Double?
        var clockOffsetMilliseconds: Double?
        var sentFramesPerSecond = 0.0
        var sentKilobitsPerSecond = 0.0
        var receivedFramesPerSecond = 0.0
        var receivedKilobitsPerSecond = 0.0
        var droppedForBackpressure = 0
        var outputWidth = 0
        var outputHeight = 0
    }
    struct Countdown: Equatable {
        let startsAtLocal: Double
        let bpm: Double?
        let sourceName: String
        var fired = false
    }
    enum VideoQuality: String, CaseIterable, Identifiable {
        case smooth, clear
        var id: String { rawValue }
        var title: String { self == .smooth ? "流畅 · 640 宽" : "清晰 · 960 宽" }
        var maxWidth: Int { self == .smooth ? 640 : 960 }
        var bitrate: Int { self == .smooth ? 1_000_000 : 2_400_000 }
        var encoderConfiguration: PartyVideoEncoder.Configuration { .init(maxWidth: maxWidth, bitrate: bitrate) }
    }

    @Published private(set) var role: Role = .none
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var port: UInt16?
    @Published private(set) var roomCode = ""
    @Published private(set) var localAddresses: [String] = []
    @Published private(set) var nearby: [NearbyRoom] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var peer: PeerInfo?
    @Published private(set) var pendingRequest: PeerInfo?
    @Published private(set) var remoteSharing: PartyShareMode = .off
    @Published private(set) var hostBeat: PartyBeatState?
    @Published private(set) var countdown: Countdown?
    /// Guest: local clock at which the beat joins the host's next eight-count, while waiting for it.
    @Published private(set) var nextBarStartLocal: Double?
    @Published private(set) var statistics = Statistics()
    @Published var errorMessage: String?
    @Published var displayName: String {
        didSet {
            let trimmed = String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            if trimmed != displayName { displayName = trimmed; return }
            defaults.set(displayName, forKey: Self.nameKey)
        }
    }
    /// What this Mac sends while connected. Off by default; the camera is a separate explicit action.
    @Published var shareMode: PartyShareMode = .off { didSet { if shareMode != oldValue { applySharing() } } }
    @Published var quality: VideoQuality {
        didSet {
            defaults.set(quality.rawValue, forKey: Self.qualityKey)
            sender.update(quality: quality)
        }
    }
    /// Guest: adopt the host's tempo, start and stop.
    @Published var followHostBeat = true
    let remoteFrames = PartyRemoteFrames()
    let peerID: String
    let appVersion: String

    var isConnected: Bool { phase.isConnected }
    var isHosting: Bool { role == .host && listener != nil }
    var sharingStatus: String? { sender.lastFailure }

    private static let nameKey = "party.displayName"
    private static let peerIDKey = "party.peerID"
    private static let qualityKey = "party.quality"
    private static let helloTimeout = 12.0
    private static let linkTimeout = 8.0

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "club.hidan.party.network", qos: .userInitiated)
    private let frameTap: LivePoseFrameTap?
    private let sender: PartySender
    private let receiver: PartyRemoteReceiver
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var link: PartyLink?
    private var rejecting: [PartyLink] = []
    private var clock = PartyClockSync()
    private var pingCounter: UInt32 = 0
    private var lastReceivedAt = 0.0
    private var pingTimer: DispatchSourceTimer?
    private var housekeepingTimer: DispatchSourceTimer?
    private var beatPlayer: (any PartyBeatPlayer)?
    private var beatSubscription: AnyCancellable?
    private var lastBeatSnapshot: PartyBeatSnapshot?
    private var lastBroadcastBeat: PartyBeatState?
    private var barAnchor: Double?
    private var scheduledPlay: DispatchWorkItem?

    nonisolated static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    init(frameTap: LivePoseFrameTap?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.frameTap = frameTap
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        if let saved = defaults.string(forKey: Self.peerIDKey) { peerID = saved } else {
            peerID = UUID().uuidString; defaults.set(peerID, forKey: Self.peerIDKey)
        }
        let savedName = defaults.string(forKey: Self.nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = (savedName?.isEmpty == false ? savedName : nil) ?? String((Host.current().localizedName ?? "Hidan 舞者").prefix(24))
        let savedQuality = defaults.string(forKey: Self.qualityKey).flatMap(VideoQuality.init(rawValue:)) ?? .smooth
        quality = savedQuality
        receiver = PartyRemoteReceiver(frames: remoteFrames)
        sender = PartySender(quality: savedQuality)
    }

    // MARK: Beat player

    func attachBeatPlayer(_ player: any PartyBeatPlayer) {
        beatPlayer = player
        lastBeatSnapshot = player.partyBeatSnapshot
        beatSubscription = player.beatChanges
            .debounce(for: .milliseconds(40), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.beatPlayerDidChange() }
    }

    // MARK: Hosting

    func startHosting(advertise: Bool = true) {
        guard role == .none else { return }
        errorMessage = nil
        stopBrowsing()
        let code = PartyRoomCode.generate()
        do {
            let listener = try NWListener(using: Self.parameters(code: code))
            if advertise {
                listener.service = NWListener.Service(name: displayName, type: PartyProtocol.serviceType,
                                                      txtRecord: NWTXTRecord([PartyProtocol.versionTXTKey: String(PartyProtocol.version)]))
            }
            listener.stateUpdateHandler = { [weak self] state in
                Self.onMain { guard let self, self.listener === listener else { return }; self.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Self.onMain { guard let self, self.listener === listener else { connection.cancel(); return }; self.accept(connection) }
            }
            self.listener = listener
            roomCode = code
            role = .host
            phase = .hosting
            localAddresses = LocalNetworkAddresses.ipv4()
            listener.start(queue: queue)
        } catch {
            errorMessage = "无法开启房间：\(error.localizedDescription)"
        }
    }

    func stopHosting() {
        guard role == .host else { return }
        leave()
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            localAddresses = LocalNetworkAddresses.ipv4()
        case .failed(let error):
            errorMessage = "房间已关闭：\(error.localizedDescription)"
            leave()
        case .waiting(let error):
            errorMessage = "等待网络：\(error.localizedDescription)"
        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let incoming = PartyLink(connection: connection, queue: queue)
        guard link == nil, phase == .hosting else {
            // Someone else is already in the room, or a request is being decided.
            rejecting.append(incoming)
            incoming.onEvent = { [weak self, weak incoming] event in
                guard let incoming else { return }
                switch event {
                case .ready:
                    incoming.send(.rejected(PartyRejection(reason: "房间已经有人了")))
                    incoming.cancel(after: 0.5)
                case .closed, .failed, .protocolError:
                    Self.onMain { self?.rejecting.removeAll { $0 === incoming || $0.isCancelled } }
                case .message, .video:
                    break
                }
            }
            incoming.start()
            return
        }
        install(incoming)
        lastReceivedAt = Self.now()
        startHousekeeping()
    }

    func approvePendingRequest() {
        guard role == .host, let request = pendingRequest, let link else { return }
        pendingRequest = nil
        peer = request
        link.send(.welcome(PartyWelcome(peerID: peerID, name: displayName, appVersion: appVersion)))
        beginSession()
    }

    func declinePendingRequest() {
        guard role == .host, pendingRequest != nil, let link else { return }
        pendingRequest = nil
        link.send(.rejected(PartyRejection(reason: "对方没有接受这次加入")))
        link.cancel(after: 0.5)
        self.link = nil
    }

    // MARK: Browsing and joining

    func startBrowsing() {
        guard browser == nil, role != .host else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: PartyProtocol.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Self.onMain {
                guard let self, self.browser === browser else { return }
                switch state {
                case .ready: self.isBrowsing = true
                case .failed(let error):
                    self.errorMessage = "无法搜索附近的房间：\(error.localizedDescription)"
                    self.stopBrowsing()
                case .waiting(let error):
                    self.errorMessage = "搜索附近房间需要本地网络权限：\(error.localizedDescription)"
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let rooms = results.compactMap(NearbyRoom.init(result:)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Self.onMain { guard let self, self.browser === browser else { return }; self.nearby = rooms }
        }
        self.browser = browser
        isBrowsing = true
        browser.start(queue: queue)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        nearby = []
    }

    func join(room: NearbyRoom, code: String) {
        join(endpoint: room.endpoint, code: code, label: room.name)
    }

    func join(addressText: String, code: String) {
        guard let address = PartyAddress.parse(addressText) else {
            errorMessage = "地址格式应为「IP:端口」，例如 192.168.1.8:52000"; return
        }
        guard let port = NWEndpoint.Port(rawValue: address.port) else { errorMessage = "端口无效"; return }
        join(endpoint: .hostPort(host: NWEndpoint.Host(address.host), port: port), code: code, label: address.description)
    }

    private func join(endpoint: NWEndpoint, code rawCode: String, label: String) {
        guard role == .none else { return }
        guard let code = PartyRoomCode.normalize(rawCode) else { errorMessage = "请输入对方屏幕上的 4 位房间码"; return }
        errorMessage = nil
        stopBrowsing()
        let connection = NWConnection(to: endpoint, using: Self.parameters(code: code))
        let outgoing = PartyLink(connection: connection, queue: queue)
        role = .guest
        phase = .connecting
        install(outgoing)
        lastReceivedAt = Self.now()
        startHousekeeping()
    }

    // MARK: Session

    private func install(_ link: PartyLink) {
        self.link = link
        link.onEvent = { [weak self, weak link] event in
            guard let link else { return }
            switch event {
            case .video(let packet):
                self?.receiver.receiveVideo(packet)
            case .message(.pose(let pose)):
                self?.receiver.receivePose(pose)
            default:
                Self.onMain { guard let self, self.link === link else { return }; self.handle(event) }
            }
        }
        link.start()
    }

    private func handle(_ event: PartyLink.Event) {
        if case .message = event { lastReceivedAt = Self.now() }
        switch event {
        case .ready:
            if role == .guest {
                link?.send(.hello(PartyHello(peerID: peerID, name: displayName, appVersion: appVersion)))
                phase = .waitingForApproval
            }
        case .failed(let message):
            let reason: String
            if role == .guest, phase == .connecting || phase == .waitingForApproval {
                reason = "连不上这个房间：请确认房间码，并且两台 Mac 在同一网络。（\(message)）"
            } else { reason = "连接中断：\(message)" }
            endSession(reason: reason)
        case .closed:
            endSession(reason: peer.map { "\($0.name) 已离开" } ?? "对方关闭了连接")
        case .protocolError(let message):
            endSession(reason: "收到无法识别的数据，已断开（\(message)）")
        case .message(let message):
            handle(message)
        case .video:
            break
        }
    }

    private func handle(_ message: PartyMessage) {
        switch message {
        case .hello(let hello):
            guard role == .host, phase == .hosting, let link else { return }
            guard hello.protocolVersion == PartyProtocol.version else {
                link.send(.rejected(PartyRejection(reason: "版本不兼容，请两边都更新 Hidan Club")))
                link.cancel(after: 0.5); self.link = nil
                return
            }
            pendingRequest = PeerInfo(id: hello.peerID, name: hello.name.isEmpty ? "好友" : hello.name,
                                      appVersion: hello.appVersion, protocolVersion: hello.protocolVersion)
        case .welcome(let welcome):
            guard role == .guest, phase == .waitingForApproval else { return }
            peer = PeerInfo(id: welcome.peerID, name: welcome.name.isEmpty ? "好友" : welcome.name,
                            appVersion: welcome.appVersion, protocolVersion: welcome.protocolVersion)
            beginSession()
        case .rejected(let rejection):
            endSession(reason: rejection.reason)
        case .ping(let ping):
            let now = Self.now()
            link?.send(.pong(PartyPong(id: ping.id, sentAt: ping.sentAt, receivedAt: now, repliedAt: now)))
        case .pong(let pong):
            clock.record(sentAt: pong.sentAt, remoteReceivedAt: pong.receivedAt, remoteRepliedAt: pong.repliedAt, receivedAt: Self.now())
            statistics.roundTripMilliseconds = clock.roundTrip.map { $0 * 1000 }
            statistics.clockOffsetMilliseconds = clock.offset.map { $0 * 1000 }
        case .sharing(let sharing):
            remoteSharing = sharing.mode
            receiver.remoteModeChanged(sharing.mode)
        case .beat(let state):
            guard role == .guest else { return }
            hostBeat = state
            applyHostBeat(state)
        case .countdown(let countdown):
            guard role == .guest else { return }
            applyCountdown(countdown)
        case .stop:
            guard role == .guest else { return }
            cancelScheduledPlay()
            countdown = nil
            if followHostBeat { beatPlayer?.pauseSharedBeat() }
        case .bye(let farewell):
            endSession(reason: farewell.reason ?? peer.map { "\($0.name) 已离开" } ?? "对方已离开")
        case .pose:
            break
        }
    }

    private func beginSession() {
        phase = .connected
        errorMessage = nil
        clock.reset()
        statistics = Statistics()
        receiver.reset()
        lastReceivedAt = Self.now()
        _ = sender.takeTraffic(); _ = receiver.takeTraffic()
        startPinging()
        applySharing()
        if role == .host, let player = beatPlayer {
            lastBroadcastBeat = nil
            broadcastBeat(player.partyBeatSnapshot)
        }
    }

    private func endSession(reason: String) {
        cancelScheduledPlay()
        countdown = nil
        let hadPeer = peer != nil || phase == .waitingForApproval || phase == .connecting
        link?.cancel()
        link = nil
        peer = nil
        pendingRequest = nil
        remoteSharing = .off
        hostBeat = nil
        stopPinging()
        sender.detach()
        frameTap?.install(nil)
        receiver.reset()
        statistics = Statistics()
        switch role {
        case .host:
            // Keep the room open so the friend can come back.
            phase = .hosting
            if hadPeer { errorMessage = reason }
        case .guest:
            role = .none
            phase = .ended(reason)
            stopHousekeeping()
        case .none:
            phase = .idle
            stopHousekeeping()
        }
    }

    /// Ends the session and, for a host, closes the room.
    func leave() {
        cancelScheduledPlay()
        countdown = nil
        if let link, phase == .connected || phase == .waitingForApproval {
            link.send(.bye(PartyFarewell(reason: nil)))
            link.cancel(after: 0.3)
        } else {
            link?.cancel()
        }
        link = nil
        rejecting.forEach { $0.cancel() }
        rejecting.removeAll()
        listener?.cancel()
        listener = nil
        port = nil
        roomCode = ""
        peer = nil
        pendingRequest = nil
        remoteSharing = .off
        hostBeat = nil
        stopPinging()
        stopHousekeeping()
        sender.detach()
        frameTap?.install(nil)
        receiver.reset()
        statistics = Statistics()
        role = .none
        phase = .idle
    }

    func dismissEnded() {
        if case .ended = phase { phase = .idle }
    }

    // MARK: Sharing

    private func applySharing() {
        guard phase == .connected, let link else {
            sender.detach(); frameTap?.install(nil); return
        }
        sender.attach(link: link, mode: shareMode)
        if shareMode.sendsPose, let frameTap {
            let sender = self.sender
            frameTap.install { buffer, observation in sender.handle(buffer, observation) }
        } else {
            frameTap?.install(nil)
        }
        let size = sender.outputSize
        link.send(.sharing(PartySharing(mode: shareMode, width: Int(size.width), height: Int(size.height))))
    }

    // MARK: Beat sync

    private func beatPlayerDidChange() {
        guard let player = beatPlayer else { return }
        let snapshot = player.partyBeatSnapshot
        defer { lastBeatSnapshot = snapshot }
        if snapshot.isPlaying, lastBeatSnapshot?.isPlaying != true, barAnchor == nil {
            // A fresh start begins on the downbeat; resuming from pause keeps an unknown phase.
            barAnchor = lastBeatSnapshot?.isPaused == true ? nil : Self.now()
        } else if snapshot.isPlaying, let last = lastBeatSnapshot, last.isPlaying,
                  last.bpm != snapshot.bpm || last.sourceName != snapshot.sourceName || last.isBeat != snapshot.isBeat {
            // The built-in beat restarts its loop on a tempo or preset change.
            barAnchor = Self.now()
        }
        if !snapshot.isPlaying { barAnchor = nil }
        guard role == .host, phase == .connected else { return }
        broadcastBeat(snapshot)
    }

    private func broadcastBeat(_ snapshot: PartyBeatSnapshot) {
        let state = PartyBeatState(bpm: snapshot.bpm, playing: snapshot.isPlaying, sourceName: snapshot.sourceName,
                                   isTrack: snapshot.isTrack, barAnchor: snapshot.isPlaying ? barAnchor : nil)
        guard state != lastBroadcastBeat else { return }
        lastBroadcastBeat = state
        link?.send(.beat(state))
    }

    /// Host: everyone starts on the same instant after a short countdown.
    func startTogether(lead: Double = 3) {
        guard role == .host, phase == .connected, let player = beatPlayer else { return }
        cancelScheduledPlay()
        player.stopSharedBeat()
        beatPlayerDidChange()
        let snapshot = player.partyBeatSnapshot
        let startsAt = Self.now() + max(1, lead)
        link?.send(.countdown(PartyCountdown(startsAt: startsAt, bpm: snapshot.bpm, sourceName: snapshot.sourceName)))
        schedulePlay(atLocal: startsAt, countdown: Countdown(startsAtLocal: startsAt, bpm: snapshot.bpm, sourceName: snapshot.sourceName), startsBeat: true)
    }

    func stopTogether() {
        guard role == .host, phase == .connected else { return }
        cancelScheduledPlay()
        countdown = nil
        beatPlayer?.stopSharedBeat()
        link?.send(.stop)
    }

    private func applyHostBeat(_ state: PartyBeatState) {
        guard followHostBeat, let player = beatPlayer else { return }
        // A countdown already in flight wins; the host's own start follows it.
        if scheduledPlay != nil, countdown != nil { return }
        let local = player.partyBeatSnapshot
        guard state.playing else {
            cancelScheduledPlay()
            if local.isPlaying { player.pauseSharedBeat() }
            return
        }
        if let bpm = state.bpm {
            let sameTempo = local.isBeat && abs((local.bpm ?? 0) - bpm) <= 0.5
            if sameTempo, local.isPlaying || scheduledPlay != nil { return }
            cancelScheduledPlay()
            player.prepareSharedBeat(name: followName(state.sourceName, isTrack: state.isTrack), bpm: bpm)
            if let anchor = state.barAnchor, let localAnchor = clock.localTime(forRemote: anchor),
               let start = PartyBeatGrid.nextBarStart(after: Self.now(), anchor: localAnchor, bpm: bpm, minimumLead: 0.15) {
                schedulePlay(atLocal: start, countdown: nil, startsBeat: true)
            } else {
                barAnchor = Self.now()
                player.playSharedBeat()
            }
        } else if !local.isPlaying, scheduledPlay == nil {
            player.playSharedBeat()
        }
    }

    private func applyCountdown(_ countdown: PartyCountdown) {
        let startsAt = clock.localTime(forRemote: countdown.startsAt) ?? (Self.now() + 3)
        if followHostBeat, let player = beatPlayer {
            if let bpm = countdown.bpm {
                player.prepareSharedBeat(name: followName(countdown.sourceName, isTrack: hostBeat?.isTrack ?? false), bpm: bpm)
            } else {
                player.stopSharedBeat()
            }
        }
        schedulePlay(atLocal: startsAt, countdown: Countdown(startsAtLocal: startsAt, bpm: countdown.bpm, sourceName: countdown.sourceName),
                     startsBeat: followHostBeat)
    }

    private func followName(_ source: String, isTrack: Bool) -> String {
        let name = peer?.name ?? "好友"
        return isTrack ? "跟随 \(name) · \(source)" : "跟随 \(name)"
    }

    private func schedulePlay(atLocal start: Double, countdown: Countdown?, startsBeat: Bool) {
        cancelScheduledPlay()
        self.countdown = countdown
        nextBarStartLocal = countdown == nil ? start : nil
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduledPlay = nil
                self.nextBarStartLocal = nil
                if startsBeat {
                    self.barAnchor = start
                    self.beatPlayer?.playSharedBeat()
                }
                if var fired = self.countdown { fired.fired = true; self.countdown = fired }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    MainActor.assumeIsolated { if self?.countdown?.fired == true { self?.countdown = nil } }
                }
            }
        }
        scheduledPlay = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, start - Self.now()), execute: item)
    }

    private func cancelScheduledPlay() {
        scheduledPlay?.cancel()
        scheduledPlay = nil
        nextBarStartLocal = nil
        if countdown?.fired == false { countdown = nil }
    }

    // MARK: Timers

    private func startPinging() {
        stopPinging()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .connected, let link = self.link else { return }
                self.pingCounter &+= 1
                link.send(.ping(PartyPing(id: self.pingCounter, sentAt: Self.now())))
                self.updateStatistics()
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPinging() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func startHousekeeping() {
        guard housekeepingTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.housekeeping() }
        }
        timer.resume()
        housekeepingTimer = timer
    }

    private func stopHousekeeping() {
        housekeepingTimer?.cancel()
        housekeepingTimer = nil
    }

    private func housekeeping() {
        rejecting.removeAll(where: \.isCancelled)
        guard link != nil else { return }
        let silence = Self.now() - lastReceivedAt
        switch phase {
        case .connected:
            if silence > Self.linkTimeout { endSession(reason: "连接超时，对方可能已离开网络") }
        case .hosting:
            if pendingRequest == nil, silence > Self.helloTimeout { link?.cancel(); link = nil }
        case .connecting, .waitingForApproval:
            // Nothing flows until the host decides; give them a minute.
            if silence > 60 { endSession(reason: "对方没有响应") }
        case .idle, .ended:
            break
        }
    }

    private func updateStatistics() {
        let sent = sender.takeTraffic()
        let received = receiver.takeTraffic()
        var stats = statistics
        stats.sentFramesPerSecond = Double(sent.frames)
        stats.sentKilobitsPerSecond = Double(sent.bytes) * 8 / 1000
        stats.receivedFramesPerSecond = Double(received.frames)
        stats.receivedKilobitsPerSecond = Double(received.bytes) * 8 / 1000
        stats.droppedForBackpressure = sent.dropped
        let size = sender.outputSize
        stats.outputWidth = Int(size.width); stats.outputHeight = Int(size.height)
        statistics = stats
    }

    // MARK: Parameters

    /// TLS 1.2 with a pre-shared key derived from the room code: only someone who
    /// can read the host's screen can connect, and the link is encrypted.
    nonisolated static func parameters(code: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.connectionTimeout = 10
        let tls = NWProtocolTLS.Options()
        let digest = SHA256.hash(data: Data("club.hidan.party.v1:\(code)".utf8))
        let key = digest.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("hidanclub-party".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key as __DispatchData, identity as __DispatchData)
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }

    nonisolated private static func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
}

extension PartyService.NearbyRoom {
    init?(result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var version: Int?
        if case .bonjour(let record) = result.metadata, let value = record[PartyProtocol.versionTXTKey] { version = Int(value) }
        self.init(id: result.endpoint.debugDescription, name: name, endpoint: result.endpoint, protocolVersion: version)
    }
}

// MARK: - Link

/// One NWConnection with length-prefixed framing. Callbacks arrive on `queue`.
final class PartyLink: @unchecked Sendable {
    enum Event {
        case ready
        case failed(String)
        case closed
        case protocolError(String)
        case message(PartyMessage)
        case video(PartyVideoPacket)
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var decoder = PartyFrameDecoder()
    private var cancelled = false
    private var inflightVideo = 0
    var onEvent: ((Event) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    /// Encoded video bytes accepted by `send` and not yet handed to the transport.
    var inflightVideoBytes: Int { lock.lock(); defer { lock.unlock() }; return inflightVideo }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.isCancelled else { return }
            switch state {
            case .ready: self.onEvent?(.ready)
            case .failed(let error): self.onEvent?(.failed(Self.describe(error)))
            case .waiting(let error):
                // A wrong room code surfaces here as a TLS handshake failure; report it instead of waiting forever.
                if case .tls = error { self.onEvent?(.failed(Self.describe(error))) }
            case .cancelled: self.onEvent?(.closed)
            case .setup, .preparing: break
            @unknown default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ message: PartyMessage) {
        guard let frame = try? message.frame() else { return }
        send(frame, isVideo: false)
    }

    func send(_ packet: PartyVideoPacket) {
        send(packet.frame(), isVideo: true)
    }

    private func send(_ frame: PartyFrame, isVideo: Bool) {
        let data = frame.encoded()
        if isVideo { adjustInflight(data.count) }
        queue.async { [self] in
            guard !isCancelled else { if isVideo { adjustInflight(-data.count) }; return }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if isVideo { self.adjustInflight(-data.count) }
                if let error, !self.isCancelled {
                    self.markCancelled()
                    self.onEvent?(.failed(Self.describe(error)))
                    self.connection.cancel()
                }
            })
        }
    }

    func cancel() {
        guard !isCancelled else { return }
        markCancelled()
        connection.cancel()
    }

    /// Lets a final message (rejection, goodbye) leave before the socket closes.
    func cancel(after delay: Double) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in cancel() }
    }

    private func markCancelled() { lock.lock(); cancelled = true; lock.unlock() }
    private func adjustInflight(_ delta: Int) { lock.lock(); inflightVideo = max(0, inflightVideo + delta); lock.unlock() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.isCancelled else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.append(data) { self.dispatch(frame) }
                } catch {
                    self.markCancelled()
                    self.onEvent?(.protocolError("\(error)"))
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.markCancelled()
                self.onEvent?(.failed(Self.describe(error)))
                self.connection.cancel()
                return
            }
            if isComplete {
                self.markCancelled()
                self.onEvent?(.closed)
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func dispatch(_ frame: PartyFrame) {
        switch frame.kind {
        case .control:
            do { onEvent?(.message(try PartyMessage(jsonData: frame.payload))) }
            catch PartyMessageError.unknownType { /* newer peer; ignore what we do not know */ }
            catch {
                markCancelled()
                onEvent?(.protocolError("\(error)"))
                connection.cancel()
            }
        case .video:
            do { onEvent?(.video(try PartyVideoPacket(decoding: frame.payload))) }
            catch {
                markCancelled()
                onEvent?(.protocolError("\(error)"))
                connection.cancel()
            }
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return String(cString: strerror(code.rawValue))
        case .dns(let code): return "DNS \(code)"
        case .tls(let status): return "TLS \(status)"
        default: return error.localizedDescription
        }
    }
}

// MARK: - Sender

/// Capture-queue side of sharing: rate cap, back-pressure at the encoder input,
/// same-frame joints sent before the picture they belong to.
final class PartySender: @unchecked Sendable {
    private let lock = NSLock()
    private var link: PartyLink?
    private var mode: PartyShareMode = .off
    private var encoder: PartyVideoEncoder?
    private var quality: PartyService.VideoQuality
    private var lastFrameAt = -1.0
    private var frames = 0
    private var bytes = 0
    private var dropped = 0
    private static let minimumInterval = 1.0 / 30

    /// Encoded bytes allowed to wait for the transport before camera frames are
    /// skipped at the encoder input: about 0.6 s of video at the chosen bitrate.
    static func inflightBudget(for quality: PartyService.VideoQuality) -> Int { max(64_000, quality.bitrate / 8 * 6 / 10) }

    init(quality: PartyService.VideoQuality) { self.quality = quality }

    var lastFailure: String? { lock.lock(); defer { lock.unlock() }; return encoder?.lastFailure }
    var outputSize: CGSize { lock.lock(); defer { lock.unlock() }; return encoder?.outputSize ?? .zero }

    func attach(link: PartyLink, mode: PartyShareMode) {
        lock.lock(); defer { lock.unlock() }
        self.link = link
        self.mode = mode
        if mode.sendsVideo {
            if encoder == nil {
                encoder = PartyVideoEncoder(configuration: quality.encoderConfiguration) { [weak self] packet in self?.deliver(packet) }
            } else {
                encoder?.requestKeyframe()
            }
        } else {
            encoder?.invalidate(); encoder = nil
        }
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        link = nil; mode = .off
        encoder?.invalidate(); encoder = nil
        lastFrameAt = -1
    }

    func update(quality: PartyService.VideoQuality) {
        lock.lock(); defer { lock.unlock() }
        self.quality = quality
        encoder?.update(configuration: quality.encoderConfiguration)
    }

    func handle(_ buffer: CVPixelBuffer, _ observation: LivePoseObservation) {
        lock.lock()
        guard let link, mode.sendsPose else { lock.unlock(); return }
        let now = PartyService.now()
        guard now - lastFrameAt >= Self.minimumInterval else { lock.unlock(); return }
        lastFrameAt = now
        let encoder = mode.sendsVideo ? self.encoder : nil
        let budget = Self.inflightBudget(for: quality)
        lock.unlock()
        link.send(.pose(PartyPose(observation: observation)))
        guard let encoder else { return }
        // Skipping a camera frame before encoding keeps the H.264 reference chain
        // intact; the receiver simply sees a lower frame rate while the link is slow.
        if link.inflightVideoBytes > budget {
            lock.lock(); dropped += 1; lock.unlock()
            return
        }
        encoder.encode(buffer, timestamp: observation.timestamp)
    }

    private func deliver(_ packet: PartyVideoPacket) {
        lock.lock()
        let link = self.link
        frames += 1; bytes += packet.data.count
        lock.unlock()
        link?.send(packet)
    }

    func takeTraffic() -> (frames: Int, bytes: Int, dropped: Int) {
        lock.lock(); defer { lock.unlock() }
        defer { frames = 0; bytes = 0 }
        return (frames, bytes, dropped)
    }
}

// MARK: - Receiver

/// Network-queue side: decodes in order, pairs each picture with the joints
/// sent for the same camera frame, and publishes latest-only to the main actor.
final class PartyRemoteReceiver: @unchecked Sendable {
    private let frames: PartyRemoteFrames
    private let decoder = PartyVideoDecoder()
    private let lock = NSLock()
    private var recentPoses: [(timestamp: Double, pose: LivePoseObservation)] = []
    private var lastVideoAt = -1.0
    private var pending: PartyRemoteFrames.Value?
    private var scheduled = false
    private var current = PartyRemoteFrames.Value()
    private var receivedFrames = 0
    private var receivedBytes = 0

    init(frames: PartyRemoteFrames) { self.frames = frames }

    var lastFailure: String? { decoder.lastFailure }

    func remoteModeChanged(_ mode: PartyShareMode) {
        lock.lock()
        if !mode.sendsVideo { current.image = nil; lastVideoAt = -1 }
        if !mode.sendsPose { current.pose = nil }
        let value = current
        lock.unlock()
        publish(value)
    }

    func receivePose(_ pose: PartyPose) {
        let observation = pose.observation
        lock.lock()
        recentPoses.append((pose.timestamp, observation))
        if recentPoses.count > 90 { recentPoses.removeFirst(recentPoses.count - 90) }
        let videoActive = lastVideoAt >= 0 && PartyService.now() - lastVideoAt < 1.0
        if !videoActive {
            current.pose = observation
            if current.image == nil { current.width = pose.width; current.height = pose.height }
            current.updatedAt = PartyService.now()
        }
        let value = current
        lock.unlock()
        if !videoActive { publish(value) }
    }

    /// Runs on the network queue; decode order is arrival order.
    func receiveVideo(_ packet: PartyVideoPacket) {
        lock.lock(); receivedBytes += packet.data.count; lock.unlock()
        guard let image = decoder.decode(packet) else { return }
        lock.lock()
        receivedFrames += 1
        lastVideoAt = PartyService.now()
        let pose = recentPoses.min { abs($0.timestamp - packet.timestamp) < abs($1.timestamp - packet.timestamp) }
        let paired = pose.map { abs($0.timestamp - packet.timestamp) < 0.005 ? $0.pose : nil } ?? nil
        current.image = image
        current.pose = paired ?? current.pose
        current.width = packet.width; current.height = packet.height
        current.updatedAt = lastVideoAt
        let value = current
        lock.unlock()
        publish(value)
    }

    func reset() {
        lock.lock()
        recentPoses.removeAll(); lastVideoAt = -1; current = PartyRemoteFrames.Value(); pending = nil
        receivedFrames = 0; receivedBytes = 0
        lock.unlock()
        decoder.reset()
        DispatchQueue.main.async { [frames] in MainActor.assumeIsolated { frames.reset() } }
    }

    func takeTraffic() -> (frames: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        defer { receivedFrames = 0; receivedBytes = 0 }
        return (receivedFrames, receivedBytes)
    }

    private func publish(_ value: PartyRemoteFrames.Value) {
        lock.lock()
        pending = value
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            let next = pending; pending = nil; scheduled = false
            lock.unlock()
            guard let next else { return }
            MainActor.assumeIsolated { frames.apply(next) }
        }
    }
}

// MARK: - Local addresses

enum LocalNetworkAddresses {
    /// Non-loopback IPv4 addresses with their interface, for joining by hand.
    static func ipv4() -> [String] {
        var results: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_RUNNING != 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let text = String(cString: host)
            if text.hasPrefix("169.254.") { continue }
            results.append("\(text) (\(name))")
        }
        return results
    }
}
