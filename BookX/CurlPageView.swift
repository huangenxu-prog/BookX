import SwiftUI
import UIKit

/// UIKit's native page curl, bridged into SwiftUI.
struct CurlPageView: UIViewControllerRepresentable {
    let pages: [String]
    @Binding var currentPage: Int
    let fontSize: Double
    let lineSpacing: Double
    let ink: Color
    let background: Color

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
        var pages: [String] = []
        var fontSize: Double = 0
        var lineSpacing: Double = 0
        var controllers: [Int: IndexedPageController] = [:]
        init(_ parent: CurlPageView) { self.parent = parent }

        func rebuild(pages: [String], fontSize: Double, lineSpacing: Double, ink: Color, background: Color) {
            self.pages = pages
            self.fontSize = fontSize
            self.lineSpacing = lineSpacing
            controllers.removeAll()
        }

        func controller(at index: Int) -> IndexedPageController? {
            guard pages.indices.contains(index) else { return nil }
            if let cached = controllers[index] { return cached }
            let view = AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    Text(pages[index])
                        .font(.system(size: fontSize))
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(parent.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(parent.background)
            )
            let result = IndexedPageController(index: index, view: view)
            result.view.backgroundColor = UIColor(parent.background)
            // Keep only a small neighborhood rather than thousands of hosting controllers.
            controllers = controllers.filter { abs($0.key - index) <= 3 }
            controllers[index] = result
            return result
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
