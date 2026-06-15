import CoreGraphics

/// Identifies synthetic keyboard events that Howl posts itself — streaming
/// text injection (`CGEventTextTyper`) and the final ⌘V paste
/// (`CGEventKeystrokeSender`). The any-key cancel monitor reads this marker
/// to tell Howl's own injection apart from a real user keypress, so typing
/// text into the document never self-cancels the dictation.
enum HowlSyntheticEvent {
    /// Sentinel written to `CGEventField.eventSourceUserData` on every
    /// synthetic keystroke Howl posts. Arbitrary but fixed ("HOWL" + a tag);
    /// unique-enough not to collide with other apps' synthetic events.
    static let marker: Int64 = 0x484F_574C_0001
}

extension CGEvent {
    /// Stamp this event as Howl-originated synthetic input.
    func markAsHowlSynthetic() {
        setIntegerValueField(.eventSourceUserData, value: HowlSyntheticEvent.marker)
    }

    /// True when this event carries Howl's synthetic-input marker.
    var isHowlSynthetic: Bool {
        getIntegerValueField(.eventSourceUserData) == HowlSyntheticEvent.marker
    }
}
