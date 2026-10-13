import Foundation
import CryptoKit

/// Bounded local evidence, independent of the noisy raw strap-log retention. No polling, BLE writes,
/// sensor changes or per-notification disk I/O. Counts describe this app, not another connected client.
final class BatteryDiagnostics: @unchecked Sendable {
    static let shared = BatteryDiagnostics()
    static let storageKey = "diagnostics.battery.v1"
    static let retentionSeconds = 14 * 86_400
    static let maxCheckpoints = 2048

    enum Event {
        case connection(Bool)
        case association(Bool)
        case received(bytes: Int, standardHr: Bool)
        case write(command: String, realtime: Bool?)
        case syncRequest(String)
        case syncStart
        case syncEnd(reason: String, rows: Int)
        case battery(pct: Double, charging: Bool?, policy: String)
        case charging(Bool?)
        case policy(String)
    }
    struct Meter: Codable {
        var counters: [String: Int] = [:]
        var connected = false
        var requestedRealtime = false
        var requestedHeavyRealtime = false
        var syncing = false
        var accountedAt: Int
        var battery: Double?
        var charging: Bool?
        var batteryReadAt: Int?
        var lastCheckpointAt: Int?
        var policy = "not recorded"
    }
    struct Checkpoint: Codable {
        let time: Int
        let device: String
        let battery: Double?
        let charging: Bool?
        let batteryReadAt: Int?
        let policy: String
        let counters: [String: Int]
    }
    private struct State: Codable {
        var meters: [String: Meter] = [:]
        var checkpoints: [Checkpoint] = []
    }
    private let lock = NSLock()
    private let persistence = DispatchQueue(label: "noop.battery.diagnostics", qos: .utility)
    private let defaults: UserDefaults
    private var state: State
    private var tags: [String: String] = [:]

    init(defaults: UserDefaults = .standard, now: Int = Int(Date().timeIntervalSince1970)) {
        self.defaults = defaults
        state = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        // The previous process cannot tell us whether its link/stream survived termination. Do not
        // charge the unobserved gap to connected time or silently carry an armed stream into this run.
        for key in state.meters.keys {
            state.meters[key]?.connected = false
            state.meters[key]?.requestedRealtime = false
            state.meters[key]?.requestedHeavyRealtime = false
            state.meters[key]?.syncing = false
            state.meters[key]?.accountedAt = now
        }
        prune(now: now)
    }

    func note(_ event: Event, device: String, now: Int = Int(Date().timeIntervalSince1970)) {
        lock.lock()
        let tag: String
        if let cached = tags[device] { tag = cached }
        else {
            tag = SHA256.hash(data: Data(device.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            tags[device] = tag
        }
        var meter = state.meters[tag] ?? Meter(accountedAt: now)
        account(&meter, now: now)
        var checkpoint = false
        func count(_ key: String, _ amount: Int = 1) { meter.counters[key, default: 0] += max(0, amount) }
        switch event {
        case .connection(let up):
            if meter.connected != up {
                count(up ? "connects" : "disconnects")
            }
            meter.connected = up
            if !up { meter.requestedRealtime = false; meter.requestedHeavyRealtime = false; meter.syncing = false }
        case .association(let up):
            // A registry identity move is not a radio reconnect. Stop timing the old association and
            // start the new one without incrementing connection/drop counters.
            meter.connected = up
            if !up { meter.requestedRealtime = false; meter.requestedHeavyRealtime = false; meter.syncing = false }
        case .received(let bytes, let hr):
            count("rx_updates"); count("rx_bytes", bytes)
            if hr { count("standard_hr_updates") }
        case .write(let command, let realtime):
            count("submitted_writes")
            if let realtime {
                count(realtime ? "realtime_on_writes" : "realtime_off_writes")
                meter.requestedRealtime = realtime
            }
            if command == "heavy_realtime_on" || command == "heavy_realtime_off" {
                count(command + "_writes")
                meter.requestedHeavyRealtime = command == "heavy_realtime_on"
            }
            if command == "history" { count("history_request_writes") }
            if command == "history_ack" { count("history_ack_writes") }
            if command == "battery" { count("battery_poll_writes") }
        case .syncRequest(let trigger): count("sync_requested_" + trigger)
        case .syncStart: count("sync_started"); meter.syncing = true
        case .syncEnd(let reason, let rows):
            count("sync_ended"); count("sync_rows", rows); count("sync_end_" + reason)
            meter.syncing = false
        case .battery(let pct, let charging, let policy):
            guard pct.isFinite, (0...100).contains(pct) else { lock.unlock(); return }
            checkpoint = (charging != nil && meter.charging != charging) || (meter.battery.map { pct > $0 + 2 } ?? false)
            meter.battery = pct; meter.charging = charging; meter.policy = policy; meter.batteryReadAt = now
            count("battery_readings")
        case .charging(let charging):
            checkpoint = charging != nil && charging != meter.charging
            meter.charging = charging
        case .policy(let policy):
            meter.policy = policy
        }
        let lastCheckpoint = meter.lastCheckpointAt
        // Traffic counters checkpoint at most every ten minutes too, even when battery replies vanish.
        // Rapid reconnect/reconcile loops must not consume the whole two-week trace or write per frame.
        let intervalDue = lastCheckpoint.map { now - $0 >= 600 } ?? true
        if intervalDue || (checkpoint && now - (lastCheckpoint ?? 0) >= 10) {
            meter.lastCheckpointAt = now
            state.meters[tag] = meter
            state.checkpoints.append(Checkpoint(time: now, device: tag, battery: meter.battery,
                charging: meter.charging, batteryReadAt: meter.batteryReadAt, policy: meter.policy, counters: meter.counters))
            prune(now: now)
            // Capture and queue under the lock so concurrent events cannot persist out of order.
            let captured = state
            persistence.async { [defaults] in
                if let data = try? JSONEncoder().encode(captured) { defaults.set(data, forKey: Self.storageKey) }
            }
        } else { state.meters[tag] = meter }
        lock.unlock()
    }

    private func account(_ meter: inout Meter, now: Int) {
        let elapsed = max(0, now - meter.accountedAt)
        if meter.connected { meter.counters["connected_wall_seconds", default: 0] += elapsed }
        if meter.connected && meter.requestedRealtime { meter.counters["realtime_requested_wall_seconds", default: 0] += elapsed }
        if meter.connected && meter.requestedHeavyRealtime { meter.counters["heavy_requested_wall_seconds", default: 0] += elapsed }
        if meter.syncing { meter.counters["sync_wall_seconds", default: 0] += elapsed }
        meter.accountedAt = now
    }
    private func prune(now: Int) {
        state.checkpoints.removeAll { $0.time < now - Self.retentionSeconds }
        if state.checkpoints.count > Self.maxCheckpoints { state.checkpoints.removeFirst(state.checkpoints.count - Self.maxCheckpoints) }
        let retained = Set(state.checkpoints.map(\.device))
        state.meters = state.meters.filter { retained.contains($0.key) || $0.value.accountedAt >= now - Self.retentionSeconds }
    }

    /// Every export carries the trace, even with Battery test mode off. Exporting never polls a strap.
    func exportLines(now: Int = Int(Date().timeIntervalSince1970)) -> [String] {
        lock.lock()
        let checkpoints = state.checkpoints.filter { $0.time >= now - Self.retentionSeconds }
        var meters = state.meters
        lock.unlock()
        var lines = ["Battery diagnostics (local; up to 14 days / 2048 checkpoints)",
            "Times are observed wall-clock link/request intervals, not CPU time or confirmed sensor duty. Unobserved process gaps are excluded; suspension can delay observations.",
            "Counters checkpoint about every ten minutes; termination may lose activity since the last checkpoint. soc_read_t is the reading time, not the checkpoint time.",
            "Received updates include characteristic reads and notifications. Writes are submitted to CoreBluetooth, not proof of strap acceptance. Other apps/clients and battery capacity are not measured."]
        if checkpoints.isEmpty { lines.append("No checkpoints recorded yet.") }
        for key in meters.keys.sorted() {
            guard var meter = meters[key] else { continue }
            account(&meter, now: now)
            meters[key] = meter
            let counts = meter.counters.keys.sorted().map { "\($0)=\(meter.counters[$0]!)" }.joined(separator: " ")
            lines.append("battery-device=\(key) current: \(counts); policy=\(meter.policy)")
        }
        for row in checkpoints {
            let counts = row.counters.keys.sorted().map { "\($0)=\(row.counters[$0]!)" }.joined(separator: " ")
            lines.append("battery-checkpoint t=\(row.time) device=\(row.device) soc=\(row.battery.map { String(format: "%.2f", $0) } ?? "unknown") soc_read_t=\(row.batteryReadAt.map { String($0) } ?? "unknown") charging=\(row.charging.map { String($0) } ?? "unknown") \(counts); policy=\(row.policy)")
        }
        return lines
    }

    func clear() {
        lock.lock()
        state = State()
        tags = [:]
        persistence.async { [defaults] in defaults.removeObject(forKey: Self.storageKey) }
        lock.unlock()
    }
    func flushForTesting() { persistence.sync {} }
}
