import SwiftUI

struct LiveTVProgramProgressLine: View {
    let progress: CGFloat
    let isFocused: Bool
    let width: CGFloat
    let tick: Int

    private var clampedProgress: CGFloat {
        min(max(progress, 0.0), 1.0)
    }

    var body: some View {
        ZStack(alignment: Alignment.leading) {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.34))
            Capsule(style: .continuous)
                .fill(Color.red.opacity(0.88))
                .frame(width: max(2.0, width * clampedProgress))
                .shadow(color: Color.red.opacity(0.32), radius: 5, y: 0)
        }
        .frame(width: width, height: 4.0)
        .clipShape(Capsule(style: .continuous))
        .opacity(0.90)
        .id(tick)
        .accessibilityHidden(true)
    }
}
