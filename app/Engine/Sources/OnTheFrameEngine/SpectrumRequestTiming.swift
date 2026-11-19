#if DEBUG
import Dispatch
import Foundation
import os

/// One admitted playback request. The record travels with its work across queues.
/// Cells are assigned once for milestones and summed for repeated raster phases.
public final class SpectrumRequestTiming: Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        case coordinatorEnqueued, coordinatorStarted, analysisSubmitted, analysisReady, analysisCallbackStarted
        case rasterStarted, rasterFinished, coordinatorCancelled, coordinatorFinished
        case deliveryInvoked, sessionReceived, controllerCallback, slotReleased, cancellationRequested
        case baseGeometry, baseColor, coverageMask, distanceForward, distanceReverse, attenuation, tightCrop, ownedImage
    }

    public struct Row: Encodable, Sendable {
        public let id: Int64
        public let frame, priority, serial, epoch, revision: Int
        public fileprivate(set) var values: [UInt64?]
        public fileprivate(set) var coordinatorOutcome: Int64?
        public fileprivate(set) var controllerOutcome: Int64?
        public subscript(stage: Stage) -> UInt64? { values[stage.rawValue] }

        fileprivate var finished: Bool {
            self[.coordinatorEnqueued] != nil && self[.coordinatorStarted] != nil &&
            coordinatorOutcome != nil && self[.deliveryInvoked] != nil && self[.sessionReceived] != nil &&
            controllerOutcome != nil && self[.slotReleased] != nil &&
            (coordinatorOutcome != SpectrumFrameOutcome.cancelled.playbackTraceCode || self[.coordinatorCancelled] != nil) &&
            (self[.analysisSubmitted] == nil || (self[.analysisReady] != nil && self[.analysisCallbackStarted] != nil)) &&
            (self[.rasterStarted] == nil || self[.rasterFinished] != nil)
        }
    }

    public let id: Int64
    private let storage: OSAllocatedUnfairLock<Row>

    fileprivate init(id: Int64, frame: Int, priority: Int, serial: Int, epoch: Int, revision: Int) {
        self.id = id
        storage = OSAllocatedUnfairLock(initialState: Row(id: id, frame: frame, priority: priority,
            serial: serial, epoch: epoch, revision: revision, values: Array(repeating: nil, count: Stage.allCases.count)))
    }

    public func mark(_ stage: Stage) {
        let now = DispatchTime.now().uptimeNanoseconds
        storage.withLock { row in
            if row[stage] == nil { row.values[stage.rawValue] = now }
        }
    }

    public func mark(_ stage: Stage, outcome: Int64) {
        let now = DispatchTime.now().uptimeNanoseconds
        storage.withLock { row in
            guard row[stage] == nil else { return }
            row.values[stage.rawValue] = now
            if stage == .coordinatorFinished { row.coordinatorOutcome = outcome }
            if stage == .controllerCallback { row.controllerOutcome = outcome }
        }
    }

    public func add(_ stage: Stage, nanoseconds: UInt64) {
        storage.withLock { row in row.values[stage.rawValue] = (row[stage] ?? 0) + nanoseconds }
    }

    public func snapshot() -> Row { storage.withLock { $0 } }
}

/// Used by the isolated image/Spectrum self-test during its first Play only.
/// Previously admitted requests can publish their terminal stamps after selection closes.
@MainActor public final class SpectrumRequestTimingCapture {
    public static let frameWindow = 0..<120
    public static let maxRequests = 256
    public nonisolated static let byteLimit = 2 * 1024 * 1024
    public static func enabled(arguments: [String]) -> Bool {
        arguments.contains("-OTFSpectrumRequestTiming") && arguments.contains("-OTFImageSpectrumTest") &&
        !arguments.contains("-OTFSpectrumContinuityTrace") && !arguments.contains("-OTFOwnerSpectrumPlaybackTrace")
    }

    public struct Report: Encodable, Sendable {
        public let version = 1
        public let firstFrame: Int
        public let endFrameExclusive: Int
        public let capacity: Int
        public let selectionEnded: Bool
        public let overflow, outsideWindow, incomplete: Int
        public let complete: Bool
        public let stages: [String]
        public let durationStages: [String]
        public let clock = "DispatchTime.uptimeNanoseconds"
        public let rows: [SpectrumRequestTiming.Row]

        public func encoded() throws -> Data {
            let data = try JSONEncoder().encode(self)
            guard data.count <= SpectrumRequestTimingCapture.byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
            return data
        }
    }

    private let capacity: Int
    private var selectionEnded = false
    private var requests: [SpectrumRequestTiming] = []
    private var overflow = 0, outsideWindow = 0

    public init(capacity: Int = 256) {
        self.capacity = min(Self.maxRequests, max(1, capacity))
        requests.reserveCapacity(self.capacity)
    }

    public func begin(frame: Int, priority: Int = 0, serial: Int = 0,
                      epoch: Int = 0, revision: Int = 0) -> SpectrumRequestTiming? {
        guard !selectionEnded else { return nil }
        guard Self.frameWindow.contains(frame) else { outsideWindow += 1; return nil }
        guard requests.count < capacity else { overflow += 1; return nil }
        let request = SpectrumRequestTiming(id: Int64(requests.count + 1), frame: frame, priority: priority,
                                            serial: serial, epoch: epoch, revision: revision)
        requests.append(request)
        return request
    }

    public func request(id: Int64) -> SpectrumRequestTiming? {
        guard id > 0, id <= Int64(requests.count) else { return nil }
        return requests[Int(id) - 1]
    }

    public func endSelection() { selectionEnded = true }

    public func report() -> Report {
        let rows = requests.map { $0.snapshot() }
        let unfinished = rows.filter { !$0.finished }.count
        let stages = SpectrumRequestTiming.Stage.allCases.map { String(describing: $0) }
        return Report(firstFrame: Self.frameWindow.lowerBound, endFrameExclusive: Self.frameWindow.upperBound,
                      capacity: capacity, selectionEnded: selectionEnded, overflow: overflow,
                      outsideWindow: outsideWindow, incomplete: unfinished,
                      complete: selectionEnded && !rows.isEmpty && unfinished == 0 && overflow == 0,
                      stages: stages, durationStages: Array(stages[SpectrumRequestTiming.Stage.baseGeometry.rawValue...]),
                      rows: rows)
    }

    public func encodedReport() throws -> Data {
        try report().encoded()
    }
}
#endif
