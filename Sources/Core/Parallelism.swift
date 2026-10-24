import Foundation

/// How many files run side by side, sized to the Mac and how it's doing.
enum Parallelism {
    /// What the limits are worked out from.
    struct Machine: Equatable {
        /// Physical cores; Intel's hyper-threads share one core's work.
        var cores: Int
        var memoryGB: Int
        var thermal: ProcessInfo.ThermalState
        var lowPower: Bool

        static var current: Machine {
            var physical: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let cores = sysctlbyname("hw.physicalcpu", &physical, &size, nil, 0) == 0 && physical > 0
                ? Int(physical) : ProcessInfo.processInfo.activeProcessorCount
            let info = ProcessInfo.processInfo
            return Machine(cores: cores, memoryGB: Int(info.physicalMemory >> 30), thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled)
        }
    }

    /// Pictures decode and encode on the CPU, so one per core, up to 8 and
    /// one per 2 GB of memory. Audio leaves room for ffmpeg's own threads. The
    /// Mac has a single video encoder, so two videos keep it busy while one
    /// is read or copied. Document converters share AppKit and WebKit state
    /// and run in turn. A hot Mac or Low Power Mode halves the work.
    static func limit(for categories: [FormatCatalog.Category?], on machine: Machine = .current) -> Int {
        let pictures = pictureLimit(on: machine)
        let base = categories.map { category -> Int in
            switch category {
            case .image: return pictures
            case .audio: return min(pictures, max(2, machine.cores / 2))
            case .video: return 2
            default: return 1
            }
        }.min() ?? 1
        switch machine.thermal {
        case .critical: return 1
        case .serious: return max(1, base / 2)
        default: return machine.lowPower ? max(1, base / 2) : base
        }
    }

    static func pictureLimit(on machine: Machine) -> Int {
        max(1, min(8, machine.cores, machine.memoryGB / 2))
    }
}

/// Caps how many files run at once across every job, so several drops in a
/// row share the Mac instead of each taking all of it. A job must not wait
/// for a slot while holding one, or the two could wait on each other.
actor WorkSlots {
    static let shared = WorkSlots(capacity: Parallelism.pictureLimit(on: .current))

    private let capacity: Int
    private var used = 0
    private var waiting: [(id: UUID, resume: CheckedContinuation<Void, Error>)] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Runs `body` once a slot is free and gives the slot back afterwards.
    nonisolated func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            // A free slot is taken at once, even by a job already cancelled.
            try Task.checkCancellation()
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async throws {
        if used < capacity && waiting.isEmpty {
            used += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancelled before queueing: the handler below found nothing to cancel.
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).resume.resume(throwing: CancellationError())
    }

    /// Hands the slot straight to the next job in line, if any.
    private func release() {
        if waiting.isEmpty { used -= 1 } else { waiting.removeFirst().resume.resume() }
    }
}
