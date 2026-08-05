import SwiftUI

/// Transport control. Bare until hovered; `tint` carries the button's state, `hover` fills behind.
private struct Tile: View {
    let symbol: String
    var tint: Color = .primary
    var hover: Color = .gray
    var size: CGFloat = 12
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(over ? hover.opacity(0.22) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
    }
}

/// One catalogue row: a star and a download toggle, both revealed on hover unless already set.
private struct Row: View {
    let entry: Entry
    let index: Int
    let playing: Bool
    let downloaded: Bool
    let playable: Bool
    let canStream: Bool
    let hasSource: Bool
    let progress: Double?
    let encoding: Bool
    let onPlay: () -> Void
    let onFavorite: () -> Void
    let onDownload: () -> Void
    let onRename: (String) -> Void
    @State private var over = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var spin: Double = -90

    /// Playable now, or fetchable. A row that is neither can never start, so it says so instead of
    /// swallowing the click.
    private var reachable: Bool { playable || (canStream && hasSource) }

    var body: some View {
        HStack(spacing: 7) {
            Text("\(index + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                .fixedSize()      // 153 entries means three digits, and the default width elides them

            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, has in if !has { commit() } }
            } else {
                Text(entry.name)
                    .font(.system(size: 12, weight: playing ? .medium : .regular))
                    .foregroundStyle(reachable ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // the star is always shown when set, so a filtered-down list still reads at a glance
            icon(entry.favorite ? "star.fill" : "star", entry.favorite ? .yellow : .secondary,
                 visible: entry.favorite || over, action: onFavorite)
            if let progress {
                ring(progress)
            } else if encoding {
                ring(nil).help("Encoding").onAppear { spin = 270 }
            } else {
                icon(downloaded ? "arrow.down.circle.fill" : "arrow.down.circle",
                     downloaded ? .accentColor : .secondary,
                     visible: downloaded || over, action: onDownload)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(playing ? Color.accentColor.opacity(0.20) : .clear))
        .contentShape(Rectangle())
        .onHover { over = $0 }
        .onTapGesture(count: 2) { draft = entry.name; editing = true; focused = true }
        .onTapGesture { if !editing, reachable { onPlay() } }
        .help(reachable ? "" : hasSource ? "Change streamMode in settings to stream this video"
                                         : "No download link and no local file")
    }

    private func commit() {
        guard editing else { return }
        editing = false
        onRename(draft)
    }

    /// Fills clockwise around the same 16pt slot the arrow occupies, so the row does not reflow
    /// when a fetch starts.
    /// nil fraction is the encode, which has no progress to report: a fixed arc that spins says
    /// work is happening without claiming to know how much is left.
    private func ring(_ fraction: Double?) -> some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 1.6)
            Circle().trim(from: 0, to: fraction.map { max(0.02, min(1, $0)) } ?? 0.28)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(fraction == nil ? spin : -90))
                .animation(fraction == nil ? .linear(duration: 1).repeatForever(autoreverses: false)
                                           : .easeOut(duration: 0.2), value: fraction == nil ? spin : fraction!)
        }
        .frame(width: 12, height: 12)
        .frame(width: 16, height: 16)
    }

    private func icon(_ symbol: String, _ tint: Color, visible: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint).frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}

struct ControlPanel: View {
    @ObservedObject var state: AppState
    @State private var scrubbing: Double?
    @State private var dragging: String?      // id of the row under the pointer
    @State private var origin: Int?           // where the drag began
    @State private var target: Int?           // where it would land
    @State private var held: CGFloat = 0
    private static let rowHeight: CGFloat = 26
    private static let listHeight: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // constant height on purpose: NSPopover re-anchors itself whenever the content size
            // changes, so a list that collapsed on an empty filter moved the whole panel
            Group { if state.rows.isEmpty { empty } else { list } }
                .frame(height: ControlPanel.listHeight, alignment: .top)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                transport
                playback
                speed
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 11)
        }
        .frame(width: 320)
        .onAppear { state.startPolling() }
        .onDisappear { state.stopPolling() }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("AeriaLite").font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu {
                ForEach(Filter.allCases) { option in
                    Toggle(option.rawValue, isOn: Binding(
                        get: { state.filters.contains(option) },
                        set: { on in
                            // All is exclusive; the other two union, and emptying falls back to All
                            if option == .all { return state.filters = [.all] }
                            var next = state.filters.subtracting([.all])
                            if on { next.insert(option) } else { next.remove(option) }
                            state.filters = next.isEmpty ? [.all] : next
                        }))
                }
                Divider()
                Button("Open wallpapers.json") { state.openCatalogFile() }
            } label: {
                Image(systemName: state.filters == [.all]
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(state.filters == [.all] ? Color.primary : .accentColor)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Tile(symbol: "gearshape", size: 12) { state.openConfig() }
            Tile(symbol: "power", hover: .white, size: 12) { NSApplication.shared.terminate(nil) }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
    }

    private var empty: some View {
        Text("Nothing matches this filter. Star some clips, or switch the filter back to All.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 12)
    }


    /// Hand-rolled rather than List's onMove, so the dragged row floats under the pointer and the
    /// rest part around it. Fixed row heights are what make the landing slot plain arithmetic.
    private var list: some View {
        let rows = state.rows
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { position, entry in
                    Row(entry: entry,
                        index: position,
                        playing: entry.name == state.status.id,
                        downloaded: Library.isDownloaded(entry),
                        playable: Library.playable(entry) != nil,
                        canStream: state.canStream,
                        hasSource: !entry.source.link.isEmpty,
                        progress: state.progress[entry.name],
                        encoding: state.encoding.contains(entry.name),
                        onPlay: { state.play(entry) },
                        onFavorite: { state.toggleFavorite(entry) },
                        onDownload: { state.toggleDownload(entry) },
                        onRename: { state.rename(entry, to: $0) })
                    .frame(height: ControlPanel.rowHeight)
                    .padding(.horizontal, 6)
                    .background(dragging == entry.id
                                ? AnyView(RoundedRectangle(cornerRadius: 5).fill(.background)
                                    .shadow(radius: 5, y: 2).padding(.horizontal, 4))
                                : AnyView(Color.clear))
                    .offset(y: slide(position))
                    .zIndex(dragging == entry.id ? 1 : 0)
                    .animation(dragging == entry.id ? nil : .easeOut(duration: 0.13), value: target)
                    .gesture(drag(from: position, of: rows.count))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func drag(from position: Int, of count: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if origin == nil { origin = position; dragging = state.rows[position].id }
                held = value.translation.height
                let steps = Int((held / ControlPanel.rowHeight).rounded())
                target = min(max(0, (origin ?? position) + steps), max(0, count - 1))
            }
            .onEnded { _ in
                if let from = origin, let to = target, from != to { state.reorder(from: from, to: to) }
                dragging = nil; origin = nil; target = nil; held = 0
            }
    }

    /// The dragged row tracks the pointer; every row between its old and new slot slides one
    /// place the other way, which is what opens the gap it lands in.
    private func slide(_ position: Int) -> CGFloat {
        guard let from = origin, let to = target else { return 0 }
        if position == from { return held }
        if from < to, position > from, position <= to { return -ControlPanel.rowHeight }
        if from > to, position < from, position >= to { return ControlPanel.rowHeight }
        return 0
    }

    private var transport: some View {
        HStack(spacing: 3) {
            Tile(symbol: "shuffle", tint: state.shuffle ? .accentColor : .primary) {
                state.shuffle.toggle()
            }
            Tile(symbol: "backward.end.fill") { state.previous() }
            Tile(symbol: state.paused ? "play.fill" : "pause.fill",
                 tint: state.paused ? .primary : .green, hover: .green) { state.paused.toggle() }
            Tile(symbol: state.running ? "stop.fill" : "power",
                 tint: state.running ? .red : .green,
                 hover: state.running ? .red : .green) { state.running.toggle() }
            Tile(symbol: "forward.end.fill") { state.next() }
            Tile(symbol: "repeat.1", tint: state.repeatOne ? .accentColor : .primary) {
                state.repeatOne.toggle()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var playback: some View {
        let total = max(state.status.duration, 0.01)
        let shown = scrubbing ?? state.status.position
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Position").font(.system(size: 12))
                Spacer()
                Text(remaining(total - shown))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            // no step: a stepped Slider draws a tick track, and seek() already snaps the landing
            // to the keyframe grid, so quantising the thumb as well only buys ticks
            Slider(value: Binding(get: { min(shown, total) }, set: { scrubbing = $0 }),
                   in: 0...total,
                   onEditingChanged: { editing in
                       if !editing, let target = scrubbing { state.seek(to: target); scrubbing = nil }
                   })
        }
        .disabled(!state.running || state.status.duration <= 0)
    }

    /// Signed, because the figure counts down rather than up.
    private func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "-0:00" }
        return String(format: "-%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private var speed: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Speed").font(.system(size: 12))
                Spacer()
                Text(String(format: state.speed < 1 ? "%.2fx" : "%.2gx", state.speed))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: $state.speed, in: 0.25...5, step: 0.25)
        }
        .disabled(!state.running)
    }
}
