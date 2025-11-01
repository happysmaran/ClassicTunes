import SwiftUI

struct AnimatedLabel: View {
    let texts: [String]
    @State private var currentIndex = 0

    var body: some View {
        Text(texts[currentIndex])
            .transition(.opacity)
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
                    withAnimation {
                        currentIndex = (currentIndex + 1) % texts.count
                    }
                }
            }
    }
}
