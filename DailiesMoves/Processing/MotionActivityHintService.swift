import Foundation
import CoreMotion

/// Retroactively queries Apple's hardware motion coprocessor ONLY when the user manually triggers Review mode.
/// Zero background CPU or battery usage: iOS already stores up to 7 days of motion history at the OS level.
final class MotionActivityHintService: @unchecked Sendable {
    struct MotionInterval: Sendable {
        let startDate: Date
        let endDate: Date
        let suggestedActivityID: String?
        let isStationary: Bool
    }

    static let shared = MotionActivityHintService()

    private let manager = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.dailiesmoves.motion.hints"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    func queryHints(from start: Date, to end: Date) async -> [MotionInterval] {
        guard CMMotionActivityManager.isActivityAvailable() else { return [] }
        // Only query when already authorized so Review never blocks on an OS permission prompt.
        guard CMMotionActivityManager.authorizationStatus() == .authorized else { return [] }

        return await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: start, to: end, to: queue) { activities, _ in
                guard let activities, !activities.isEmpty else {
                    continuation.resume(returning: [])
                    return
                }
                var intervals: [MotionInterval] = []
                for idx in activities.indices {
                    let act = activities[idx]
                    guard act.confidence != .low else { continue }
                    let nextDate = (idx + 1 < activities.count) ? activities[idx + 1].startDate : end
                    guard nextDate > act.startDate else { continue }

                    let suggestedID: String?
                    if act.cycling {
                        suggestedID = "biking"
                    } else if act.automotive {
                        suggestedID = "car"
                    } else if act.running {
                        suggestedID = "running"
                    } else if act.walking {
                        suggestedID = "walking"
                    } else {
                        suggestedID = nil
                    }

                    intervals.append(MotionInterval(
                        startDate: act.startDate,
                        endDate: nextDate,
                        suggestedActivityID: suggestedID,
                        isStationary: act.stationary && suggestedID == nil
                    ))
                }
                continuation.resume(returning: intervals)
            }
        }
    }
}
