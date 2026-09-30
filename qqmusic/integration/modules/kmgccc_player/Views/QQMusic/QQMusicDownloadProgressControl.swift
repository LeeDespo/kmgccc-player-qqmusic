//
//  QQMusicDownloadProgressControl.swift
//  kmgccc_player
//
//  The download progress box, as its own window-toolbar item.
//
//  Separate from the download control beside it, which stays a download button:
//  the user asked for the box to come and go on its own rather than for the
//  button to change into one. It appears when the engine has work queued and
//  disappears when it does not.
//
//  What it shows is read from the engine, not from the app's own bookkeeping —
//  the engine knows about every task (including the ones a restart or another
//  caller produced), and pause/resume/cancel have to be its operations, not
//  something the app pretends to do. Clicking opens the list, where each task can
//  be paused, resumed or cancelled on its own, or all of them at once.
//
//  The surface is the app's own toolbar material — a neutral capsule fill, the
//  toolbar's height, no second layer of glass — so it sits beside the reload and
//  download buttons as one of them rather than as a banner.
//

import AppKit
import SwiftUI

struct QQMusicDownloadProgressControl: View {

    @Environment(QQMusicOnlineCoordinator.self) private var coordinator
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    /// Told whenever the box should be on screen, so the toolbar item can hide
    /// itself instead of leaving a gap where it would have been.
    var onVisibilityChange: ((Bool) -> Void)?

    @State private var isShowingList = false

    /// Tasks that are worth showing: anything not finished. A completed task stays
    /// in the engine's list until it is removed, and a box that counted those
    /// would never go away.
    private var tasks: [QQMusicAria2Task] {
        coordinator.aria2Tasks
    }

    private var liveTasks: [QQMusicAria2Task] {
        tasks.filter { !$0.isFinished && !$0.isFailed }
    }

    private var isVisible: Bool { !tasks.isEmpty }

    var body: some View {
        Group {
            if isVisible {
                box
            } else {
                // Nothing at all while idle; the item itself is hidden by the
                // closure below, so this only covers the frame before that lands.
                Color.clear.frame(width: 0, height: GlassStyleTokens.headerControlHeight)
            }
        }
        .onAppear {
            coordinator.refreshAria2Tasks()
            onVisibilityChange?(isVisible)
        }
        .onChange(of: isVisible) { _, visible in
            onVisibilityChange?(visible)
        }
        // Polled rather than pushed: the engine is a separate process with its own
        // progress, and a 1s cadence is what makes the bar move without asking the
        // component for a stream of notifications nobody else needs.
        .task {
            while !Task.isCancelled {
                coordinator.refreshAria2Tasks()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var box: some View {
        Button {
            isShowingList.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: liveTasks.contains(where: \.isPaused) ? "pause.circle" : "arrow.down.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                ProgressView(value: overallFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 44)
                    .tint(themeStore.accentColor)
                Text(countText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 10)
            .frame(height: GlassStyleTokens.headerControlHeight)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.045))
                    .overlay(
                        Capsule().strokeBorder(
                            Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.09),
                            lineWidth: 0.5
                        )
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("正在下载 \(countText) · 点击查看列表")
        .accessibilityLabel(Text("下载任务 \(countText)"))
        .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
            taskList
        }
    }

    /// Finished over all: "3/12".
    private var countText: String {
        let done = tasks.filter { $0.isFinished }.count
        return "\(done)/\(tasks.count)"
    }

    private var overallFraction: Double {
        guard !tasks.isEmpty else { return 0 }
        let done = Double(tasks.filter { $0.isFinished }.count)
        let partial = liveTasks.reduce(0.0) { $0 + $1.fraction }
        return min(1, (done + partial) / Double(tasks.count))
    }

    // MARK: - The list

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("下载任务")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 12)
                Text(countText)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("全部暂停") { Task { await coordinator.pauseAria2Tasks() } }
                Button("全部恢复") { Task { await coordinator.resumeAria2Tasks() } }
                Button("全部取消") { Task { await coordinator.cancelAria2Tasks() } }
                Spacer(minLength: 0)
            }
            .disabled(liveTasks.isEmpty)
            .controlSize(.small)

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tasks) { task in
                        taskRow(task)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 280)
        }
        .padding(14)
        .frame(width: 380)
    }

    private func taskRow(_ task: QQMusicAria2Task) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.name?.isEmpty == false ? task.name! : task.gid)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(statusText(task))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if task.isActive || task.isPaused, task.total ?? 0 > 0 {
                        ProgressView(value: task.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                            .tint(themeStore.accentColor)
                    }
                }
            }
            Spacer(minLength: 8)
            if task.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if task.isFailed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .help(task.error ?? "")
            } else {
                if task.isPaused {
                    Button { Task { await coordinator.resumeAria2Tasks(gid: task.gid) } } label: {
                        Image(systemName: "play.circle")
                    }
                    .help("继续")
                } else {
                    Button { Task { await coordinator.pauseAria2Tasks(gid: task.gid) } } label: {
                        Image(systemName: "pause.circle")
                    }
                    .help("暂停")
                }
                Button { Task { await coordinator.cancelAria2Tasks(gid: task.gid) } } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("取消并删除临时文件")
            }
        }
        .buttonStyle(.plain)
    }

    private func statusText(_ task: QQMusicAria2Task) -> String {
        switch task.status {
        case "active":
            let speed = task.speed ?? 0
            return speed > 0
                ? ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
                : "下载中"
        case "waiting": return "等待中"
        case "paused": return "已暂停"
        case "complete": return "已完成"
        case "error": return "失败"
        case "removed": return "已取消"
        default: return task.status
        }
    }
}
