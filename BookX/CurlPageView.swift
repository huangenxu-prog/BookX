import SwiftUI
import UIKit

/// UIKit's native page curl, bridged into SwiftUI.
struct CurlPageView: UIViewControllerRepresentable {
    static let headerHeight: CGFloat = 40
    static let footerHeight: CGFloat = 28

    let pages: [ReadingPage]
    @Binding var currentPage: Int
    let fontSize: Double
    let lineSpacing: Double
    let ink: Color
    let background: Color
    let header: AnyView
    let topInset: CGFloat
    let bottomInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [UIPageViewController.OptionsKey.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)]
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.rebuild(pages: pages, fontSize: fontSize, lineSpacing: lineSpacing, ink: ink, background: background)
        if let first = context.coordinator.controller(at: currentPage) {
            controller.setViewControllers([first], direction: .forward, animated: false)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.pages.count != pages.count || coordinator.fontSize != fontSize || coordinator.lineSpacing != lineSpacing {
            coordinator.rebuild(pages: pages, fontSize: fontSize, lineSpacing: lineSpacing, ink: ink, background: background)
        }
        coordinator.refreshChrome()
        guard let target = coordinator.controller(at: currentPage),
              controller.viewControllers?.first !== target else { return }
        let old = (controller.viewControllers?.first as? IndexedPageController)?.pageIndex ?? 0
        controller.setViewControllers([target], direction: currentPage >= old ? .forward : .reverse, animated: false)
    }

    final class IndexedPageController: UIHostingController<AnyView> {
        let pageIndex: Int
        init(index: Int, view: AnyView) {
            pageIndex = index
            super.init(rootView: view)
        }
        @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) unavailable") }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: CurlPageView
        var pages: [ReadingPage] = []
        var fontSize: Double = 0
        var lineSpacing: Double = 0
        var controllers: [Int: IndexedPageController] = [:]
        init(_ parent: CurlPageView) { self.parent = parent }

        func rebuild(pages: [ReadingPage], fontSize: Double, lineSpacing: Double, ink: Color, background: Color) {
            self.pages = pages
            self.fontSize = fontSize
            self.lineSpacing = lineSpacing
            controllers.removeAll()
        }

        func controller(at index: Int) -> IndexedPageController? {
            guard pages.indices.contains(index) else { return nil }
            if let cached = controllers[index] { return cached }
            let view = pageView(at: index)
            let result = IndexedPageController(index: index, view: view)
            result.view.backgroundColor = UIColor(parent.background)
            // Keep only a small neighborhood rather than thousands of hosting controllers.
            controllers = controllers.filter { abs($0.key - index) <= 3 }
            controllers[index] = result
            return result
        }
        private func pageView(at index: Int) -> AnyView {
            AnyView(
                VStack(spacing: 0) {
                    parent.header
                        .padding(.top, parent.topInset)
                        .frame(height: CurlPageView.headerHeight + parent.topInset)
                    ScreenPageView(text: pages[index].text, fontSize: fontSize,
                                   lineSpacing: lineSpacing, ink: parent.ink)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    Text("\(index + 1) / \(pages.count)")
                        .font(.caption)
                        .foregroundStyle(parent.ink.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .frame(height: CurlPageView.footerHeight)
                        .padding(.bottom, parent.bottomInset)
                        .accessibilityIdentifier("reading-position")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(parent.ink)
                .background(parent.background)
                // Hosting controllers otherwise add their own safe-area margins,
                // duplicating the insets already included in the turning sheet.
                .ignoresSafeArea()
            )
        }

        // Each sheet owns its controls; refresh cached sheets when listening state changes.
        func refreshChrome() {
            for (index, controller) in controllers where pages.indices.contains(index) {
                controller.rootView = pageView(at: index)
            }
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? IndexedPageController else { return nil }
            return controller(at: page.pageIndex - 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? IndexedPageController else { return nil }
            return controller(at: page.pageIndex + 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let page = pageViewController.viewControllers?.first as? IndexedPageController else { return }
            parent.currentPage = page.pageIndex
        }
    }
}
