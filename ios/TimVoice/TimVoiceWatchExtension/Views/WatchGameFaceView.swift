import SwiftUI
import WatchKit

/// The Watch face. The Ally's interface.
///
/// Emotionally inverted from the iPhone's GameView:
/// - Phone: black-to-red background (punishment)      Watch: green-to-blue (reward)
/// - Phone: taunts (aggressive)                        Watch: encouragement (warm)
/// - Phone: shame counter (loud)                       Watch: pickup count (quiet)
/// - Phone: "PUT. IT. DOWN."                           Watch: "You're doing it."
///
/// Minimal. Monospaced. Same design language, opposite emotional valence.
struct WatchGameFaceView: View {
    @EnvironmentObject var game: WatchGameEngine
    @EnvironmentObject var session: WatchSessionManager

    var body: some View {
        ZStack {
            // Background gradient — shifts from calm green to vibrant blue
            // as TIME ALIVE increases. The inverse of the phone's black-to-red.
            backgroundGradient
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 3), value: game.timeAliveSeconds)

            ScrollView {
                VStack(spacing: 8) {
                    // Phone far away indicator — the best state
                    if game.isPhoneFarAway {
                        phoneFarAwayBadge
                    }

                    Spacer().frame(height: 4)

                    // Primary: TIME ALIVE
                    timeAliveSection

                    Spacer().frame(height: 8)

                    // Encouragement — rotating positive messages
                    encouragementSection

                    Spacer().frame(height: 8)

                    // Streak
                    streakSection

                    // Active challenge card
                    if game.activeChallenge != nil {
                        challengeCard
                    }

                    Spacer().frame(height: 8)

                    // Pickup counter — small, quiet, at the bottom
                    pickupCounter
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Phone Far Away Badge

    private var phoneFarAwayBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)

            Text("PHONE FAR AWAY")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.green.opacity(0.15))
        .cornerRadius(8)
        .transition(.opacity)
    }

    // MARK: - Time Alive

    private var timeAliveSection: some View {
        VStack(spacing: 2) {
            Text("TIME ALIVE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))

            Text(game.timeAliveString)
                .font(.system(size: 38, weight: .black, design: .monospaced))
                .foregroundColor(.white)
                .minimumScaleFactor(0.7)
        }
    }

    // MARK: - Encouragement

    private var encouragementSection: some View {
        Text(game.encouragement)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .animation(.easeInOut(duration: 0.5), value: game.encouragement)
    }

    // MARK: - Streak

    private var streakSection: some View {
        VStack(spacing: 2) {
            Text("STREAK")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            Text("\(game.currentStreak)d")
                .font(.system(size: 22, weight: .black, design: .monospaced))
                .foregroundColor(streakSwiftUIColor)

            if game.longestStreak > game.currentStreak {
                Text("best: \(game.longestStreak)d")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
    }

    // MARK: - Challenge Card

    private var challengeCard: some View {
        VStack(spacing: 6) {
            if let challenge = game.activeChallenge {
                Text("CHALLENGE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.8))

                Text(challenge.text)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)

                Text(challenge.reward)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.green.opacity(0.8))

                Button(action: {
                    game.completeChallenge()
                }) {
                    Text("DONE")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.green)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }

    // MARK: - Pickup Counter

    /// Small and quiet. The Watch doesn't shame — it just notes.
    private var pickupCounter: some View {
        Text("\(game.pickupsToday) pickup\(game.pickupsToday == 1 ? "" : "s") today")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.3))
    }

    // MARK: - Helpers

    private var backgroundGradient: some View {
        let colors = game.backgroundGradient
        return LinearGradient(
            colors: colors.map { Color(red: $0.red, green: $0.green, blue: $0.blue) },
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var streakSwiftUIColor: Color {
        let c = game.streakColor
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

// MARK: - Preview

#if DEBUG
struct WatchGameFaceView_Previews: PreviewProvider {
    static var previews: some View {
        WatchGameFaceView()
            .environmentObject(WatchGameEngine.shared)
            .environmentObject(WatchSessionManager.shared)
    }
}
#endif
