import SwiftUI
import Combine

/// A text component that cyclically transitions through an array of strings at a fixed temporal interval.
struct AnimatedLabel: View {
    /// The collection of localizable string tokens or plain text messages to rotate through.
    let texts: [String]
    
    @State private var currentIndex = 0
    
    /// A foundational publishing stream driving state updates at a specific interval.
    private let timer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    var body: some View {
        // Guard against empty arrays to prevent out-of-bounds runtime crashes
        if !texts.isEmpty {
            Text(texts[currentIndex])
                // Identifies unique views to help the transition engine evaluate structural modifications
                .id(currentIndex)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .onReceive(timer) { _ in
                    withAnimation(.easeInOut(duration: 0.35)) {
                        currentIndex = (currentIndex + 1) % texts.count
                    }
                }
        } else {
            Text("")
        }
    }
}
