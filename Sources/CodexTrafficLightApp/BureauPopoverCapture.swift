import AppKit
import CodexTrafficLightCore
import SwiftUI

@MainActor
enum BureauPopoverCapture {
    static func writePreview(to url: URL) -> Bool {
        let model = BureauPopoverModel()
        model.currentUserID = "zlu"
        model.websiteURL = URL(string: "https://c.wanhe.cn")
        model.syncDetail = "刚刚同步"

        let previewState = ProcessInfo.processInfo.environment["CODEX_LIGHT_CAPTURE_BUREAU_STATE"]
        if previewState == "loading" {
            model.snapshot = nil
            model.syncDetail = "正在读取创新局项目…"
        } else if previewState == "empty" {
            model.snapshot = BureauSnapshot(
                updatedAt: "2026-09-19",
                stages: [],
                members: [
                    BureauMember(id: "zlu", name: "张璐", avatar: "/avatars/58.png"),
                    BureauMember(id: "liguoqing", name: "李国庆", avatar: "/avatars/168.png"),
                    BureauMember(id: "qiaoyue", name: "乔月", avatar: "/avatars/201.png"),
                ]
            )
        } else {
            model.snapshot = BureauSnapshot(
                updatedAt: "2026-09-19",
                stages: [],
                members: [
                    BureauMember(
                        id: "zlu", name: "张璐", avatar: "/avatars/58.png",
                        projects: [
                            BureauProject(
                                id: "p1", name: "Boss 直聘智能体", client: "鲁信机械",
                                summary: "帮 HR 自动看 Boss 直聘上的简历：按岗位要求打分排序，合适的直接发打招呼话术，HR 每天只看筛完的十几个人。",
                                progressNote: "打分和自动打招呼已经能跑通，正在接客户自己的人才库。",
                                nextStep: "下周去客户那边现场跑一天。",
                                stage: "building", stageLabel: "正在做", percent: 65
                            ),
                            BureauProject(
                                id: "p2", name: "客户回访助手",
                                summary: "把销售的通话记录整理成回访纪要。",
                                stage: "planning", stageLabel: "刚立项", percent: 10
                            ),
                        ],
                        activeCount: 2, onlineCount: 0
                    ),
                    BureauMember(
                        id: "liguoqing", name: "李国庆", avatar: "/avatars/168.png",
                        projects: [
                            BureauProject(
                                id: "p3", name: "设计师智能体", client: "青岛家居",
                                summary: "输入户型和客户偏好，自动出三套配色和软装方案图。",
                                stage: "online", stageLabel: "已上线", percent: 100
                            ),
                            BureauProject(
                                id: "p4", name: "报价单核对", client: "青岛家居",
                                summary: "下单前自动核对报价单，有问题直接标红提醒。",
                                stage: "piloting", stageLabel: "客户试用", percent: 80
                            ),
                        ],
                        activeCount: 1, onlineCount: 1
                    ),
                    BureauMember(
                        id: "qiaoyue", name: "乔月", avatar: "/avatars/201.png",
                        projects: [
                            BureauProject(
                                id: "p5", name: "合同审查智能体", client: "万合法务",
                                summary: "合同上传后自动挑出风险条款，法务只看标红的部分。",
                                stage: "building", stageLabel: "正在做", percent: 45
                            ),
                            BureauProject(
                                id: "p6", name: "招投标信息抓取",
                                summary: "每天自动扫几个招标网站，把有戏的项目推到群里。",
                                stage: "paused", stageLabel: "暂停中", percent: 35
                            ),
                        ],
                        activeCount: 1, onlineCount: 0
                    ),
                ]
            )
        }

        let view = NSHostingView(rootView: BureauPopoverView(model: model, openBureauPage: {}))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
