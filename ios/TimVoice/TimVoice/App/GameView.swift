import SwiftUI
import CoreMotion
import UIKit

/// The Game. The phone is the enemy.
///
/// It knows everything — your voice, your location, your habits, how long
/// since you last picked it up. Every time you look at the screen, it
/// messes with you. The goal: put the phone down and go live.
///
/// The longer you stay off the phone, the higher your score.
/// Pick it up? It punishes you.
struct GameView: View {
    @StateObject private var game = GameEngine.shared
    @State private var showingChallenge = false

    var body: some View {
        ZStack {
            // Background shifts based on how long you've been on the phone
            game.backgroundColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 2), value: game.screenTimeThisSession)

            VStack(spacing: 0) {
                // The taunt
                Text(game.currentTaunt)
                    .font(.system(size: 28, weight: .black, design: .monospaced))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity)
                    .animation(.easeInOut, value: game.currentTaunt)

                Spacer()

                // The score — how long you've been OFF the phone today
                VStack(spacing: 8) {
                    Text("TIME ALIVE")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))

                    Text(game.timeAliveString)
                        .font(.system(size: 64, weight: .black, design: .monospaced))
                        .foregroundColor(.white)

                    Text("(time OFF this phone)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()

                // Current streak
                VStack(spacing: 4) {
                    Text("STREAK")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))

                    Text("\(game.currentStreak) days")
                        .font(.system(size: 36, weight: .black, design: .monospaced))
                        .foregroundColor(game.streakColor)

                    Text("longest: \(game.longestStreak) days")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()

                // The challenge button — if you're going to be on your phone,
                // at least do something real
                if let challenge = game.activeChallenge {
                    VStack(spacing: 12) {
                        Text("FINE. DO THIS:")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)

                        Text(challenge.text)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(12)

                        Text(challenge.reward)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()

                // Pickup counter — shame display
                Text("You've picked up this phone \(game.pickupsToday) times today.")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.red.opacity(0.7))
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            game.phonePickedUp()
        }
    }
}
