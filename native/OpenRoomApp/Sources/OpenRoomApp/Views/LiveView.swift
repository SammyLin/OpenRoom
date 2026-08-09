import SwiftUI

struct LiveView: View {
    @ObservedObject var session: MeetingSession
    let scenarioLabel: String
    let onStop: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                transcript.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                sidebar.frame(width: 320)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.phase == .live ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(session.phase == .live ? .red : .secondary)
            }

            Text(formatClock(session.audioMs))
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)

            // 音量表：看得到聲音進來，才知道「有沒有在收音」
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor).opacity(0.5))
                    Capsule().fill(
                        LinearGradient(colors: [.accentColor, .accentColor.opacity(0.6)],
                                       startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, geo.size.width * session.capture.level))
                }
            }
            .frame(width: 110, height: 6)

            Spacer()

            Button(action: onExport) {
                Label(L("Export"), systemImage: "square.and.arrow.up")
            }
            .disabled(session.segments.isEmpty)

            Button(role: .destructive, action: onStop) {
                Label(L("Stop"), systemImage: "stop.fill")
            }
            .disabled(session.phase != .live)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.bar)
    }

    private var statusText: String {
        switch session.phase {
        case .live: return L("Recording")
        case .warming, .connecting: return L("Warming up")
        default: return L("Stopped")
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groupSegments(session.segments, turns: session.turns)) { seg in
                    transcriptRow(seg)
                }
                if !session.partial.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(Color.secondary.opacity(0.2)).frame(width: 26, height: 26)
                        Text(session.partial).font(.body).foregroundStyle(.secondary).italic()
                    }
                }
                if session.segments.isEmpty && session.partial.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text(session.phase == .warming ? L("Warming up…") : L("No transcript yet"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transcriptRow(_ seg: Segment) -> some View {
        let names = speakerNames(session.turns)
        let name = seg.speaker.flatMap { names[$0] }
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill((seg.speaker.map(speakerColor) ?? .secondary).opacity(0.18))
                    .frame(width: 26, height: 26)
                Text(name?.last.map(String.init) ?? "?")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(seg.speaker.map(speakerColor) ?? .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let name {
                        Text(name).font(.caption.weight(.semibold))
                            .foregroundStyle(seg.speaker.map(speakerColor) ?? .secondary)
                    }
                    Text(formatClock(seg.startMs)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Text(seg.text).font(.body).textSelection(.enabled)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(scenarioLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    if session.analysing {
                        Label(L("Analysing…"), systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(session.insights) { ins in
                        insightCard(ins)
                    }
                    if session.insights.isEmpty && !session.analysing {
                        Text(L("No background notes yet. They show up once there is enough conversation."))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }.padding(14)
            }
            Divider()
            DisclosureGroup {
                healthDetail
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(session.health.clean ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(L("Pipeline health"))
                }
            }
            .font(.caption).padding(12)
        }
        .background(.thinMaterial)
    }

    private func insightCard(_ ins: Insight) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(ins.headline).font(.subheadline.weight(.semibold))
                ForEach(ins.items) { item in
                    Text("· \(item.text)").font(.caption)
                }
                ForEach(ins.questions, id: \.self) { q in
                    Label(q, systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var healthDetail: some View {
        VStack(alignment: .leading, spacing: 5) {
            healthRow("engine", session.engine ?? "?")
            healthRow("gaps", "\(session.health.gaps)　lost_ms: \(session.health.lostMs)")
            healthRow("no_speech", "\(session.health.noSpeech)　revisions: \(session.health.revisions)")
            healthRow("dropped_before_ready", "\(session.health.droppedBeforeReady)")
            healthRow("speakers", "\(session.speakers)")
            ForEach(session.health.errors) { e in
                Label("\(e.code): \(e.message)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }.font(.caption2).padding(.top, 4)
    }

    private func healthRow(_ key: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }
}
