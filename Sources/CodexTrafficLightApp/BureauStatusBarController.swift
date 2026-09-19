import Cocoa
import CodexTrafficLightCore
import SwiftUI

/// 菜单栏上单独的「创新局」入口，只装给张璐、李国庆、乔月三个人。
@MainActor
final class BureauStatusBarController {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model = BureauPopoverModel()
    private var bureauPageURL: URL?
    var onPopoverOpen: (() -> Void)?

    init(currentUserID: String) {
        model.currentUserID = currentUserID
        item.button?.title = InnovationBureau.name
        item.button?.toolTip = "\(InnovationBureau.name)：\(InnovationBureau.tagline)"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 600)
        let hostingController = NSHostingController(
            rootView: BureauPopoverView(model: model, openBureauPage: { [weak self] in self?.openBureauPage() })
        )
        hostingController.view.appearance = NSAppearance(named: .aqua)
        popover.contentViewController = hostingController
    }

    func apply(snapshot: BureauSnapshot?, websiteURL: URL?, bureauPageURL: URL?, syncDetail: String? = nil) {
        if let snapshot {
            model.snapshot = snapshot
            item.button?.toolTip = tooltip(for: snapshot)
        }
        if let websiteURL { model.websiteURL = websiteURL }
        if let bureauPageURL { self.bureauPageURL = bureauPageURL }
        if let syncDetail { model.syncDetail = syncDetail }
    }

    func setSyncDetail(_ detail: String) {
        model.syncDetail = detail
    }

    private func tooltip(for snapshot: BureauSnapshot) -> String {
        guard snapshot.projectCount > 0 else {
            return "\(InnovationBureau.name)：还没有人填项目"
        }
        let lines = snapshot.members
            .filter { !$0.projects.isEmpty }
            .map { "\($0.name)：\($0.projects.map(\.name).joined(separator: "、"))" }
        return (["\(InnovationBureau.name) \(snapshot.projectCount) 个项目"] + lines).joined(separator: "\n")
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            onPopoverOpen?()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func openBureauPage() {
        guard let bureauPageURL else { return }
        NSWorkspace.shared.open(bureauPageURL)
        popover.performClose(nil)
    }
}
