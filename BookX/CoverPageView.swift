import SwiftUI

/// New page slides over the previous page rather than moving both pages together.
struct CoverPageView: View {
    let pages: [ReadingPage]
    @Binding var currentPage: Int
    let fontSize: Double
    let lineSpacing: Double
    let ink: Color
    let background: Color

    @State private var displayedPage = 0
    @State private var incomingPage: Int?
    @State private var incomingOffset: CGFloat = 0
    @State private var animating = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                page(at: displayedPage)
                if let incomingPage {
                    page(at: incomingPage)
                        .offset(x: incomingOffset)
                        .shadow(color: .black.opacity(0.13), radius: 5, x: -3)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 35).onEnded { value in
                    if value.translation.width < -60 { currentPage = min(pages.count - 1, displayedPage + 1) }
                    if value.translation.width > 60 { currentPage = max(0, displayedPage - 1) }
                }
            )
            .onAppear { displayedPage = currentPage }
            .onChange(of: currentPage) { _, next in
                guard pages.indices.contains(next), next != displayedPage else { return }
                guard !animating else {
                    displayedPage = next
                    incomingPage = nil
                    animating = false
                    return
                }
                if next < displayedPage {
                    // Reveal the previous page by sliding the current page away.
                    displayedPage = next
                    incomingPage = nil
                } else {
                    incomingPage = next
                    incomingOffset = geometry.size.width
                    animating = true
                    withAnimation(.easeOut(duration: 0.28)) { incomingOffset = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        displayedPage = next
                        incomingPage = nil
                        animating = false
                    }
                }
            }
        }
        .background(background)
    }

    @ViewBuilder private func page(at index: Int) -> some View {
        if pages.indices.contains(index) {
            ScrollView {
                Text(pages[index].text)
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
        }
    }
}
