import ApplicationServices
import CoreGraphics

// i3/AeroSpace tree: each workspace has a root container; containers hold windows and other
// containers; windows are leaves. Floating windows live beside the tree, not in it.

class TreeNode {
    weak var parent: TilingContainer?
    /// Share of the parent's length along its orientation, relative to siblings.
    var weight: CGFloat = 1

    func removeFromParent() {
        guard let parent else { return }
        if let i = parent.children.firstIndex(where: { $0 === self }) {
            parent.children.remove(at: i)
        }
        if parent.mruChild === self { parent.mruChild = parent.children.last }
        self.parent = nil
    }

    /// Index within the parent's children.
    var indexInParent: Int? { parent?.children.firstIndex { $0 === self } }

    /// All windows in this subtree, in tree order.
    var windowsInSubtree: [WindowNode] {
        if let w = self as? WindowNode { return [w] }
        if let c = self as? TilingContainer { return c.children.flatMap(\.windowsInSubtree) }
        return []
    }
}

final class TilingContainer: TreeNode {
    var orientation: Orientation
    var layout: LayoutKind
    var children: [TreeNode] = []
    /// Most recently focused child: where focus lands when entering this container.
    weak var mruChild: TreeNode?
    /// Rect from the last layout pass, used by `resize`.
    var lastRect: CGRect = .zero

    init(orientation: Orientation, layout: LayoutKind) {
        self.orientation = orientation
        self.layout = layout
    }

    var isRoot: Bool { parent == nil }

    func insert(_ child: TreeNode, at index: Int) {
        child.removeFromParent()
        // New nodes get the average weight so they take a fair share.
        child.weight = children.isEmpty ? 1 : children.map(\.weight).reduce(0, +) / CGFloat(children.count)
        child.parent = self
        children.insert(child, at: max(0, min(index, children.count)))
    }

    func append(_ child: TreeNode) { insert(child, at: children.count) }

    /// Replace `old` (a direct child) with `new`, keeping position and weight.
    func replace(_ old: TreeNode, with new: TreeNode) {
        guard let i = children.firstIndex(where: { $0 === old }) else { return }
        new.removeFromParent()
        new.weight = old.weight
        new.parent = self
        old.parent = nil
        children[i] = new
        if mruChild === old { mruChild = new }
    }
}

final class WindowNode: TreeNode {
    let id: CGWindowID
    let watcher: AppWatcher
    let element: AXUIElement

    /// Workspace this window belongs to (tiled or floating).
    weak var workspace: Workspace?
    var isFloating = false
    var isFullscreen = false

    /// Last frame we wrote; lets us skip redundant AX writes and recognise our own move echoes.
    var lastAppliedFrame: CGRect?
    /// For floating windows: where to put it back when its workspace is shown again.
    var floatingFrame: CGRect?
    /// True while parked in the screen corner because its workspace isn't visible.
    var isParked = false

    init(id: CGWindowID, watcher: AppWatcher, element: AXUIElement) {
        self.id = id
        self.watcher = watcher
        self.element = element
    }

    var title: String { AX.string(element, "AXTitle") ?? "" }
}

final class Workspace {
    let name: String
    private(set) var root: TilingContainer
    var floating: [WindowNode] = []
    weak var lastFocused: WindowNode?
    /// Monitor this workspace is shown on, or was last shown on.
    var monitorID: CGDirectDisplayID?

    init(name: String, rootOrientation: Orientation, rootLayout: LayoutKind) {
        self.name = name
        self.root = TilingContainer(orientation: rootOrientation, layout: rootLayout)
    }

    var tiledWindows: [WindowNode] { root.windowsInSubtree }
    var allWindows: [WindowNode] { tiledWindows + floating }
    var isEmpty: Bool { root.children.isEmpty && floating.isEmpty }

    func add(_ window: WindowNode, floating isFloating: Bool, after anchor: WindowNode? = nil) {
        window.workspace?.detach(window)
        window.removeFromParent()
        window.workspace = self
        window.isFloating = isFloating
        if isFloating {
            floating.append(window)
        } else if let anchor, anchor.workspace === self, !anchor.isFloating,
                  let parent = anchor.parent, let i = anchor.indexInParent {
            parent.insert(window, at: i + 1)
        } else {
            root.append(window)
        }
    }

    /// Removes the window from this workspace (tree or floating list).
    func detach(_ window: WindowNode) {
        window.removeFromParent()
        floating.removeAll { $0 === window }
        if lastFocused === window { lastFocused = nil }
        if window.workspace === self { window.workspace = nil }
    }

    /// Records focus so re-entering containers returns to this window (i3 behaviour).
    func noteFocused(_ window: WindowNode) {
        lastFocused = window
        var node: TreeNode = window
        while let parent = node.parent {
            parent.mruChild = node
            node = parent
        }
    }

    // MARK: Normalization (AeroSpace's two rules)

    func normalize(flatten: Bool, oppositeOrientation: Bool) {
        // Two passes: flattening can lift a container next to a same-orientation sibling level,
        // which the second pass then fixes.
        normalize(root, flatten: flatten, oppositeOrientation: oppositeOrientation)
        normalize(root, flatten: flatten, oppositeOrientation: oppositeOrientation)

        // A root holding exactly one container adopts that container's children and layout.
        if flatten, root.children.count == 1, let only = root.children.first as? TilingContainer {
            root.orientation = only.orientation
            root.layout = only.layout
            let kids = only.children
            only.children = []
            root.children = []
            for k in kids { k.parent = root; root.children.append(k) }
            root.mruChild = only.mruChild
            if oppositeOrientation { normalize(root, flatten: flatten, oppositeOrientation: oppositeOrientation) }
        }
    }

    private func normalize(_ c: TilingContainer, flatten: Bool, oppositeOrientation: Bool) {
        for child in c.children {
            guard let sub = child as? TilingContainer else { continue }
            normalize(sub, flatten: flatten, oppositeOrientation: oppositeOrientation)
        }
        for child in c.children {
            guard let sub = child as? TilingContainer else { continue }
            if sub.children.isEmpty {
                sub.removeFromParent()
            } else if flatten, sub.children.count == 1, let only = sub.children.first {
                c.replace(sub, with: only)
            } else if oppositeOrientation, sub.orientation == c.orientation {
                sub.orientation = c.orientation.opposite
                // Its own child containers must flip too to stay alternating.
                normalize(sub, flatten: flatten, oppositeOrientation: oppositeOrientation)
            }
        }
    }

    /// `flatten-workspace-tree`: every tiled window becomes a direct child of the root.
    func flattenTree() {
        let wins = tiledWindows
        for w in wins { w.removeFromParent() }
        root.children = []
        for w in wins { root.append(w) }
    }
}
