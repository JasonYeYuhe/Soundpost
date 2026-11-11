import SwiftUI
import WidgetKit

/// "New capsule" on the Home Screen and the Lock Screen: one tap target that opens capture
/// idle (M22 §4D). It shows no count, no date and no capsule — nothing a locked phone
/// should not show — so it needs no data, no App Group and no refresh.
struct LauncherWidget: Widget {
    /// Never change it once shipped: a widget someone placed is bound to its kind, and a
    /// new kind removes it from their Home Screen.
    static let kind = "com.soundpost.Soundpost.widget.newCapsule"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: LauncherProvider()) { _ in
            LauncherView()
        }
        .configurationDisplayName("New capsule")
        .description("Opens Soundpost ready to record. Nothing records until you tap the record button.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
        // A capture launcher does not belong on a car's screen, and a Mac cannot record
        // on the phone's behalf. Listed under "Other" there rather than suggested (D14).
        .disfavoredLocations(Self.disfavored, for: [.systemSmall])
    }

    static var disfavored: [WidgetLocation] {
        if #available(iOS 26.0, *) {
            return [.carPlay, .iPhoneWidgetsOnMac]
        }
        return [.iPhoneWidgetsOnMac]
    }
}

struct LauncherEntry: TimelineEntry {
    let date: Date
}

/// One entry, forever: the launcher never changes.
struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry {
        LauncherEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        face
            // Every face reads as one VoiceOver element, "New capsule" (M23 §4E.3): the
            // small and rectangular faces used to expose the glyph as a second element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("New capsule")
            // The whole widget is the door: the app sets the capture request for this
            // URL and nothing else (`CaptureDoor.open`, in `SoundpostApp`).
            .widgetURL(CaptureDoor.newCapsuleURL)
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var face: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "waveform")
                    .font(.title2)
                    .widgetAccentable()
            }
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .widgetAccentable()
                Text("New capsule")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading) {
                Image(systemName: "waveform")
                    .font(.title)
                    .widgetAccentable()
                Spacer()
                Text("New capsule")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
