import SwiftUI
import Combine

/// A text component that cyclically transitions through an array of strings at a fixed temporal interval.
struct AnimatedLabel: View {
    /// The collection of localizable string tokens or plain text messages to rotate through.
    let texts: [String]
    
    @State private var currentIndex = 0

    var body: some View {
        // Guard against empty arrays to prevent out-of-bounds runtime crashes
        if !texts.isEmpty {
            Text(texts[currentIndex % texts.count])
                // Identifies unique views to help the transition engine evaluate structural modifications
                .id(currentIndex)
                // Gentle side-to-side slide: new text drifts in from the right, old drifts out to the left.
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: 14)),
                    removal: .opacity.combined(with: .offset(x: -14))
                ))
                // A task tied to the view's identity keeps its schedule even when the parent
                // re-renders often (e.g. on every playback position tick), unlike a timer
                // created inside this struct, which would restart on each re-render.
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2.5))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.6)) {
                            currentIndex = (currentIndex + 1) % max(texts.count, 1)
                        }
                    }
                }
        } else {
            Text("")
        }
    }
}
