import AppKit
import CodexTrafficLightCore
import SwiftUI

@MainActor
final class BureauPopoverModel: ObservableObject {
    @Published var snapshot: BureauSnapshot?
    @Published var syncDetail: String = "正在读取创新局项目…"
    @Published var websiteURL: URL?
    @Published var currentUserID: String = ""
}

struct BureauPopoverView: View {
    @ObservedObject var model: BureauPopoverModel
    let openBureauPage: () -> Void

    @State private var openProjectID: String?

    private let canvas = Color(red: 0.975, green: 0.965, blue: 0.945)
    private let card = Color(red: 1.0, green: 0.995, blue: 0.985)
    private let ink = Color(red: 0.12, green: 0.115, blue: 0.105)
    private let muted = Color(red: 0.49, green: 0.47, blue: 0.43)
    private let line = Color(red: 0.88, green: 0.85, blue: 0.79)
    private let green = Color(red: 0.18, green: 0.54, blue: 0.32)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let snapshot = model.snapshot {
                        if snapshot.projectCount == 0 {
                            emptyCard
                        } else {
                            ForEach(snapshot.members) { member in
                                memberCard(member)
                            }
                        }
                    } else {
                        loadingCard
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            footer
        }
        .frame(width: 420, height: 600)
        .background(canvas)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(green, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.snapshot?.name ?? InnovationBureau.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Text(model.snapshot?.tagline ?? InnovationBureau.tagline)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(muted)
            }
            Spacer()
            if let snapshot = model.snapshot, snapshot.projectCount > 0 {
                Text("\(snapshot.projectCount) 个项目")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(green.opacity(0.09), in: Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(card)
        .overlay(alignment: .bottom) { line.frame(height: 1) }
    }

    private var loadingCard: some View {
        Text(model.syncDetail)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Text("还没有人填项目")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(ink)
            Text("打开创新局网页，把正在做的项目和进度写进来。")
                .font(.system(size: 12))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 20)
        .background(card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func memberCard(_ member: BureauMember) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                avatar(for: member)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(ink)
                        if member.id == model.currentUserID {
                            Text("我")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(green.opacity(0.11), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                    Text(member.projects.isEmpty
                         ? "还没有填项目"
                         : "\(member.projects.count) 个项目 · 推进中 \(member.activeCount) 个 · 已上线 \(member.onlineCount) 个")
                        .font(.system(size: 11))
                        .foregroundStyle(muted)
                }
                Spacer()
            }

            ForEach(member.projects) { project in
                projectRow(project)
            }
        }
        .padding(14)
        .background(card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(line.opacity(0.85), lineWidth: 1)
        }
    }

    private func projectRow(_ project: BureauProject) -> some View {
        let isOpen = openProjectID == project.id
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                openProjectID = isOpen ? nil : project.id
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                        Text(projectSubtitle(project))
                            .font(.system(size: 10.5))
                            .foregroundStyle(muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(project.stageLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(stageColor(project.stage))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(stageColor(project.stage).opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(muted.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(line.opacity(0.7))
                    Capsule()
                        .fill(green)
                        .frame(width: proxy.size.width * CGFloat(max(0, min(100, project.percent))) / 100)
                }
            }
            .frame(height: 3)
            .accessibilityLabel("进度 \(project.percent)%")

            if isOpen {
                VStack(alignment: .leading, spacing: 9) {
                    detailBlock(title: "这个项目是干什么的", text: project.summary)
                    if !project.progressNote.isEmpty {
                        detailBlock(title: "现在做到哪了", text: project.progressNote)
                    }
                    if !project.nextStep.isEmpty {
                        detailBlock(title: "下一步", text: project.nextStep)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(canvas.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(muted.opacity(0.85))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: openBureauPage) {
                Label("打开创新局网页", systemImage: "safari")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(green)
                    .background(green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(green.opacity(0.18), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .disabled(model.websiteURL == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(card)
        .overlay(alignment: .top) { line.frame(height: 1) }
    }

    private func projectSubtitle(_ project: BureauProject) -> String {
        let parts = [project.client.isEmpty ? nil : project.client, "进度 \(project.percent)%"].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    private func stageColor(_ stage: String) -> Color {
        switch stage {
        case "building": return Color(red: 0.81, green: 0.40, blue: 0.18)
        case "piloting": return Color(red: 0.42, green: 0.35, blue: 0.65)
        case "online": return green
        case "paused": return Color(red: 0.54, green: 0.52, blue: 0.47)
        default: return Color(red: 0.39, green: 0.45, blue: 0.48)
        }
    }

    private func avatar(for member: BureauMember) -> some View {
        Group {
            if let url = avatarURL(member) {
                PersistentAvatarImage(url: url, fallbackText: String(member.name.prefix(1)))
                    .id(url.absoluteString)
                    .foregroundStyle(ink)
            } else {
                Text(String(member.name.prefix(1)))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ink)
            }
        }
        .frame(width: 34, height: 34)
        .background(line.opacity(0.45))
        .clipShape(Circle())
    }

    private func avatarURL(_ member: BureauMember) -> URL? {
        guard !member.avatar.isEmpty else { return nil }
        if let absolute = URL(string: member.avatar), absolute.scheme != nil { return absolute }
        guard let websiteURL = model.websiteURL else { return nil }
        return URL(string: member.avatar, relativeTo: websiteURL)?.absoluteURL
    }
}
