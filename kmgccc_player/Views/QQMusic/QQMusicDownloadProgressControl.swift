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

    /// What the box shows: **the user's queue**, every track of the selection,
    /// paired with the engine's live state where the engine has one.
    ///
    /// Not the engine's task table — that only holds what is in flight, so a
    /// hundred-song selection looked like a two-item list. The queue is the app's
    /// own record from the moment each track was handed over.
    private var items: [QQMusicUserDownloadProgress.Item] {
        coordinator.userDownloadProgress?.items ?? []
    }

    /// The engine's view of a queued track, by gid.
    private func task(for item: QQMusicUserDownloadProgress.Item) -> QQMusicAria2Task? {
        guard let gid = item.gid else { return nil }
        return coordinator.aria2Tasks.first { $0.gid == gid }
    }

    private var isVisible: Bool { !items.isEmpty }

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
                Image(systemName: hasPaused ? "pause.circle" : "arrow.down.circle")
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

    /// Finished over the whole selection: "3/100".
    private var countText: String {
        let done = items.filter(\.isFinished).count
        return "\(done)/\(items.count)"
    }

    private var overallFraction: Double {
        guard !items.isEmpty else { return 0 }
        let done = Double(items.filter(\.isFinished).count)
        let partial = items.reduce(0.0) { total, item in
            guard !item.isFinished else { return total }
            return total + (task(for: item)?.fraction ?? 0)
        }
        return min(1, (done + partial) / Double(items.count))
    }

    private var hasPaused: Bool {
        items.contains { task(for: $0)?.isPaused == true }
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
            .disabled(items.allSatisfy(\.isFinished))
            .controlSize(.small)

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        itemRow(item)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 280)
        }
        .padding(14)
        .frame(width: 380)
    }

    private func itemRow(_ item: QQMusicUserDownloadProgress.Item) -> some View {
        let engineTask = task(for: item)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // The song, the way every other list in the app names it…
                Text(item.displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // …and the file it becomes, which is what a person looking for
                // the download on disk needs.
                HStack(spacing: 6) {
                    if let fileName = item.fileName {
                        Text(fileName)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(statusText(item, engineTask))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let engineTask, !item.isFinished, engineTask.isActive, engineTask.total ?? 0 > 0 {
                        ProgressView(value: engineTask.fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 70)
                            .tint(themeStore.accentColor)
                    }
                }
            }
            Spacer(minLength: 8)
            if let outcome = item.outcome {
                Text(outcome)
                    .font(.system(size: 11))
                    .foregroundStyle(outcome == "失败" || outcome == "导入失败" ? Color.red : Color.secondary)
            } else if let engineTask, engineTask.isFailed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .help(engineTask.error ?? "")
            } else {
                if engineTask?.isPaused == true {
                    Button { Task { await coordinator.resumeAria2Tasks(gid: item.gid) } } label: {
                        Image(systemName: "play.circle")
                    }
                    .help("继续")
                } else {
                    Button { Task { await coordinator.pauseAria2Tasks(gid: item.gid) } } label: {
                        Image(systemName: "pause.circle")
                    }
                    .help("暂停")
                    .disabled(item.gid == nil)
                }
                Button { Task { await coordinator.cancelUserDownloadItem(songMid: item.songMid) } } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("取消并删除临时文件")
            }
        }
        .buttonStyle(.plain)
    }

    private func statusText(
        _ item: QQMusicUserDownloadProgress.Item,
        _ task: QQMusicAria2Task?
    ) -> String {
        guard let task else { return item.gid == nil ? "等待中" : "排队中" }
        return statusText(task)
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
