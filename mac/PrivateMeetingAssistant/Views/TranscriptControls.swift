import SwiftUI

enum TranscriptFont {
    static let key = "transcriptFontSize"
    static let standard: Double = 14
    static let range: ClosedRange<Double> = 10...28
}

/// Smaller / larger transcript text (⌘− / ⌘=), for the meeting page and the live view; remembered.
struct TranscriptFontButtons: View {
    @AppStorage(TranscriptFont.key) private var size = TranscriptFont.standard

    var body: some View {
        ControlGroup {
            Button("Smaller Text", systemImage: "textformat.size.smaller") { size = max(size - 1, TranscriptFont.range.lowerBound) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(size <= TranscriptFont.range.lowerBound)
                .help("Smaller transcript text (⌘−)")
            Button("Larger Text", systemImage: "textformat.size.larger") { size = min(size + 1, TranscriptFont.range.upperBound) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(size >= TranscriptFont.range.upperBound)
                .help("Larger transcript text (⌘=)")
        }
    }
}

/// Notes typed during or after a meeting, saved to notes.md (and the search index) a moment after
/// typing stops, and when leaving.
struct NotesEditor: View {
    let meetingID: Int64
    let initial: String
    var minHeight: CGFloat = 90
    @Environment(MeetingLibrary.self) private var library
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: minHeight)
            .background(Theme.surface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Type notes… They're saved with the meeting, in notes.md.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = initial
                saved = initial
            }
            .task(id: text) {
                guard loaded, text != saved else { return }
                try? await Task.sleep(for: .seconds(1))
                save()
            }
            // Notes saved elsewhere (the live view, as the recording stopped) arrive here unless
            // these have been edited since.
            .onChange(of: initial) {
                if text == saved {
                    text = initial
                    saved = initial
                }
            }
            .onDisappear { save() }
    }

    private func save() {
        guard loaded, text != saved else { return }
        saved = text
        library.saveNotes(meetingID, text)
    }
}
