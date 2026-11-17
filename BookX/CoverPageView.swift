import SwiftUI

/// Forward: the next sheet covers this one. Backward: this sheet reveals the previous one.
struct CoverPageView: View {
    let pages: [ReadingPage]
    @Binding var currentPage: Int
    let fontSize: Double
    let lineSpacing: Double
    let ink: Color
    let background: Color

    @State private var displayedPage = 0
    @State private var targetPage: Int?
    @State private var sheetOffset: CGFloat = 0
    @State private var goingForward = true
    @State private var transitionID = UUID()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let targetPage {
                    page(at: goingForward ? displayedPage : targetPage)
                    page(at: goingForward ? targetPage : displayedPage)
                        .offset(x: sheetOffset)
                        .shadow(color: .black.opacity(0.18), radius: 6, x: -3)
                } else {
                    page(at: displayedPage)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                guard targetPage == nil,
                      abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) > 45 else { return }
                currentPage = max(0, min(pages.count - 1, currentPage + (value.translation.width < 0 ? 1 : -1)))
            })
            .onAppear { displayedPage = currentPage }
            .onChange(of: currentPage) { _, next in
                guard pages.indices.contains(next), next != displayedPage || targetPage != nil else { return }
                turn(to: next, width: geometry.size.width)
            }
            .onDisappear { transitionID = UUID() }
        }
        .background(background)
    }

    private func turn(to next: Int, width: CGFloat) {
        let token = UUID()
        transitionID = token
        // Commit an interrupted turn before starting another; old completions are invalidated.
        if let targetPage { displayedPage = targetPage }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            goingForward = next > displayedPage
            targetPage = next
            sheetOffset = goingForward ? width : 0
        }
        // Insert the sheet at its starting position before changing the animated offset.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            guard transitionID == token else { return }
            withAnimation(.easeInOut(duration: 0.28), completionCriteria: .logicallyComplete) {
                sheetOffset = goingForward ? 0 : width
            } completion: {
                guard transitionID == token else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayedPage = next
                    targetPage = nil
                    sheetOffset = 0
                }
            }
        }
    }

    private func page(at index: Int) -> some View {
        ZStack {
            background
            if pages.indices.contains(index) {
                ScreenPageView(text: pages[index].text, fontSize: fontSize, lineSpacing: lineSpacing, ink: ink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
