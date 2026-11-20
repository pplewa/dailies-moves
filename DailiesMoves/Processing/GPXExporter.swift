import Foundation
import UniformTypeIdentifiers
import SwiftUI

/// Exports a reviewed day's timeline to standard GPX 1.1 XML using strict UTC timestamps
/// and a UTC-resolved filename (`YYYY-MM-DD.gpx`).
enum GPXExporter {
    struct ExportPackage: Sendable {
        let utcDateKey: String
        let filename: String
        let xmlString: String
        var data: Data { Data(xmlString.utf8) }
    }

    static func generate(
        localDayKey: String,
        segments: [TimelineSegment],
        rawSamples: [RawLocationSample],
        activityTypes: [ActivityType],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> ExportPackage {
        let activityLookup = Dictionary(uniqueKeysWithValues: activityTypes.map { ($0.id, $0) })

        var eventDates: [Date] = []
        for seg in segments {
            eventDates.append(seg.startDate)
            eventDates.append(seg.endDate)
        }
        if eventDates.isEmpty {
            eventDates = rawSamples.map(\.timestamp)
        }

        let utcDateKey = DateFormatting.resolvedUTCExportDayKey(
            forLocalDayKey: localDayKey,
            eventDates: eventDates,
            now: now,
            timeZone: timeZone
        )
        let filename = "\(utcDateKey).gpx"

        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<gpx version="1.1" creator="DailiesMoves" xmlns="http://www.topografix.com/GPX/1/1" xmlns:dm="https://dailiesmoves.app/gpx/1">"#)
        lines.append("  <metadata>")
        lines.append("    <name>\(xmlEscape(utcDateKey))</name>")
        lines.append("    <desc>\(xmlEscape("Timeline for local day \(localDayKey) exported with UTC timestamps"))</desc>")
        lines.append("    <time>\(DateFormatting.iso8601UTC(now))</time>")
        lines.append("  </metadata>")

        let sortedSegments = segments.sorted { $0.startDate < $1.startDate }
        let sortedSamples = TimelineSegmenter.removeTeleportSpikes(
            rawSamples
                .filter { $0.source != .visitAnchor && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100 }
                .sorted { $0.timestamp < $1.timestamp }
        )

        // 1. Waypoints (<wpt>) for Stationary places
        for seg in sortedSegments where seg.kind == .stationary {
            guard let lat = seg.latitude, let lon = seg.longitude else { continue }
            let name = (seg.placeName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? seg.placeName!
                : "Stationary"
            let startISO = DateFormatting.iso8601UTC(seg.startDate)
            let endISO = DateFormatting.iso8601UTC(seg.endDate)

            lines.append(String(format: "  <wpt lat=\"%.6f\" lon=\"%.6f\">", lat, lon))
            lines.append("    <time>\(startISO)</time>")
            lines.append("    <name>\(xmlEscape(name))</name>")
            lines.append("    <desc>\(xmlEscape("Stationary: \(startISO) to \(endISO)"))</desc>")
            lines.append("    <type>stationary</type>")
            lines.append("    <extensions>")
            lines.append("      <dm:segmentType>stationary</dm:segmentType>")
            lines.append("      <dm:startTime>\(startISO)</dm:startTime>")
            lines.append("      <dm:endTime>\(endISO)</dm:endTime>")
            if let placeID = seg.placeID {
                lines.append("      <dm:placeId>\(xmlEscape(placeID))</dm:placeId>")
            }
            lines.append("    </extensions>")
            lines.append("  </wpt>")
        }

        // 2. Tracks (<trk>) for Move segments
        for seg in sortedSegments where seg.kind == .move {
            let activity = seg.activityTypeID.flatMap { activityLookup[$0] }
            let displayName = activity?.name ?? "Move"
            let gpxType = activity?.gpxType ?? "move"
            let startISO = DateFormatting.iso8601UTC(seg.startDate)
            let endISO = DateFormatting.iso8601UTC(seg.endDate)

            let segSamples = sortedSamples.filter {
                $0.timestamp >= seg.startDate && $0.timestamp <= seg.endDate
            }

            lines.append("  <trk>")
            lines.append("    <name>\(xmlEscape(displayName))</name>")
            lines.append("    <type>\(xmlEscape(gpxType))</type>")
            lines.append("    <extensions>")
            lines.append("      <dm:segmentType>move</dm:segmentType>")
            lines.append("      <dm:startTime>\(startISO)</dm:startTime>")
            lines.append("      <dm:endTime>\(endISO)</dm:endTime>")
            lines.append("    </extensions>")
            lines.append("    <trkseg>")
            if !segSamples.isEmpty {
                for sample in segSamples {
                    lines.append(String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\">", sample.latitude, sample.longitude))
                    if sample.altitude != 0 {
                        lines.append(String(format: "        <ele>%.1f</ele>", sample.altitude))
                    }
                    lines.append("        <time>\(DateFormatting.iso8601UTC(sample.timestamp))</time>")
                    lines.append("      </trkpt>")
                }
            } else if let lat = seg.latitude, let lon = seg.longitude {
                lines.append(String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\">", lat, lon))
                lines.append("        <time>\(startISO)</time>")
                lines.append("      </trkpt>")
            }
            lines.append("    </trkseg>")
            lines.append("  </trk>")
        }

        // Fallback: if no reviewed segments exist yet but user exports raw day directly, emit raw track.
        if sortedSegments.isEmpty && !sortedSamples.isEmpty {
            lines.append("  <trk>")
            lines.append("    <name>Raw Track</name>")
            lines.append("    <type>raw</type>")
            lines.append("    <trkseg>")
            for sample in sortedSamples {
                lines.append(String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\">", sample.latitude, sample.longitude))
                if sample.altitude != 0 {
                    lines.append(String(format: "        <ele>%.1f</ele>", sample.altitude))
                }
                lines.append("        <time>\(DateFormatting.iso8601UTC(sample.timestamp))</time>")
                lines.append("      </trkpt>")
            }
            lines.append("    </trkseg>")
            lines.append("  </trk>")
        }

        lines.append("</gpx>")

        return ExportPackage(
            utcDateKey: utcDateKey,
            filename: filename,
            xmlString: lines.joined(separator: "\n") + "\n"
        )
    }

    private static func xmlEscape(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// SwiftUI `FileDocument` wrapper for native `.fileExporter` (iCloud Drive / Files).
struct GPXFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.gpx, .xml] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    static var gpx: UTType {
        UTType(filenameExtension: "gpx") ?? .xml
    }
}
