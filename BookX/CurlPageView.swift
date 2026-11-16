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
        if coordinator.pages != pages || coordinator.fontSize != fontSize || coordinator.lineSpacing != lineSpacing {
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
        var controllers: [IndexedPageController] = []
        init(_ parent: CurlPageView) { self.parent = parent }

        func rebuild(pages: [String], fontSize: Double, lineSpacing: Double, ink: Color, background: Color) {
            self.pages = pages
            self.fontSize = fontSize
            self.lineSpacing = lineSpacing
            controllers = pages.enumerated().map { index, text in
                let view = AnyView(
                    ScrollView {
                        Text(text)
                            .font(.system(size: fontSize))
                            .lineSpacing(lineSpacing)
                            .foregroundStyle(ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(24)
                    }
                    .background(background)
                )
                let controller = IndexedPageController(index: index, view: view)
                controller.view.backgroundColor = UIColor(background)
                return controller
            }
        }

        func controller(at index: Int) -> IndexedPageController? {
            controllers.indices.contains(index) ? controllers[index] : nil
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
