import SwiftUI

/// The Record page's list of upcoming meetings from linked accounts, plus a field to look one up by
/// link or ID. Picking one names the recording and attaches its participants.
struct UpcomingMeetingsSection: View {
    @Binding var selected: MeetingDetails?
    let pick: (MeetingDetails) -> Void
    private let accounts = MeetingAccounts.shared
    @State private var lookupText = ""
    @State private var lookupError: String?
    @State private var isLookingUp = false
    @State private var completing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Meeting").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if accounts.isRefreshing {
                    ProgressView().controlSize(.mini)
                } else if !accounts.linked.isEmpty {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await accounts.refreshUpcoming() } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Reload upcoming meetings from your linked accounts")
                }
            }

            if accounts.linked.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus").foregroundStyle(.secondary)
                    Text("Link Google, Microsoft 365 or Zoom to name recordings and list participants from your meetings.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    SettingsLink { Text("Link Accounts…") }
                        .controlSize(.small)
                }
                .padding(12)
                .background(Theme.surface, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            } else {
                if accounts.upcoming.isEmpty, !accounts.isRefreshing {
                    Text("No more meetings today or tomorrow.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(accounts.upcoming) { meeting in
                            UpcomingMeetingCard(
                                meeting: meeting, isSelected: selected?.id == meeting.id,
                                isLoading: completing == meeting.id
                            ) { choose(meeting) }
                        }
                    }
                }
                lookupField
            }

            ForEach(accounts.errors.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { provider, error in
                Label("\(provider.name): \(error)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .task {
            // Keeps "upcoming" current while the page is open.
            while !Task.isCancelled {
                await accounts.refreshUpcoming()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private var lookupField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Paste a Meet, Zoom or Teams link or meeting ID", text: $lookupText)
                    .textFieldStyle(.plain)
                    .onSubmit(lookup)
                if isLookingUp {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Find", action: lookup)
                        .controlSize(.small)
                        .disabled(lookupText.nilIfBlank == nil)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            if let lookupError {
                Text(lookupError).font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
    }

    private func lookup() {
        guard let text = lookupText.nilIfBlank, !isLookingUp else { return }
        isLookingUp = true
        lookupError = nil
        Task {
            defer { isLookingUp = false }
            do {
                pick(try await accounts.lookup(text))
                lookupText = ""
            } catch {
                lookupError = error.localizedDescription
            }
        }
    }

    /// Picks the meeting, first fetching what its listing left out (Zoom's invitees).
    private func choose(_ meeting: MeetingDetails) {
        if selected?.id == meeting.id {
            selected = nil
            return
        }
        guard meeting.provider == .zoom else { return pick(meeting) }
        completing = meeting.id
        Task {
            defer { completing = nil }
            pick((try? await accounts.complete(meeting)) ?? meeting)
        }
    }
}

private struct UpcomingMeetingCard: View {
    let meeting: MeetingDetails
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(timeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isNow ? .red : .secondary)
                    Spacer(minLength: 4)
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    } else if let platform = meeting.platform {
                        Label(platform.name, systemImage: platform.symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(peopleLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(width: 210, alignment: .leading)
            .background(isSelected ? AnyShapeStyle(Theme.raised) : AnyShapeStyle(Theme.surface), in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.stroke), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Don't attach this meeting" : "Record “\(meeting.title)” with its participants")
    }

    private var isNow: Bool {
        meeting.start <= Date() && (meeting.end ?? meeting.start.addingTimeInterval(3600)) > Date()
    }

    private var timeLabel: String {
        if isNow { return "NOW" }
        let time = meeting.start.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(meeting.start) ? time : "\(meeting.start.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    private var peopleLabel: String {
        let others = meeting.others
        guard let first = others.first else { return "No other participants listed" }
        return others.count == 1 ? first.displayName : "\(first.displayName) + \(others.count - 1) more"
    }
}

/// Everyone invited to a meeting, each on their own line with their role, so it's clear who's who:
/// the recorder ("Me"), the organizer, required and optional guests, and who declined.
struct ParticipantsList: View {
    let details: MeetingDetails

    var body: some View {
        let people = details.participants.filter(\.isMe) + details.others
        if people.isEmpty {
            Text("No participants listed.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 8) {
                ForEach(people) { ParticipantChip(participant: $0) }
            }
        }
    }
}

struct ParticipantChip: View {
    let participant: MeetingParticipant

    var body: some View {
        HStack(spacing: 8) {
            Text(initials)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(color, in: .circle)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(participant.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.raised, in: .capsule)
                            .foregroundStyle(.secondary)
                    }
                }
                if let email = participant.email, participant.name?.nilIfBlank != nil {
                    Text(email).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(Theme.surface, in: .capsule)
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .opacity(participant.response == .declined ? 0.55 : 1)
        .textSelection(.enabled)
        .help(MeetingFiles.participantLine(participant))
    }

    private var badges: [String] {
        var out: [String] = []
        if participant.isMe { out.append("ME") }
        if participant.role == .organizer { out.append("ORGANIZER") }
        if participant.role == .optional { out.append("OPTIONAL") }
        if participant.response == .declined { out.append("DECLINED") }
        if participant.response == .tentative { out.append("MAYBE") }
        return out
    }

    private var initials: String {
        let words = participant.displayName.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// A steady colour per person, so the same person looks the same across meetings.
    private var color: Color {
        if participant.isMe { return .accentColor }
        let palette: [Color] = [.orange, .pink, .purple, .teal, .indigo, .green, .brown, .cyan]
        let hash = participant.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[hash % palette.count]
    }
}
