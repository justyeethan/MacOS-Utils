import AppKit
import ApplicationServices

/// AeroSpace command semantics. Every command mutates the tree, then layout runs once.
extension WindowManager {

    func execute(_ commands: [WMCommand]) {
        guard isRunning else { return }
        for command in commands { run(command) }
        applyLayout()
        notifyWorkspaceChangeIfNeeded()
        publishStatus()
    }

    func run(_ command: WMCommand) {
        switch command {
        case .focus(let d):                 focusDirection(d)
        case .move(let d):                  moveDirection(d)
        case .joinWith(let d):              joinWith(d)
        case .layout(let args):             layoutCommand(args)
        case .resize(let dim, let amount, let relative): resize(dim, amount: amount, relative: relative)
        case .balanceSizes:                 balanceSizes()
        case .fullscreen:                   toggleFullscreen()
        case .workspace(let name):          switchToWorkspace(name)
        case .workspaceNext:                cycleWorkspace(by: 1)
        case .workspacePrev:                cycleWorkspace(by: -1)
        case .workspaceBackAndForth:        if let p = previousWorkspace { switchToWorkspace(p) }
        case .moveNodeToWorkspace(let name): moveFocusedWindow(toWorkspace: name)
        case .mode(let name):               hotkeys.setMode(name)
        case .reloadConfig:                 reloadConfig()
        case .flattenWorkspaceTree:         focusedWorkspace.flattenTree()
        case .closeAllWindowsButCurrent:
            let keep = focusedWindow
            for w in focusedWorkspace.allWindows where w !== keep { close(w) }
        case .close:                        if let w = focusedWindow { close(w) }
        case .volume(let action):           Exec.volume(action)
        case .execAndForget(let cmd):       Exec.shell(cmd)
        case .moveMouseMonitorLazyCenter:   moveMouseToFocusedMonitor()
        case .moveMouseWindowLazyCenter:    moveMouseToFocusedWindow()
        }
    }

    // MARK: - focus <direction>

    /// i3 navigation: climb until an ancestor with the matching orientation has a neighbour on
    /// that side, then descend into it. At the edge of the workspace, cross to the next monitor.
    private func focusDirection(_ d: Direction) {
        guard let current = focusedWindow, let ws = current.workspace else {
            if let w = focusedWorkspace.lastFocused ?? focusedWorkspace.allWindows.first { focus(w) }
            return
        }

        if current.isFloating {
            if let target = nearestWindow(from: current, direction: d, in: ws) { focus(target) }
            return
        }

        var node: TreeNode = current
        while let parent = node.parent {
            if parent.orientation == d.orientation, let i = node.indexInParent {
                let j = i + d.step
                if parent.children.indices.contains(j), let target = descend(parent.children[j], entering: d) {
                    focus(target)
                    return
                }
            }
            node = parent
        }

        // Edge reached: next monitor in that direction.
        guard let here = homeMonitor(of: ws), let next = here.neighbor(d, in: monitors),
              let name = visible[next.id] else { return }
        let target = workspace(named: name)
        if let w = descend(target.root, entering: d) ?? target.floating.first {
            focus(w)
        } else {
            setFocusedMonitor(next.id)
        }
    }

    /// Picks the window to land on when entering `node` while moving in `d`: the child on the
    /// near edge for containers along the same axis, otherwise the most recently focused child.
    func descend(_ node: TreeNode, entering d: Direction) -> WindowNode? {
        var n: TreeNode = node
        while let c = n as? TilingContainer {
            guard let first = c.children.first, let last = c.children.last else { return nil }
            if c.orientation == d.orientation {
                n = d.isPositive ? first : last
            } else if let mru = c.mruChild, c.children.contains(where: { $0 === mru }) {
                n = mru
            } else {
                n = first
            }
        }
        return n as? WindowNode
    }

    /// Geometric fallback for floating windows: nearest window whose centre lies in direction `d`.
    private func nearestWindow(from current: WindowNode, direction d: Direction, in ws: Workspace) -> WindowNode? {
        guard let origin = AX.frame(current.element) else { return nil }
        let c0 = CGPoint(x: origin.midX, y: origin.midY)
        var best: (WindowNode, CGFloat)?
        for w in ws.allWindows where w !== current {
            guard let f = AX.frame(w.element) else { continue }
            let c = CGPoint(x: f.midX, y: f.midY)
            let inDirection: Bool
            switch d {
            case .left:  inDirection = c.x < c0.x - 1
            case .right: inDirection = c.x > c0.x + 1
            case .up:    inDirection = c.y < c0.y - 1
            case .down:  inDirection = c.y > c0.y + 1
            }
            guard inDirection else { continue }
            let dist = hypot(c.x - c0.x, c.y - c0.y)
            if best == nil || dist < best!.1 { best = (w, dist) }
        }
        return best?.0
    }

    // MARK: - move <direction>

    /// AeroSpace/i3 move: swap with a window neighbour, enter a container neighbour, or climb out
    /// to the nearest ancestor along that axis. At the workspace edge, move to the next monitor.
    private func moveDirection(_ d: Direction) {
        guard let w = focusedWindow, !w.isFloating, let ws = w.workspace,
              let parent = w.parent, let i = w.indexInParent else { return }

        if parent.orientation == d.orientation {
            let j = i + d.step
            if parent.children.indices.contains(j) {
                if let container = parent.children[j] as? TilingContainer {
                    let index: Int
                    if container.orientation == d.orientation {
                        index = d.isPositive ? 0 : container.children.count
                    } else {
                        index = container.mruChild?.indexInParent.map { $0 + 1 } ?? container.children.count
                    }
                    container.insert(w, at: index)
                } else {
                    parent.children.swapAt(i, j)
                }
                ws.noteFocused(w)
                return
            }
        }

        // Climb to the nearest ancestor whose orientation matches.
        var child: TreeNode = parent
        var ancestor = parent.parent
        while let a = ancestor, a.orientation != d.orientation {
            child = a
            ancestor = a.parent
        }

        if let a = ancestor, let ci = child.indexInParent {
            a.insert(w, at: d.isPositive ? ci + 1 : ci)
            ws.noteFocused(w)
        } else if ws.root.orientation != d.orientation {
            wrapRoot(of: ws, adding: w, direction: d)
            ws.noteFocused(w)
        } else if let here = homeMonitor(of: ws), let next = here.neighbor(d, in: monitors),
                  let name = visible[next.id] {
            let target = workspace(named: name)
            target.add(w, floating: false)
            if d.isPositive, target.root.orientation == d.orientation {
                target.root.insert(w, at: 0)          // enter from the near edge
            }
            noteFocus(w)
        }
    }

    /// Root has the wrong orientation for this move: make a new root along `d` holding the old
    /// root's contents and the moved window.
    private func wrapRoot(of ws: Workspace, adding w: WindowNode, direction d: Direction) {
        w.removeFromParent()
        let root = ws.root
        let inner = TilingContainer(orientation: root.orientation, layout: root.layout)
        for kid in root.children {
            kid.parent = inner
            inner.children.append(kid)
        }
        inner.mruChild = root.mruChild
        root.children = []
        root.orientation = d.orientation
        root.layout = .tiles
        inner.parent = root
        inner.weight = 1
        w.parent = root
        w.weight = 1
        root.children = d.isPositive ? [inner, w] : [w, inner]
    }

    // MARK: - join-with <direction>

    /// Wraps the focused window and its neighbour in `d` into a new container of the opposite
    /// orientation.
    private func joinWith(_ d: Direction) {
        guard let w = focusedWindow, !w.isFloating, let ws = w.workspace,
              let parent = w.parent, parent.orientation == d.orientation,
              let i = w.indexInParent, parent.children.indices.contains(i + d.step) else { return }
        let neighbour = parent.children[i + d.step]
        let container = TilingContainer(orientation: parent.orientation.opposite, layout: .tiles)
        w.removeFromParent()
        parent.replace(neighbour, with: container)
        if d.isPositive {
            container.append(w); container.append(neighbour)
        } else {
            container.append(neighbour); container.append(w)
        }
        ws.noteFocused(w)
    }

    // MARK: - layout <args…>

    /// AeroSpace semantics: apply the first argument that doesn't already describe the window,
    /// so `layout tiles horizontal vertical` toggles orientation and `layout floating tiles`
    /// toggles floating.
    private func layoutCommand(_ args: [LayoutArg]) {
        guard let w = focusedWindow else { return }

        func describes(_ a: LayoutArg) -> Bool {
            let p = w.parent
            switch a {
            case .floating:   return w.isFloating
            case .tiling:     return !w.isFloating
            case .tiles:      return !w.isFloating && p?.layout == .tiles
            case .accordion:  return !w.isFloating && p?.layout == .accordion
            case .horizontal: return !w.isFloating && p?.orientation == .horizontal
            case .vertical:   return !w.isFloating && p?.orientation == .vertical
            case .hTiles:     return describes(.tiles) && describes(.horizontal)
            case .vTiles:     return describes(.tiles) && describes(.vertical)
            case .hAccordion: return describes(.accordion) && describes(.horizontal)
            case .vAccordion: return describes(.accordion) && describes(.vertical)
            }
        }
        guard let arg = args.first(where: { !describes($0) }) else { return }

        switch arg {
        case .floating: makeFloating(w); return
        case .tiling:   makeTiling(w); return
        default: break
        }
        if w.isFloating { makeTiling(w) }
        guard let parent = w.parent else { return }

        switch arg {
        case .tiles:      parent.layout = .tiles
        case .accordion:  parent.layout = .accordion
        case .horizontal: setOrientation(parent, .horizontal)
        case .vertical:   setOrientation(parent, .vertical)
        case .hTiles:     parent.layout = .tiles;     setOrientation(parent, .horizontal)
        case .vTiles:     parent.layout = .tiles;     setOrientation(parent, .vertical)
        case .hAccordion: parent.layout = .accordion; setOrientation(parent, .horizontal)
        case .vAccordion: parent.layout = .accordion; setOrientation(parent, .vertical)
        case .floating, .tiling: break
        }
    }

    /// Changing a nested container to its parent's orientation would just be undone by the
    /// opposite-orientation normalization, so merge it into the parent instead (same result
    /// on screen as i3).
    private func setOrientation(_ c: TilingContainer, _ o: Orientation) {
        c.orientation = o
        guard config.oppositeOrientationForNested, let gp = c.parent, gp.orientation == o,
              let index = c.indexInParent else { return }
        let kids = c.children
        let share = c.weight / max(kids.map(\.weight).reduce(0, +), 0.0001)
        c.removeFromParent()
        for (k, kid) in kids.enumerated() {
            kid.parent = gp
            kid.weight *= share
            gp.children.insert(kid, at: index + k)
        }
        c.children = []
    }

    private func makeFloating(_ w: WindowNode) {
        guard let ws = w.workspace else { return }
        let frame = AX.frame(w.element)
        ws.add(w, floating: true)
        w.floatingFrame = frame
        w.lastAppliedFrame = nil
        ws.lastFocused = w
    }

    private func makeTiling(_ w: WindowNode) {
        guard let ws = w.workspace else { return }
        let anchor = ws.tiledWindows.contains { $0 === ws.lastFocused } ? ws.lastFocused : nil
        ws.add(w, floating: false, after: anchor)
        ws.noteFocused(w)
    }

    // MARK: - resize / balance / fullscreen

    /// `resize smart ±N` grows or shrinks along the parent's axis; `width`/`height` find the
    /// nearest ancestor along that axis. Implemented by re-weighting so siblings keep their
    /// relative proportions.
    private func resize(_ dim: ResizeDimension, amount: CGFloat, relative: Bool) {
        guard let w = focusedWindow, !w.isFloating else { return }

        var node: TreeNode = w
        if dim != .smart {
            let axis: Orientation = dim == .width ? .horizontal : .vertical
            while let p = node.parent, p.orientation != axis { node = p }
        }
        guard let c = node.parent, c.children.count > 1 else { return }

        let length = c.orientation == .horizontal ? c.lastRect.width : c.lastRect.height
        guard length > 0 else { return }
        let total = c.children.map(\.weight).reduce(0, +)
        let currentPx = node.weight / total * length
        let minPx: CGFloat = 50
        let maxPx = length - minPx * CGFloat(c.children.count - 1)
        let targetPx = min(max(relative ? currentPx + amount : amount, minPx), maxPx)
        let fraction = targetPx / length
        let others = total - node.weight
        guard fraction < 1, others > 0 else { return }
        node.weight = fraction / (1 - fraction) * others
    }

    private func balanceSizes() {
        func reset(_ n: TreeNode) {
            n.weight = 1
            if let c = n as? TilingContainer { c.children.forEach(reset) }
        }
        reset(focusedWorkspace.root)
    }

    private func toggleFullscreen() {
        guard let w = focusedWindow, !w.isFloating else { return }
        w.isFullscreen.toggle()
        w.lastAppliedFrame = nil
        AX.perform(w.element, "AXRaise")
    }

    // MARK: - Workspaces

    /// `workspace N`: if it's on another monitor, focus that monitor; otherwise show it on the
    /// focused monitor. The old workspace's windows get parked by the layout pass.
    func switchToWorkspace(_ name: String) {
        let target = workspace(named: name)
        let current = focusedWorkspace
        guard target !== current else { return }
        previousWorkspace = current.name
        suppressFocusSync()   // the old app still claims focus for a moment; don't bounce back

        if let mid = monitorID(showing: target) {
            setFocusedMonitor(mid)
        } else if let mid = focusedMonitor?.id {
            show(target, on: mid)
        }
        applyLayout()

        if let w = target.lastFocused ?? target.tiledWindows.first ?? target.floating.first {
            focus(w)
        } else {
            focusedWindowID = nil
            updateBorder()
        }
    }

    private func cycleWorkspace(by step: Int) {
        let names = WindowManager.sortNames(Array(Set(
            workspaces.values.filter { !$0.isEmpty }.map(\.name) + visible.values)))
        guard let i = names.firstIndex(of: focusedWorkspace.name), !names.isEmpty else { return }
        switchToWorkspace(names[(i + step + names.count) % names.count])
    }

    /// `move-node-to-workspace N`: the window goes; focus stays on this workspace and moves to
    /// the window's neighbour.
    private func moveFocusedWindow(toWorkspace name: String) {
        guard let w = focusedWindow, let from = w.workspace else { return }
        let target = workspace(named: name)
        guard target !== from else { return }

        let next = neighbourForFocus(after: w, in: from)
        suppressFocusSync()
        if w.isFloating { w.floatingFrame = AX.frame(w.element) }
        target.add(w, floating: w.isFloating, after: target.lastFocused)
        if target.lastFocused == nil { target.lastFocused = w }
        w.lastAppliedFrame = nil

        applyLayout()
        if let next { focus(next) } else { focusedWindowID = nil }
    }

    private func neighbourForFocus(after w: WindowNode, in ws: Workspace) -> WindowNode? {
        if let p = w.parent, let i = w.indexInParent {
            let candidates = [i + 1, i - 1].filter { p.children.indices.contains($0) }
            for j in candidates {
                if let target = descend(p.children[j], entering: j > i ? .right : .left) { return target }
            }
        }
        return ws.allWindows.first { $0 !== w }
    }

    // MARK: - Misc

    private func close(_ w: WindowNode) {
        if let button = AX.element(w.element, "AXCloseButton") {
            AX.perform(button, "AXPress")
        }
    }

    private func mouseLocation() -> CGPoint? {
        CGEvent(source: nil)?.location   // already top-left global coordinates, same as AX
    }

    private func moveMouseToFocusedMonitor() {
        guard let m = focusedMonitor, let p = mouseLocation(), !m.frame.contains(p) else { return }
        CGWarpMouseCursorPosition(m.center)
    }

    private func moveMouseToFocusedWindow() {
        guard let w = focusedWindow, let f = AX.frame(w.element), let p = mouseLocation(),
              !f.contains(p) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: f.midY))
    }
}
