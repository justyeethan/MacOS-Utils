import CoreGraphics

/// Gaps resolved for one monitor.
struct ResolvedGaps {
    var innerHorizontal: CGFloat = 0   // between side-by-side windows
    var innerVertical: CGFloat = 0     // between stacked windows
    var outerLeft: CGFloat = 0
    var outerRight: CGFloat = 0
    var outerTop: CGFloat = 0
    var outerBottom: CGFloat = 0

    init() {}

    init(_ gaps: WMConfig.Gaps, monitor: Monitor, all: [Monitor]) {
        func r(_ g: WMConfig.GapValue) -> CGFloat {
            g.perMonitor.first { monitor.matches(pattern: $0.pattern, among: all) }?.value ?? g.fallback
        }
        innerHorizontal = r(gaps.innerHorizontal)
        innerVertical = r(gaps.innerVertical)
        outerLeft = r(gaps.outerLeft)
        outerRight = r(gaps.outerRight)
        outerTop = r(gaps.outerTop)
        outerBottom = r(gaps.outerBottom)
    }

    func workspaceRect(in visibleFrame: CGRect) -> CGRect {
        CGRect(x: visibleFrame.minX + outerLeft,
               y: visibleFrame.minY + outerTop,
               width: max(1, visibleFrame.width - outerLeft - outerRight),
               height: max(1, visibleFrame.height - outerTop - outerBottom))
    }
}

/// Pure layout: tree in, frames out. No AX calls, so it's straightforward to unit-test.
enum LayoutEngine {

    static func frames(for workspace: Workspace,
                       in rect: CGRect,
                       gaps: ResolvedGaps,
                       accordionPadding: CGFloat) -> [(WindowNode, CGRect)] {
        var out: [(WindowNode, CGRect)] = []
        layout(workspace.root, in: rect, gaps: gaps, padding: accordionPadding, into: &out)

        // AeroSpace-style fullscreen: the window covers the whole workspace area.
        for i in out.indices where out[i].0.isFullscreen {
            out[i].1 = rect
        }
        return out
    }

    private static func layout(_ container: TilingContainer,
                               in rect: CGRect,
                               gaps: ResolvedGaps,
                               padding: CGFloat,
                               into out: inout [(WindowNode, CGRect)]) {
        container.lastRect = rect
        let kids = container.children
        guard !kids.isEmpty else { return }

        let rects: [CGRect]
        switch container.layout {
        case .tiles:     rects = tiles(kids, in: rect, orientation: container.orientation, gaps: gaps)
        case .accordion:
            let mru = container.mruChild.flatMap { m in kids.firstIndex { $0 === m } } ?? 0
            rects = accordion(count: kids.count, focused: mru, in: rect,
                              orientation: container.orientation, padding: padding)
        }

        for (child, r) in zip(kids, rects) {
            let snapped = r.integral
            if let w = child as? WindowNode {
                out.append((w, snapped))
            } else if let c = child as? TilingContainer {
                layout(c, in: snapped, gaps: gaps, padding: padding, into: &out)
            }
        }
    }

    private static func tiles(_ kids: [TreeNode], in rect: CGRect, orientation: Orientation, gaps: ResolvedGaps) -> [CGRect] {
        let horizontal = orientation == .horizontal
        let gap = horizontal ? gaps.innerHorizontal : gaps.innerVertical
        let total = horizontal ? rect.width : rect.height
        let available = max(0, total - gap * CGFloat(kids.count - 1))
        let weightSum = max(kids.map(\.weight).reduce(0, +), 0.0001)

        var rects: [CGRect] = []
        var cursor = horizontal ? rect.minX : rect.minY
        for kid in kids {
            let length = available * kid.weight / weightSum
            if horizontal {
                rects.append(CGRect(x: cursor, y: rect.minY, width: length, height: rect.height))
            } else {
                rects.append(CGRect(x: rect.minX, y: cursor, width: rect.width, height: length))
            }
            cursor += length + gap
        }
        return rects
    }

    /// AeroSpace's accordion: the focused child fills the rect minus `padding` on each side; its
    /// immediate neighbours are pushed `padding` past it so their edges peek out on either side;
    /// everything further away sits hidden directly behind the focused one. The first/last child
    /// don't need room on their outer side.
    private static func accordion(count: Int, focused: Int, in rect: CGRect,
                                  orientation: Orientation, padding: CGFloat) -> [CGRect] {
        (0..<count).map { i in
            var lead: CGFloat = 0
            var trail: CGFloat = 0
            if count == 1 {
                (lead, trail) = (0, 0)
            } else if i == focused - 1 {
                (lead, trail) = (0, 2 * padding)        // peeks out on the leading side
            } else if i == focused + 1 {
                (lead, trail) = (2 * padding, 0)        // peeks out on the trailing side
            } else if i == 0 {
                (lead, trail) = (0, padding)
            } else if i == count - 1 {
                (lead, trail) = (padding, 0)
            } else {
                (lead, trail) = (padding, padding)
            }
            if orientation == .horizontal {
                return CGRect(x: rect.minX + lead, y: rect.minY,
                              width: max(1, rect.width - lead - trail), height: rect.height)
            } else {
                return CGRect(x: rect.minX, y: rect.minY + lead,
                              width: rect.width, height: max(1, rect.height - lead - trail))
            }
        }
    }
}
