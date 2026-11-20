import Foundation

/// Metadata about a local day's review and export status.
struct DayReviewRecord: Identifiable, Hashable, Sendable {
    var id: String { localDayKey }
    let localDayKey: String          // Local day displayed in UI, e.g. "2026-11-19"
    var utcExportDateKey: String?    // Actual UTC date used when saved/exported
    var reviewedAt: Date?            // UTC timestamp
    var exportedAt: Date?            // UTC timestamp
    var lastExportFilename: String?
}

/// Summary row for the Day History list.
struct TrackedDaySummary: Identifiable, Hashable, Sendable {
    var id: String { localDayKey }
    let localDayKey: String
    let date: Date                   // Local start-of-day
    let rawSampleCount: Int
    let segmentCount: Int
    let reviewRecord: DayReviewRecord?

    var isReviewed: Bool {
        reviewRecord?.reviewedAt != nil
    }
}
