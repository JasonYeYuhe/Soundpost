import SwiftUI

/// First-run onboarding: three pages that introduce the capture → place → echo
/// loop, asking for location and notification permission *with context* (the
/// review-safe middle ground between "ask at launch" and "ask mid-task").
/// Denying anything never blocks the app — every capability degrades gracefully
/// and can still be granted just-in-time later.
struct OnboardingView: View {
    let onFinished: () -> Void

    @Environment(NotificationCoordinator.self) private var notifications
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var location = LocationProvider()
    @State private var requesting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                // Skip is only offered on the first (no-permission) page. The
                // location and notification pages must not present an exit button
                // on the message that precedes a system permission request
                // (App Review Guideline 5.1.1(iv)).
                if page == 0 {
                    Button("Skip") { onFinished() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }

            TabView(selection: $page) {
                pageView(
                    symbol: "waveform",
                    tint: .accentColor,
                    title: "Capture how this moment sounds",
                    body: "Up to a minute of real sound — rain, a café, a voice — kept as a beautiful, mood-tinted card.",
                    buttonTitle: "Continue",
                    action: { advance() }
                )
                .tag(0)

                pageView(
                    symbol: "mappin.and.ellipse",
                    tint: .teal,
                    title: "Remember where you were",
                    body: "Soundpost can tag each capsule with the place it was recorded — a memory of where, not just when. Tap Continue to choose whether to allow location.",
                    buttonTitle: "Continue",
                    action: {
                        requesting = true
                        Task {
                            await location.requestAuthorization()
                            requesting = false
                            advance()
                        }
                    }
                )
                .tag(1)

                pageView(
                    symbol: "bell.badge",
                    tint: .purple,
                    title: "Hear today again, someday",
                    body: "Each new capsule picks a random day in the future to echo back and remind you of today. You can change or turn this off anytime.",
                    buttonTitle: "Enable Reminders",
                    action: {
                        requesting = true
                        Task {
                            await notifications.requestAuthorization()
                            requesting = false
                            onFinished()
                        }
                    },
                    secondaryTitle: "Not Now",
                    secondaryAction: { onFinished() }
                )
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .animation(reduceMotion ? nil : .spring(duration: 0.45), value: page)
        }
        .interactiveDismissDisabled()
    }

    private func advance() {
        page = min(page + 1, 2)
    }

    private func pageView(
        symbol: String,
        tint: Color,
        title: LocalizedStringKey,
        body: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        action: @escaping () -> Void,
        secondaryTitle: LocalizedStringKey? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 120, height: 120)
                Image(systemName: symbol)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Spacer()
            VStack(spacing: 10) {
                Button(action: action) {
                    Text(buttonTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(requesting)
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 36)
        }
        .padding(.horizontal, 28)
    }
}

#Preview {
    OnboardingView(onFinished: {})
        .environment(NotificationCoordinator())
}
