//
//  USBPoller.swift
//  Concept2 SDK
//

#if os(macOS)
import Foundation

/// Reads a PM5's data over USB. The PM5 sends nothing on its own over USB, so this asks for it with CSAFE
/// frames, one at a time:
///  - a small frame (stroke state, work time) over and over, which updates the time-critical subjects as
///    fast as the PM5 answers (about 8 ms);
///  - after every few of those, one of four frames with the other status values;
///  - after each drive, the force curve.
/// Over USB only the public commands and the limited PM-specific ones in the 0x1A wrapper are allowed; the
/// others (in the 0x7E and 0x7F wrappers) need an authentication, and the PM5 shows error 128 when they are
/// sent without it. So the numbers that only those give, such as a stroke's drive length and work, are worked
/// out here from what the allowed commands return.
/// What is read is put into the bytes the PM5 sends over Bluetooth and handled like those, so the models, the
/// raw data notification and everything built on them work the same.
@available(macOS 10.15, *)
final class USBPoller {
  private enum Request {
    case fast, slow(Int), forcePlot, app, probe(Int), strokeStats
  }

  // CSAFE command identifiers. The first group is in the 0x1A wrapper, the second is public.
  private enum Command {
    static let workoutType: UInt8 = 0x89, workoutState: UInt8 = 0x8D, intervalType: UInt8 = 0x8E
    static let intervalCount: UInt8 = 0x9F, workTime: UInt8 = 0xA0, workDistance: UInt8 = 0xA3
    static let strokeState: UInt8 = 0xBF, restTime: UInt8 = 0xCF, forcePlotData: UInt8 = 0x6B

    static let calories: UInt8 = 0xA3, dragFactor: UInt8 = 0xC1, pace: UInt8 = 0xA6, cadence: UInt8 = 0xA7
    static let heartRate: UInt8 = 0xB0, power: UInt8 = 0xB4
  }

  /// The slow frames. The first two hold commands of the 0x1A wrapper, the others public ones; each fits the
  /// 20 bytes of a report in both directions.
  private static let slowFrames: [Data] = [
    CSAFEFrame.pmFrame([[Command.workoutType], [Command.workoutState], [Command.intervalType], [Command.intervalCount]]),
    CSAFEFrame.pmFrame([[Command.restTime], [Command.dragFactor]]),
    CSAFEFrame.pmFrame([[Command.workDistance]]),
    CSAFEFrame.frame([Command.cadence, Command.pace]),
    CSAFEFrame.frame([Command.power, Command.heartRate, Command.calories]),
  ]

  /// The stroke state and the work time: the time-critical values, sent over and over.
  private static let fastFrame = CSAFEFrame.pmFrame([[Command.strokeState], [Command.workTime]])

  /// A read of the force curve, whose 33 byte answer shows which report carries an answer longer than 20 bytes.
  private static let forcePlotFrame = CSAFEFrame.pmFrame([[Command.forcePlotData, 1, 32]])

  /// `CSAFE_PM_GET_STROKESTATS` in the 0x1A wrapper. The PM5 answers it without an authentication (workout_35).
  private static let strokeStatsFrame = CSAFEFrame.pmFrame([[0x6E, 1, 0]])

  private weak var monitor: PerformanceMonitor?
  private let transport: USBTransport
  private let queue: DispatchQueue
  private var running = false

  private var inFlight: Request?
  private var sentAt = Date()
  private var timeout: DispatchWorkItem?
  private var appFrames: [Data] = []

  // What the slow frames last said.
  private var workoutType = 0, intervalType = 0, workoutState = 0, intervalCount = 0
  private var dragFactor = 0
  private var strokeRate = 0, heartRate = 255, paceCentiseconds = 0, power = 0, calories = 0
  private var restTime = 0
  private var paceUnit: UInt8 = 0
  private var slowIndex = 0
  private var fastSinceSlow = 0

  // What the fast frame last said.
  private var elapsed: TimeInterval = 0
  private var distance: Double = 0
  private var strokeState: StrokeState?
  private var lastFastAt: Date?

  // Whether answers longer than 20 bytes arrive, and the report that has to carry the request for it.
  private var bigReportID: UInt8?
  private var probeResults: [Bool] = []
  private var probeStart: Date?
  private var probeNotes: [String] = []
  private var statsPending = false
  private var statsLogged = 0
  /// The PM5's own numbers of the last stroke (`GET_STROKESTATS`), when they are for the stroke counted here.
  private var pm5Stats: (driveLength: Double, driveTime: Double, recovery: Double, distance: Double)?

  // The stroke that is being worked out.
  private var driveStart: TimeInterval?
  private var driveEnd: TimeInterval?
  private var recoveryTime: TimeInterval = 0
  private var driveTime: TimeInterval = 0
  private var strokeStartDistance: Double = 0
  private var strokeDistance: Double = 0
  private var strokeCount = 0
  private var strokeEventElapsed: TimeInterval = 0
  private var plotPending = false
  private var plotRetryAt = Date.distantPast
  private var plotPoints: [Int] = []

  // Statistics, logged by `PerformanceMonitor` as `PM5.usb`.
  private var loopTimes: [TimeInterval] = []
  private var timeouts = 0
  private var statsAt = Date()
  private var rawLogged = 0
  private var unusableLogged = 0
  private var sentLogged = 0
  private var timeoutsLogged = 0
  private var decodedLogged = 0
  private var slowReceived = 0

  init(monitor: PerformanceMonitor, transport: USBTransport, queue: DispatchQueue) {
    self.monitor = monitor
    self.transport = transport
    self.queue = queue
  }

  // MARK: Start and stop
  func start() -> Bool {
    guard transport.open() else { return false }
    transport.onFrame = { [weak self] bytes, date in
      self?.queue.async { self?.received(bytes, at: date) }
    }
    queue.async { [self] in
      running = true
      pump()
    }
    return true
  }

  func stop() {
    queue.async { [self] in
      running = false
      timeout?.cancel()
      inFlight = nil
    }
    transport.close()
  }

  /// A frame from the app (a workout to set up, the clock), sent between the polling frames.
  func enqueue(_ frame: Data) {
    queue.async { [self] in
      appFrames.append(frame)
      if running { pump() }
    }
  }

  // MARK: Sending
  private func pump() {
    guard running, inFlight == nil else { return }
    let request: Request
    let frame: Data
    var reportID: UInt8?
    let now = Date()
    if !appFrames.isEmpty {
      request = .app
      frame = appFrames.removeFirst()
    } else if statsPending, let big = bigReportID {
      statsPending = false
      request = .strokeStats
      frame = Self.strokeStatsFrame
      reportID = big == 1 ? nil : big
    } else if plotPending, bigReportID != nil, now >= plotRetryAt {
      request = .forcePlot
      frame = Self.forcePlotFrame
      reportID = bigReportID == 1 ? nil : bigReportID
    } else if probeDue(now) {
      let step = probeResults.count
      request = .probe(step)
      frame = Self.forcePlotFrame
      reportID = [1, 2, 4][step]
    } else if fastSinceSlow >= 3 {
      request = .slow(slowIndex)
      frame = Self.slowFrames[slowIndex]
      fastSinceSlow = 0
    } else {
      request = .fast
      frame = Self.fastFrame
      fastSinceSlow += 1
    }
    inFlight = request
    sentAt = now
    if sentLogged < 8 {
      sentLogged += 1
      monitor?.logUSB([("event", "sent"), ("request", "\(request)"),
                       ("hex", frame.map { String(format: "%02X", $0) }.joined())])
    }
    guard transport.send(frame, reportID: reportID) else {
      monitor?.logUSB([("event", "sendFailed"), ("request", "\(request)"), ("bytes", String(frame.count))])
      inFlight = nil
      transportFailed()
      return
    }
    let item = DispatchWorkItem { [weak self] in
      guard let self, let pending = self.inFlight else { return }
      self.timeouts += 1
      if self.timeoutsLogged < 60 {
        self.timeoutsLogged += 1
        self.monitor?.logUSB([("event", "timeout"), ("request", "\(pending)")])
      }
      if case .strokeStats = pending { self.pm5Stats = nil; self.monitor?.logUSB([("event", "strokeStats"), ("parsed", "timeout")]) }
      if case .probe(let step) = pending {
        self.probeResults.append(false)
        self.probeNotes.append("\(step): timeout")
        self.monitor?.logUSB([("event", "probe"), ("step", String(step)), ("ok", "timeout")])
      }
      if case .slow = pending { self.slowIndex = (self.slowIndex + 1) % Self.slowFrames.count }
      self.inFlight = nil
      self.pump()
    }
    timeout = item
    queue.asyncAfter(deadline: .now() + 0.3, execute: item)
  }

  private func probeDue(_ now: Date) -> Bool {
    guard bigReportID == nil, probeResults.count < 3 else { return false }
    let start = probeStart ?? now
    probeStart = start
    return now.timeIntervalSince(start) >= 1
  }

  private func transportFailed() {
    running = false
    DispatchQueue.main.async { [weak monitor] in monitor?.usbTransportFailed() }
  }

  // MARK: Receiving
  private func received(_ bytes: [UInt8], at date: Date) {
    guard running else { return }
    let request = inFlight
    let response = CSAFEFrame.parse(bytes)
    logRaw(request, bytes, parsed: response)
    guard let request else { return }
    if case .strokeStats = request {
      timeout?.cancel()
      inFlight = nil
      pm5Stats = nil
      if let data = response?.commands[0x6E], data.count >= 8, Int(little(data[6..<8])) == strokeCount, data[2] > 0 {
        pm5Stats = (Double(data[5]) / 100, Double(data[2]) / 100, Double(little(data[3..<5])) / 100, Double(little(data[0..<2])) / 100)
      }
      statsLogged += 1
      guard statsLogged <= 40 else { pump(); return }
      monitor?.logUSB([("event", "strokeStats"), ("parsed", response == nil ? "no" : "yes"),
                       ("local", "count \(strokeCount) drive \(driveTime) recovery \(recoveryTime) distance \(strokeDistance)"),
                       ("status", response.map { String(format: "%02X", $0.status) } ?? ""),
                       ("commands", response?.commands.map { String(format: "%02X:", $0.key) + $0.value.map { String(format: "%02X", $0) }.joined() }.joined(separator: " ") ?? ""),
                       ("hex", bytes.map { String(format: "%02X", $0) }.joined())])
      pump()
      return
    }
    if case .probe(let step) = request {
      timeout?.cancel()
      inFlight = nil
      let ok = response?.commands[Command.forcePlotData] != nil
      probeResults.append(ok)
      probeNotes.append("\(step): \(ok ? "ok" : "no") " + bytes.prefix(48).map { String(format: "%02X", $0) }.joined())
      monitor?.logUSB([("event", "probe"), ("step", String(step)), ("ok", ok ? "yes" : "no")])
      if ok { bigReportID = [1, 2, 4][step] }
      pump()
      return
    }
    guard let response else { return }
    timeout?.cancel()
    inFlight = nil
    switch request {
    case .fast: handleFast(response.commands, at: date)
    case .slow(let index): handleSlow(index, response.commands, at: date)
    case .forcePlot: handleForcePlot(response.commands, at: date)
    case .app, .probe, .strokeStats: break
    }
    pump()
  }

  /// The first few answers go to the log as they came, to check the layout and the units against; later
  /// every 500th, and every one that isn't a usable frame.
  private func logRaw(_ request: Request?, _ bytes: [UInt8], parsed: CSAFEFrame.Response?) {
    rawLogged += 1
    let usable = parsed.map { !$0.commands.isEmpty } ?? false
    guard rawLogged <= 60 || rawLogged % 500 == 0 || (!usable && unusableLogged < 30) else { return }
    if !usable { unusableLogged += 1 }
    let hex = bytes.map { String(format: "%02X", $0) }.joined()
    monitor?.logUSB([("event", "frame"), ("request", request.map { "\($0)" } ?? "none"),
                     ("parsed", parsed == nil ? "no" : (usable ? "yes" : "statusOnly")),
                     ("sentMsAgo", String(format: "%.1f", Date().timeIntervalSince(sentAt) * 1000)), ("hex", hex)])
  }

  /// A value sent least significant byte first, as the commands of the 0x1A wrapper and the public ones do.
  private func little(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
  }

  // MARK: Fast frame
  private func handleFast(_ commands: [UInt8: [UInt8]], at date: Date) {
    if let last = lastFastAt {
      loopTimes.append(date.timeIntervalSince(last))
      logStatistics(at: date)
    }
    let gap = lastFastAt.map { date.timeIntervalSince($0) } ?? 0
    lastFastAt = date

    // The work time is a count of hundredths of a second in four bytes that only moves in whole seconds,
    // with a fifth byte of hundredths of the current second (seen in workout_29's frames).
    if let time = commands[Command.workTime], time.count >= 4 {
      let fraction = time.count > 4 ? Double(min(time[4], 99)) / 100 : 0
      elapsed = Double(little(time[0..<4])) / 100 + fraction
    }
    if let state = commands[Command.strokeState]?.first.flatMap({ StrokeState(rawValue: Int($0)) }) {
      strokeChanged(to: state, at: date, gap: gap)
    }
    monitor?.usbFastUpdate(elapsed: elapsed, distance: distance, strokeState: strokeState, at: date)
  }

  private func strokeChanged(to state: StrokeState, at date: Date, gap: TimeInterval) {
    defer { strokeState = state }
    guard let previous = strokeState, previous != state else { return }
    let time = max(0, elapsed - min(gap, 0.1) / 2)
    if state == .Driving {
      if let end = driveEnd { recoveryTime = max(0, time - end) }
      driveStart = time
      strokeStartDistance = distance
    } else if previous == .Driving {
      driveEnd = time
      driveTime = max(0, time - (driveStart ?? time))
      strokeDistance = max(0, distance - strokeStartDistance)
      strokeCount += 1
      strokeEventElapsed = time
      plotPoints = []
      if bigReportID != nil {
        statsPending = true
        plotPending = true
        plotRetryAt = .distantPast
      } else {
        deliverStroke(peak: 0, average: 0, at: date)
      }
    }
  }

  private func logStatistics(at date: Date) {
    guard date.timeIntervalSince(statsAt) >= 10, !loopTimes.isEmpty else { return }
    let sorted = loopTimes.sorted()
    func milliseconds(_ value: TimeInterval) -> String { String(format: "%.1f", value * 1000) }
    monitor?.logUSB([("event", "loop"), ("count", String(sorted.count)),
                     ("medianMs", milliseconds(sorted[sorted.count / 2])),
                     ("p90Ms", milliseconds(sorted[Int(Double(sorted.count) * 0.9)])),
                     ("maxMs", milliseconds(sorted[sorted.count - 1])), ("timeouts", String(timeouts)),
                     ("bigReport", bigReportID.map(String.init) ?? "none"),
                     ("probes", probeResults.map { $0 ? "yes" : "no" }.joined(separator: ",")),
                     ("probeNotes", probeNotes.joined(separator: " | ")), ("reports", transport.reportDescription)])
    loopTimes = []
    statsAt = date
  }

  // MARK: Slow frames
  private func handleSlow(_ index: Int, _ commands: [UInt8: [UInt8]], at date: Date) {
    slowReceived += 1
    if slowReceived % 100 < 4 {
      let fields = commands.sorted { $0.key < $1.key }.map { id, data in
        String(format: "%02X:", id) + data.map { String(format: "%02X", $0) }.joined()
      }.joined(separator: " ")
      monitor?.logUSB([("event", "slowFrame"), ("index", String(index)), ("commands", fields)])
    }
    switch index {
    case 0:
      workoutType = Int(commands[Command.workoutType]?.first ?? UInt8(clamping: workoutType))
      workoutState = Int(commands[Command.workoutState]?.first ?? UInt8(clamping: workoutState))
      intervalType = Int(commands[Command.intervalType]?.first ?? UInt8(clamping: intervalType))
      intervalCount = Int(commands[Command.intervalCount]?.first ?? UInt8(clamping: intervalCount))
    case 1:
      if let rest = commands[Command.restTime], rest.count >= 2 { restTime = Int(little(rest[0..<2])) }
      if let drag = commands[Command.dragFactor]?.first { dragFactor = Int(drag) }
    case 2:
      // The work distance is a count of tenths of a meter in four bytes that moves in whole meters, with a
      // fifth byte that is taken to be hundredths of a meter.
      if let work = commands[Command.workDistance], work.count >= 4 {
        let fraction = work.count > 4 ? Double(min(work[4], 99)) / 100 : 0
        distance = Double(little(work[0..<4])) / 10 + fraction
      }
    case 3:
      if let cadence = commands[Command.cadence], cadence.count >= 2 { strokeRate = Int(little(cadence[0..<2])) }
      if let pace = commands[Command.pace], pace.count >= 2 {
        // The pace is a count of seconds per kilometer (checked against the power and speed the PM5 showed);
        // the third byte names the unit. Per 500 m it is half, and in hundredths of a second 50 times.
        paceCentiseconds = Int(little(pace[0..<2])) * 50
        paceUnit = pace.count > 2 ? pace[2] : 0
      }
    default:
      if let stroke = commands[Command.power], stroke.count >= 2 { power = Int(little(stroke[0..<2])) }
      if let rate = commands[Command.heartRate]?.first { heartRate = rate == 0 ? 255 : Int(rate) }
      if let total = commands[Command.calories], total.count >= 2 { calories = Int(little(total[0..<2])) }
    }
    if index == 4 {
      decodedLogged += 1
    }
    if index == 4, decodedLogged <= 12 || decodedLogged % 200 == 0 {
      monitor?.logUSB([("event", "decoded"), ("frame", String(index)),
                       ("strokeRate", String(strokeRate)), ("paceRaw", String(paceCentiseconds / 50)), ("paceUnit", String(paceUnit)),
                       ("power", String(power)), ("heartRate", String(heartRate)), ("calories", String(calories)),
                       ("distance", String(format: "%.2f", distance)), ("elapsed", String(format: "%.2f", elapsed))])
    }
    slowIndex = (slowIndex + 1) % Self.slowFrames.count
    if slowIndex == 0 {
      deliver(.generalStatus, generalStatus(), at: date)
      deliver(.additionalStatus1, additionalStatus1(), at: date)
      deliver(.additionalStatus2, additionalStatus2(), at: date)
    }
  }

  // MARK: Stroke
  private func handleForcePlot(_ commands: [UInt8: [UInt8]], at date: Date) {
    guard let data = commands[Command.forcePlotData], let count = data.first else {
      plotRetryAt = date.addingTimeInterval(0.05)
      return
    }
    let read = min(Int(count), data.count - 1)
    var index = 1
    while index + 1 <= read {
      plotPoints.append(Int(data[index]) | (Int(data[index + 1]) << 8))
      index += 2
    }
    if read >= 32 { return } // more to read
    guard !plotPoints.isEmpty else {
      // The curve isn't there yet.
      plotRetryAt = date.addingTimeInterval(0.05)
      return
    }
    plotPending = false
    let points = plotPoints
    plotPoints = []
    let packets = stride(from: 0, to: points.count, by: 9).map { Array(points[$0..<min($0 + 9, points.count)]) }
    for (sequence, chunk) in packets.enumerated() {
      var packet: [UInt8] = [UInt8(min(packets.count, 15) << 4 | chunk.count), UInt8(sequence & 0xFF)]
      for point in chunk { packet += [UInt8(point & 0xFF), UInt8((point >> 8) & 0xFF)] }
      deliver(.forceCurveData, Data(packet), at: date)
    }
    let positive = points.filter { $0 > 0 }
    let average = positive.isEmpty ? 0 : positive.reduce(0, +) / positive.count
    deliverStroke(peak: points.max() ?? 0, average: average, at: date)
  }

  /// The numbers of a stroke that was worked out here, in the layout of the PM5's stroke data. The force
  /// curve's values are in pounds; the stroke data holds tenths of a pound.
  private func deliverStroke(peak: Int, average: Int, at date: Date) {
    func big(_ value: Double) -> UInt32 { UInt32(clamping: Int(max(0, min(value, 16_000_000)))) }
    var bytes = le(big(strokeEventElapsed * 100), 3) + le(big(distance * 10), 3)
    // The PM5's own drive length, drive and recovery times and stroke distance when it gave them.
    let drive = pm5Stats?.driveTime ?? driveTime, recovery = pm5Stats?.recovery ?? recoveryTime
    let length = pm5Stats?.driveLength ?? 0, distancePerStroke = pm5Stats?.distance ?? strokeDistance
    bytes += [UInt8(clamping: Int(max(0, min(length * 100, 255)))), UInt8(clamping: Int(max(0, min(drive * 100, 255))))]
    bytes += le(big(recovery * 100), 2) + le(big(distancePerStroke * 100), 2)
    bytes += le(UInt32(clamping: peak * 10), 2) + le(UInt32(clamping: average * 10), 2) + le(0, 2)
    bytes += le(UInt32(clamping: strokeCount), 2)
    deliver(.strokeData, Data(bytes), at: date)

    var extra = le(big(strokeEventElapsed * 100), 3) + le(UInt32(clamping: power), 2) + le(0, 2)
    extra += le(UInt32(clamping: strokeCount), 2) + le(0, 3) + le(0, 3)
    deliver(.additionalStrokeData, Data(extra), at: date)
  }

  // MARK: Payloads, in the layout of the PM5's Bluetooth characteristics
  private func le(_ value: UInt32, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8((value >> UInt32(8 * $0)) & 0xFF) }
  }

  private var elapsedHundredths: UInt32 { UInt32(clamping: Int(max(0, min(elapsed * 100, 16_000_000)))) }
  private var distanceTenths: UInt32 { UInt32(clamping: Int(max(0, min(distance * 10, 16_000_000)))) }

  private func generalStatus() -> Data {
    let active = strokeState.map { $0 == .Driving || $0 == .DwellingAfterDrive || $0 == .Recovery } ?? false
    var bytes = le(elapsedHundredths, 3) + le(distanceTenths, 3)
    bytes += [UInt8(clamping: workoutType), UInt8(clamping: intervalType), UInt8(clamping: workoutState),
              active ? 1 : 0, UInt8(clamping: strokeState?.rawValue ?? 0)]
    bytes += le(distanceTenths, 3) + le(0, 3)
    bytes += [0, UInt8(clamping: dragFactor)]
    return Data(bytes)
  }

  private func additionalStatus1() -> Data {
    let speed = paceCentiseconds > 0 ? UInt32(clamping: 50_000_000 / paceCentiseconds) : 0 // 0.001 m/s
    let average = distance > 0 && elapsed > 0 ? Int(min(elapsed / distance * 500 * 100, 65_535)) : 0
    var bytes = le(elapsedHundredths, 3) + le(speed, 2)
    bytes += [UInt8(clamping: strokeRate), UInt8(clamping: heartRate)]
    bytes += le(UInt32(clamping: paceCentiseconds), 2) + le(UInt32(clamping: average), 2)
    bytes += le(0, 2) + le(UInt32(clamping: restTime), 3)
    return Data(bytes)
  }

  private func additionalStatus2() -> Data {
    var bytes = le(elapsedHundredths, 3) + [UInt8(clamping: intervalCount)]
    bytes += le(UInt32(clamping: power), 2) + le(UInt32(clamping: calories), 2)
    bytes += le(0, 2) + le(0, 2) + le(0, 2)
    bytes += le(0, 3) + le(0, 3)
    return Data(bytes)
  }

  private func deliver(_ characteristic: RowingCharacteristic, _ data: Data, at date: Date) {
    monitor?.deliver(characteristic, data: data, at: date)
  }
}
#endif
