import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

/// Snapshot of game state at a point in time, used by all three widget families.
struct TimVoiceTimelineEntry: TimelineEntry {
    let date: Date

    /// Hours and minutes off-phone today.
    let timeAliveSeconds: TimeInterval

    /// Current streak in days.
    let currentStreak: Int

    /// Number of phone pickups today.
    let pickupsToday: Int

    /// Whether this is preview/placeholder data.
    let isPlaceholder: Bool

    // MARK: - Derived

    var timeAliveHours: Int { Int(timeAliveSeconds) / 3600 }
    var timeAliveMinutes: Int { (Int(timeAliveSeconds) % 3600) / 60 }

    var timeAliveFormatted: String {
        String(format: "%d:%02d", timeAliveHours, timeAliveMinutes)
    }

    var streakColor: Color {
        if currentStreak >= 7 { return .green }
        if currentStreak >= 3 { return .yellow }
        return .orange
    }

    /// Fraction of a 16-hour waking day spent alive (off-phone).
    var timeAliveFraction: Double {
        let wakingSeconds: Double = 16 * 3600
        return min(timeAliveSeconds / wakingSeconds, 1.0)
    }
}

// MARK: - Timeline Provider

struct TimVoiceTimelineProvider: TimelineProvider {
    private let appGroupID = "group.community.holm.timvoice"

    func placeholder(in context: Context) -> TimVoiceTimelineEntry {
        TimVoiceTimelineEntry(
            date: .now,
            timeAliveSeconds: 5 * 3600 + 42 * 60, // 5:42
            currentStreak: 7,
            pickupsToday: 3,
            isPlaceholder: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TimVoiceTimelineEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TimVoiceTimelineEntry>) -> Void) {
        let entry = currentEntry()

        // Refresh every 5 minutes so TIME ALIVE stays roughly current.
        // The complication can't update in true real-time, but 5-minute
        // granularity is fine — Tim shouldn't be staring at his watch.
        let refreshDate = Calendar.current.date(byAdding: .minute, value: 5, to: entry.date) ?? entry.date
        let timeline = Timeline(entries: [entry], policy: .after(refreshDate))
        completion(timeline)
    }

    // MARK: - Read from Shared Defaults

    private func currentEntry() -> TimVoiceTimelineEntry {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: "watch_shared_game_state") else {
            return TimVoiceTimelineEntry(
                date: .now,
                timeAliveSeconds: 0,
                currentStreak: 0,
                pickupsToday: 0,
                isPlaceholder: false
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(SharedGameState.self, from: data) else {
            return TimVoiceTimelineEntry(
                date: .now,
                timeAliveSeconds: 0,
                currentStreak: 0,
                pickupsToday: 0,
                isPlaceholder: false
            )
        }

        return TimVoiceTimelineEntry(
            date: .now,
            timeAliveSeconds: state.timeAliveSeconds,
            currentStreak: state.currentStreak,
            pickupsToday: state.pickupsToday,
            isPlaceholder: false
        )
    }
}

// MARK: - TIME ALIVE Widget (Circular)

/// Shows hours:minutes off-phone as a circular gauge on the watch face.
/// The gauge fills over a 16-hour waking day. Full circle = fully alive.
struct TimeAliveWidget: Widget {
    let kind = "TimeAliveWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimVoiceTimelineProvider()) { entry in
            TimeAliveWidgetView(entry: entry)
        }
        .configurationDisplayName("TIME ALIVE")
        .description("Hours and minutes off-phone today.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct TimeAliveWidgetView: View {
    let entry: TimVoiceTimelineEntry

    var body: some View {
        Gauge(value: entry.timeAliveFraction) {
            // Label (not visible in circular, but required)
            Text("ALIVE")
        } currentValueLabel: {
            Text(entry.timeAliveFormatted)
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundColor(.green)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(gaugeGradient)
        .widgetAccentable()
    }

    private var gaugeGradient: Gradient {
        Gradient(colors: [.green.opacity(0.4), .green, .mint])
    }
}

// MARK: - Streak Widget (Corner)

/// Shows the current streak number in the corner of the watch face.
/// Color-coded: green (7+ days), yellow (3-6 days), orange (< 3 days).
struct StreakWidget: Widget {
    let kind = "StreakWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimVoiceTimelineProvider()) { entry in
            StreakWidgetView(entry: entry)
        }
        .configurationDisplayName("Streak")
        .description("Your current screenless streak in days.")
        .supportedFamilies([.accessoryCorner])
    }
}

struct StreakWidgetView: View {
    let entry: TimVoiceTimelineEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Text("\(entry.currentStreak)")
                .font(.system(size: 24, weight: .black, design: .monospaced))
                .foregroundColor(entry.streakColor)
                .widgetAccentable()
        }
        .widgetLabel {
            Text("\(entry.currentStreak)d streak")
                .font(.system(size: 10, design: .monospaced))
        }
    }
}

// MARK: - Pickup Count Widget (Inline)

/// Shows "X pickups" as inline text on the watch face.
/// The fewer, the better. Zero is the goal.
struct PickupCountWidget: Widget {
    let kind = "PickupCountWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TimVoiceTimelineProvider()) { entry in
            PickupCountWidgetView(entry: entry)
        }
        .configurationDisplayName("Pickups")
        .description("How many times you picked up your phone today.")
        .supportedFamilies([.accessoryInline])
    }
}

struct PickupCountWidgetView: View {
    let entry: TimVoiceTimelineEntry

    var body: some View {
        Text(pickupText)
            .font(.system(.body, design: .monospaced))
    }

    private var pickupText: String {
        if entry.pickupsToday == 0 {
            return "0 pickups"
        } else if entry.pickupsToday == 1 {
            return "1 pickup"
        } else {
            return "\(entry.pickupsToday) pickups"
        }
    }
}

// MARK: - Widget Bundle

/// Groups all TimVoice complications into a single bundle so they all
/// appear in the watch face customizer.
@main
struct TimVoiceWidgetBundle: WidgetBundle {
    var body: some Widget {
        TimeAliveWidget()
        StreakWidget()
        PickupCountWidget()
    }
}

// MARK: - Previews

#if DEBUG
#Preview("TIME ALIVE", as: .accessoryCircular) {
    TimeAliveWidget()
} timeline: {
    TimVoiceTimelineEntry(date: .now, timeAliveSeconds: 3 * 3600 + 15 * 60, currentStreak: 5, pickupsToday: 4, isPlaceholder: false)
    TimVoiceTimelineEntry(date: .now, timeAliveSeconds: 8 * 3600, currentStreak: 5, pickupsToday: 4, isPlaceholder: false)
    TimVoiceTimelineEntry(date: .now, timeAliveSeconds: 14 * 3600, currentStreak: 5, pickupsToday: 1, isPlaceholder: false)
}

#Preview("Streak", as: .accessoryCorner) {
    StreakWidget()
} timeline: {
    TimVoiceTimelineEntry(date: .now, timeAliveSeconds: 0, currentStreak: 1, pickupsToday: 0, isPlaceholder: false)
    TimVoiceTimelineEntry(date: .now, timeAliveSeconds: 0, currentStreak: 5, pickupsToday: 0, isPlaceholder: false)
    TimVoiceTimelineEntry(date: .now, timeAliveSeconds: 0, currentStreak: 14, pickupsToday: 0, isPlaceholder: false)
}

#Preview("Pickups", as: .accessoryInline) {
    PickupCountWidget()
} timeline: {
    TimVoiceTimelineEntry(date: .now, timeAliveSeconds: 0, currentStreak: 0, pickupsToday: 0, isPlaceholder: false)
    TimVoiceTimelineEntry(date: .now, timeAliveSeconds: 0, currentStreak: 0, pickupsToday: 7, isPlaceholder: false)
    TimVoiceTimelineEntry(date: .now, timeAliveSeconds: 0, currentStreak: 0, pickupsToday: 42, isPlaceholder: false)
}
#endif
