import Foundation
import TimelineKitCore

public struct EditState: Equatable, Codable, Sendable {
    public var timeline: EditorTimeline
    public var links: [UUID: UUID] = [:]
    public var selection: Set<UUID> = []
}

public struct TimelineProject: Codable, Sendable {
    public var sourceURL: URL
    public var sourceDuration: Double
    public var fps: Double
    public var state: EditState
    public init(sourceURL: URL, edits: TimelineEdits) {
        self.sourceURL = sourceURL; sourceDuration = edits.sourceDuration; fps = edits.fps; state = edits.state
    }
}

public enum TrimEdge { case start, end }

public struct TimelineEdits: Sendable {
    public private(set) var state: EditState
    public let sourceDuration: Double
    public let fps: Double
    private var past: [EditState] = []
    private var future: [EditState] = []
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var duration: Double { state.timeline.tracks.flatMap(\.segments).map(\.targetRange.end).max() ?? 0 }
    public var segments: [EditorSegment] { state.timeline.tracks.flatMap(\.segments) }
    public var hasDetachedSelection: Bool {
        state.timeline.tracks.contains { $0.kind == .audio } && state.selection.contains { state.links[$0] == nil }
    }

    public init(duration: Double, fps: Double, hasAudio: Bool) {
        sourceDuration = duration
        self.fps = max(1, fps)
        let material = UUID()
        let range = TimeRange(start: 0, duration: duration)
        let video = EditorSegment(materialID: material, sourceRange: range, targetRange: range, content: .video(.init()))
        var tracks = [EditorTrack(kind: .video, label: "视频", segments: [video], isMainTrack: true)]
        var links: [UUID: UUID] = [:]
        if hasAudio {
            let audio = EditorSegment(materialID: material, sourceRange: range, targetRange: range, content: .audio(.init()))
            tracks.append(EditorTrack(kind: .audio, label: "音频", segments: [audio]))
            let group = UUID(); links[video.id] = group; links[audio.id] = group
        }
        state = EditState(timeline: EditorTimeline(canvas: EditorCanvas(width: 1920, height: 1080, fps: Int(fps.rounded())), tracks: tracks), links: links)
    }

    public func snapped(_ time: Double) -> Double { (time * fps).rounded() / fps }
    private func expanded(_ ids: Set<UUID>) -> Set<UUID> {
        let groups = Set(ids.compactMap { state.links[$0] })
        return ids.union(state.links.filter { groups.contains($0.value) }.map(\.key))
    }
    public mutating func select(_ id: UUID, additive: Bool = false) {
        let group = expanded([id])
        if additive { state.selection = group.isSubset(of: state.selection) ? state.selection.subtracting(group) : state.selection.union(group) }
        else { state.selection = group }
    }
    public mutating func selectMany(_ ids: Set<UUID>, additive: Bool = false) {
        state.selection = additive ? state.selection.union(expanded(ids)) : expanded(ids)
    }
    public mutating func selectAll() { state.selection = Set(segments.map(\.id)) }
    private mutating func commit(_ next: EditState) {
        guard next != state else { return }
        past.append(state)
        if past.count > 100 { past.removeFirst() }
        future.removeAll(); state = next
    }
    public mutating func undo() { guard let value = past.popLast() else { return }; future.append(state); state = value }
    public mutating func redo() { guard let value = future.popLast() else { return }; past.append(state); state = value }
    public mutating func unlinkSelection() {
        var next = state
        let groups = Set(state.selection.compactMap { state.links[$0] })
        next.links = state.links.filter { !groups.contains($0.value) }
        commit(next)
    }
    public mutating func split(at seconds: Double) {
        let time = snapped(seconds)
        var next = state
        var rightGroups: [UUID: UUID] = [:]
        let selectionAtPlayhead = segments.contains { state.selection.contains($0.id) && time > $0.targetRange.start + 0.5/fps && time < $0.targetRange.end - 0.5/fps }
        for track in next.timeline.tracks.indices {
            var pieces: [EditorSegment] = []
            for original in next.timeline.tracks[track].segments {
                guard time > original.targetRange.start + 0.5/fps,
                      time < original.targetRange.end - 0.5/fps,
                      !selectionAtPlayhead || state.selection.contains(original.id),
                      let source = original.sourceRange else { pieces.append(original); continue }
                let offset = time - original.targetRange.start
                var left = original
                left.targetRange.duration = offset; left.sourceRange?.duration = offset
                let right = EditorSegment(materialID: original.materialID,
                    sourceRange: TimeRange(start: source.start + offset, duration: source.duration - offset),
                    targetRange: TimeRange(start: time, duration: original.targetRange.end - time), content: original.content)
                if let group = state.links[original.id] {
                    let newGroup = rightGroups[group] ?? UUID(); rightGroups[group] = newGroup
                    next.links[right.id] = newGroup
                }
                if next.selection.contains(original.id) { next.selection.insert(right.id) }
                pieces += [left, right]
            }
            next.timeline.tracks[track].segments = pieces
        }
        commit(next)
    }
    public mutating func deleteSelection(ripple: Bool) {
        guard !state.selection.isEmpty else { return }
        var next = state
        let removed = segments.filter { state.selection.contains($0.id) }
        var intervals: [TimeRange] = []
        if ripple {
            for r in removed.map(\.targetRange).sorted(by: { $0.start < $1.start }) {
                if let last = intervals.last, r.start <= last.end + 0.00001 {
                    intervals[intervals.count-1].duration = max(last.end, r.end) - last.start
                } else { intervals.append(r) }
            }
        }
        for t in next.timeline.tracks.indices {
            var output: [EditorSegment] = []
            for segment in next.timeline.tracks[t].segments where !state.selection.contains(segment.id) {
                var pieces = [segment]
                // Remove the same time from every track to keep surviving media synchronized.
                for cut in intervals {
                    pieces = pieces.flatMap { clip -> [EditorSegment] in
                        let r = clip.targetRange
                        guard r.start < cut.end && r.end > cut.start else { return [clip] }
                        var result: [EditorSegment] = []
                        if r.start < cut.start {
                            var left = clip; left.targetRange.duration = cut.start-r.start; left.sourceRange?.duration = left.targetRange.duration; result.append(left)
                        }
                        if r.end > cut.end, let source = clip.sourceRange {
                            let right = EditorSegment(materialID: clip.materialID,
                                sourceRange: TimeRange(start: source.start+cut.end-r.start, duration: r.end-cut.end),
                                targetRange: TimeRange(start: cut.end,duration:r.end-cut.end),content:clip.content)
                            result.append(right)
                        }
                        return result
                    }
                }
                for var piece in pieces {
                    piece.targetRange.start -= intervals.filter { $0.end <= piece.targetRange.start + 0.00001 }.reduce(0) { $0+$1.duration }
                    output.append(piece)
                }
            }
            next.timeline.tracks[t].segments = output
        }
        let surviving = Set(next.timeline.tracks.flatMap(\.segments).map(\.id))
        next.links = next.links.filter { surviving.contains($0.key) }
        next.selection = []
        commit(next)
    }
    private func valid(_ next: EditState) -> Bool {
        for track in next.timeline.tracks {
            let clips = track.segments.sorted { $0.targetRange.start < $1.targetRange.start }
            var end = 0.0
            for clip in clips {
                guard let source = clip.sourceRange, source.start >= -0.00001,
                      source.end <= sourceDuration + 0.00001, clip.targetRange.duration >= 0.5/fps,
                      clip.targetRange.start >= end - 0.00001 else { return false }
                end = clip.targetRange.end
            }
        }
        return true
    }
    /// Resolve near-edge snapping and clamp overlap to the nearest legal boundary.
    public func magneticMoveDelta(by proposed: Double, tolerance: Double) -> Double {
        let selected = segments.filter { state.selection.contains($0.id) }
        guard !selected.isEmpty else { return 0 }
        var boundaries: [Double] = []
        for track in state.timeline.tracks {
            let moving = track.segments.filter { state.selection.contains($0.id) }
            let fixed = track.segments.filter { !state.selection.contains($0.id) }
            for clip in moving {
                boundaries.append(-clip.targetRange.start)
                for other in fixed {
                    boundaries.append(other.targetRange.end - clip.targetRange.start)
                    boundaries.append(other.targetRange.start - clip.targetRange.end)
                }
            }
        }
        func legal(_ delta: Double) -> Bool {
            var trial = self
            trial.moveSelection(by: delta, snapToFrame: false)
            guard let id = selected.first?.id,
                  let moved = trial.segments.first(where: { $0.id == id }) else { return false }
            return abs(moved.targetRange.start - selected[0].targetRange.start - delta) < 0.00001
        }
        let wanted = snapped(proposed)
        let ordered = Array(Set(boundaries)).sorted { abs($0-wanted) < abs($1-wanted) }
        if let near = ordered.first(where: { abs($0-wanted) <= tolerance && legal($0) }) { return near }
        if legal(wanted) { return wanted }
        return ordered.first(where: { legal($0) }) ?? 0
    }

    /// Insert selected clips as a block. Linked partners receive the exact same
    /// displacement; detached lanes remain unchanged. Invalid overlaps are atomic no-ops.
    @discardableResult
    public mutating func reorderSelection(draggedID: UUID, to time: Double) -> Double? {
        guard time.isFinite, state.selection.contains(draggedID),
              let lane = state.timeline.tracks.first(where: { $0.segments.contains { $0.id == draggedID } }),
              !lane.isLocked else { return nil }
        let ordered = lane.segments.sorted { $0.targetRange.start < $1.targetRange.start }
        let moving = ordered.filter { state.selection.contains($0.id) }
        let remaining = ordered.filter { !state.selection.contains($0.id) }
        guard !moving.isEmpty else { return nil }
        let slot = remaining.firstIndex { time < $0.targetRange.start + $0.targetRange.duration / 2 } ?? remaining.count
        let reordered = Array(remaining.prefix(slot)) + moving + Array(remaining.dropFirst(slot))
        var next = state
        var shifts: [UUID: Double] = [:]
        var cursor = ordered.first?.targetRange.start ?? 0
        var insertion = cursor
        for clip in reordered {
            if clip.id == moving[0].id { insertion = cursor }
            let delta = cursor - clip.targetRange.start
            for id in expanded([clip.id]) { shifts[id] = delta }
            cursor += clip.targetRange.duration
        }
        for t in next.timeline.tracks.indices {
            for c in next.timeline.tracks[t].segments.indices {
                let id = next.timeline.tracks[t].segments[c].id
                if let delta = shifts[id] {
                    if next.timeline.tracks[t].isLocked && abs(delta) > 0.00001 { return nil }
                    next.timeline.tracks[t].segments[c].targetRange.start += delta
                }
            }
            next.timeline.tracks[t].segments.sort { $0.targetRange.start < $1.targetRange.start }
        }
        guard valid(next) else { return nil }
        commit(next)
        return insertion
    }

    public mutating func moveSelection(by delta: Double, snapToFrame: Bool = true) {
        var next = state
        for t in next.timeline.tracks.indices {
            for s in next.timeline.tracks[t].segments.indices where state.selection.contains(next.timeline.tracks[t].segments[s].id) {
                next.timeline.tracks[t].segments[s].targetRange.start += snapToFrame ? snapped(delta) : delta
            }
            next.timeline.tracks[t].segments.sort { $0.targetRange.start < $1.targetRange.start }
        }
        if valid(next) { commit(next) }
    }
    public mutating func trimSelected(edge: TrimEdge, to seconds: Double, ripple: Bool = false) {
        guard let anchor = segments.first(where: { state.selection.contains($0.id) }) else { return }
        let requested = snapped(seconds) - (edge == .start ? anchor.targetRange.start : anchor.targetRange.end)
        let selected = segments.filter { state.selection.contains($0.id) }
        let lower = selected.compactMap { clip -> Double? in
            guard let source = clip.sourceRange else { return nil }
            return edge == .start ? -source.start : 1/fps - clip.targetRange.duration
        }.max() ?? 0
        let upper = selected.compactMap { clip -> Double? in
            guard let source = clip.sourceRange else { return nil }
            return edge == .start ? clip.targetRange.duration - 1/fps : sourceDuration - source.end
        }.min() ?? 0
        let delta = max(lower,min(upper,requested))
        var next = state
        for t in next.timeline.tracks.indices {
            for s in next.timeline.tracks[t].segments.indices where state.selection.contains(next.timeline.tracks[t].segments[s].id) {
                if edge == .start {
                    next.timeline.tracks[t].segments[s].targetRange.start += delta
                    next.timeline.tracks[t].segments[s].targetRange.duration -= delta
                    next.timeline.tracks[t].segments[s].sourceRange?.start += delta
                    next.timeline.tracks[t].segments[s].sourceRange?.duration -= delta
                } else {
                    next.timeline.tracks[t].segments[s].targetRange.duration += delta
                    next.timeline.tracks[t].segments[s].sourceRange?.duration += delta
                }
            }
        }
        if ripple {
            let extensionLength = edge == .start ? -delta : delta
            if extensionLength > 0 {
                let boundary = edge == .start ? anchor.targetRange.start : anchor.targetRange.end
                for t in next.timeline.tracks.indices {
                    for c in next.timeline.tracks[t].segments.indices {
                        let clip = next.timeline.tracks[t].segments[c]
                        if state.selection.contains(clip.id) {
                            if edge == .start { next.timeline.tracks[t].segments[c].targetRange.start += extensionLength }
                        } else if clip.targetRange.start >= boundary - 0.00001 {
                            next.timeline.tracks[t].segments[c].targetRange.start += extensionLength
                        }
                    }
                }
            }
            let start = edge == .start ? anchor.targetRange.start : anchor.targetRange.end + delta
            let end = edge == .start ? anchor.targetRange.start + delta : anchor.targetRange.end
            if end > start + 0.00001 {
                // Close only a genuine empty interval; detached overlapping media remains intact.
                let occupied = next.timeline.tracks.flatMap(\.segments).contains {
                    $0.targetRange.start < end - 0.00001 && $0.targetRange.end > start + 0.00001
                }
                if !occupied {
                    for t in next.timeline.tracks.indices {
                        for c in next.timeline.tracks[t].segments.indices where next.timeline.tracks[t].segments[c].targetRange.start >= end - 0.00001 {
                            next.timeline.tracks[t].segments[c].targetRange.start -= end - start
                        }
                    }
                }
            }
        }
        if valid(next) { commit(next) }
    }
}
