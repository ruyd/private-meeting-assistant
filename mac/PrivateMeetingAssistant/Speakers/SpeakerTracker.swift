import Foundation

/// Groups transcript lines by voice as they arrive: each line's voiceprint joins the most similar
/// participant heard so far, or starts a new one ("Participant 3"). Each participant's profile is the
/// average of its voiceprints, plus the line that best represents it, kept as a sample to listen to.
/// When the recording stops, `finished()` merges participants that turned out to be one person and
/// numbers them in order of first speaking.
struct SpeakerTracker {
    /// A voiceprint less similar than this to every participant so far is a new person.
    static let newSpeakerBelow: Float = 0.45
    /// After the recording, participants whose profiles are this similar are merged.
    static let mergeAbove: Float = 0.6
    /// Participants with less speech than this are folded into the most similar other one, when
    /// that one is at least `foldAbove` alike: usually a cough or a few words that sounded different.
    static let minSpeechMs = 2_500
    static let foldAbove: Float = 0.3

    struct Profile: Equatable, Sendable {
        /// Average voiceprint, unit length.
        var voiceprint: [Float]
        /// Speech with a voiceprint, in milliseconds.
        var speechMs: Int
        var firstMs: Int
        /// The line kept as a sample of this voice (meeting milliseconds), and how good a sample it is.
        var sample: ClosedRange<Int>
        var sampleScore: Float
    }

    private(set) var profiles: [Profile] = []
    /// The participant who spoke last on each source, for lines too short for a voiceprint.
    private var last: [AudioSource: Int] = [:]

    /// The participant (numbered from 1) a line belongs to, and whether it's now that participant's
    /// sample. Without a voiceprint (a short line), it's whoever spoke last on that source, if anyone.
    mutating func assign(
        _ voiceprint: [Float]?, source: AudioSource, startMs: Int, endMs: Int, canBeSample: Bool = true
    ) -> (participant: Int?, isSample: Bool) {
        guard let voiceprint else { return (last[source], false) }
        let durationMs = max(endMs - startMs, 1)
        let best = profiles.indices.map { ($0, Self.similarity(voiceprint, profiles[$0].voiceprint)) }.max { $0.1 < $1.1 }

        let index: Int
        let similarity: Float
        if let best, best.1 >= Self.newSpeakerBelow {
            (index, similarity) = best
            var p = profiles[index]
            // Weighted by speech so far, capped so the profile keeps adapting to the voice.
            let weight = Float(min(p.speechMs, 60_000))
            p.voiceprint = Self.normalized(zip(p.voiceprint, voiceprint).map { $0 * weight + $1 * Float(durationMs) })
            p.speechMs += durationMs
            profiles[index] = p
        } else {
            profiles.append(Profile(voiceprint: voiceprint, speechMs: durationMs, firstMs: startMs, sample: startMs...endMs, sampleScore: -1))
            (index, similarity) = (profiles.count - 1, 1)
        }
        last[source] = index + 1

        // Long, clearly-this-voice lines make the best samples; past 8 s length stops mattering.
        let score = Float(min(durationMs, 8_000)) * similarity
        let isSample = canBeSample && score > profiles[index].sampleScore
        if isSample {
            profiles[index].sample = startMs...endMs
            profiles[index].sampleScore = score
        }
        return (index + 1, isSample)
    }

    /// The final participants, and how the numbers handed out during the recording map to them.
    func finished() -> (profiles: [Profile], renumber: [Int: Int]) {
        // Each group is a set of original indices that turned out to be one person.
        var groups: [(members: [Int], profile: Profile)] = profiles.enumerated().map { ([$0.offset], $0.element) }

        func mergeBest(where accept: (Profile, Profile, Float) -> Bool) -> Bool {
            var best: (Int, Int, Float)?
            for i in groups.indices {
                for j in groups.indices where j > i {
                    let s = Self.similarity(groups[i].profile.voiceprint, groups[j].profile.voiceprint)
                    if accept(groups[i].profile, groups[j].profile, s), s > (best?.2 ?? -2) { best = (i, j, s) }
                }
            }
            guard let (i, j, _) = best else { return false }
            groups[i] = (groups[i].members + groups[j].members, Self.merge(groups[i].profile, groups[j].profile))
            groups.remove(at: j)
            return true
        }
        while mergeBest(where: { _, _, s in s >= Self.mergeAbove }) {}
        while mergeBest(where: { a, b, s in min(a.speechMs, b.speechMs) < Self.minSpeechMs && s >= Self.foldAbove }) {}

        groups.sort { $0.profile.firstMs < $1.profile.firstMs }
        var renumber: [Int: Int] = [:]
        for (number, group) in groups.enumerated() {
            for member in group.members { renumber[member + 1] = number + 1 }
        }
        return (groups.map(\.profile), renumber)
    }

    /// Final participant per line: renumbered, and lines that had none (short lines before anyone
    /// else on that source spoke) given the participant of the nearest line on the same source.
    static func finalParticipants<ID: Hashable>(
        _ lines: [(id: ID, source: AudioSource, startMs: Int, participant: Int?)], renumber: [Int: Int]
    ) -> [ID: Int] {
        var out: [ID: Int] = [:]
        for line in lines {
            if let p = line.participant, let n = renumber[p] { out[line.id] = n }
        }
        for line in lines where out[line.id] == nil {
            let nearest = lines
                .filter { $0.source == line.source && out[$0.id] != nil }
                .min { abs($0.startMs - line.startMs) < abs($1.startMs - line.startMs) }
            if let nearest { out[line.id] = out[nearest.id] }
        }
        return out
    }

    private static func merge(_ a: Profile, _ b: Profile) -> Profile {
        Profile(
            voiceprint: normalized(zip(a.voiceprint, b.voiceprint).map { $0 * Float(a.speechMs) + $1 * Float(b.speechMs) }),
            speechMs: a.speechMs + b.speechMs,
            firstMs: min(a.firstMs, b.firstMs),
            sample: a.sampleScore >= b.sampleScore ? a.sample : b.sample,
            sampleScore: max(a.sampleScore, b.sampleScore)
        )
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = max(v.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        return v.map { $0 / norm }
    }
}
