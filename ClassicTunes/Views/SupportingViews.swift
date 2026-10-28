import SwiftUI
import Combine

// A single-line text that scrolls side to side when it is too long to fit
// in `maxWidth`. Text that fits is shown as-is of course.
struct MarqueeText: View {
    let text: String
    let maxWidth: CGFloat

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    // How far the text must travel to reveal its full length.
    private var overflow: CGFloat { max(textWidth - containerWidth, 0) }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            .offset(x: -offset)
            .frame(maxWidth: maxWidth, alignment: overflow > 0 ? .leading : .center)
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
            // Restarts whenever the text or the available width changes.
            .task(id: "\(text)|\(overflow)") {
                offset = 0
                guard overflow > 1 else { return }
                let duration = Double(overflow) / 30 // ~30 pt/s
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: duration)) { offset = overflow }
                    try? await Task.sleep(for: .seconds(duration + 1.5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: duration)) { offset = 0 }
                    try? await Task.sleep(for: .seconds(duration))
                }
            }
    }
}

// A text component that cyclically transitions through an array of strings at a fixed temporal interval.
struct AnimatedLabel: View {
    // The collection of localizable string tokens or plain text messages to rotate through.
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
