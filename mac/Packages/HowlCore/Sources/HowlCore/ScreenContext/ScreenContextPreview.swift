import Foundation

/// Decoded `howl_screen_context_preview()` response: the complete
/// record of how the NEXT capture's whisper `initial_prompt` would be
/// composed from the engine's current custom dictionary and stored
/// screen keywords — up to and including the exact string whisper
/// would receive.
///
/// A pure decode of Go's `transcribe.ContextPromptPlan` — same field
/// names (translated from snake_case), same stage vocabulary — so this
/// type cannot itself reinterpret what the plan means; it can only
/// fail to decode (see `LibhowlEngine.screenContextPreview()`, which
/// turns any failure into `nil` rather than throwing).
public struct ScreenContextPreview: Decodable, Equatable, Sendable {
    /// Custom dictionary as configured, before any trimming.
    public let dictionary: [String]
    /// Screen keywords as currently offered (i.e. whatever
    /// `howl_set_screen_keywords` last stored), before any trimming.
    public let screenKeywords: [String]
    /// `dictionary` after blank-stripping and the byte pre-filter —
    /// what entered the token-budget stage.
    public let dictionaryBounded: [String]
    /// Dictionary terms that actually reach whisper, in prompt order.
    public let dictionaryApplied: [String]
    /// Screen terms that actually reach whisper, in prompt order.
    /// Exactly what `howl_start_capture` would apply right now.
    public let screenApplied: [String]
    /// Every term offered that did NOT reach whisper, in the order the
    /// filtering stages ran, tagged with where it came from and which
    /// stage dropped it.
    public let dropped: [Drop]
    /// The exact string that would become whisper's `initial_prompt`.
    public let prompt: String
    /// `prompt`'s real length via `whisper_token_count` against the
    /// loaded model — not an estimate.
    public let tokenCount: Int
    /// The screen-only token sub-budget (the two caps together govern
    /// composition; dictionary always wins any conflict).
    public let maxScreenPromptTokens: Int
    /// The whole-prompt token budget — whisper's real ~224-token
    /// window.
    public let maxPromptTokens: Int

    /// One term that did not reach whisper.
    public struct Drop: Decodable, Equatable, Sendable {
        public let term: String
        /// `"dictionary"` | `"screen"`.
        public let source: String
        /// One of: `"empty"`, `"duplicate_of_dictionary"`,
        /// `"duplicate"`, `"byte_prefilter"`, `"dict_byte_cap"`,
        /// `"screen_token_cap"`, `"prompt_token_cap"` — see
        /// `transcribe.Drop*` in `core/internal/transcribe/prompt.go`.
        public let stage: String
    }

    enum CodingKeys: String, CodingKey {
        case dictionary
        case screenKeywords = "screen_keywords"
        case dictionaryBounded = "dictionary_bounded"
        case dictionaryApplied = "dictionary_applied"
        case screenApplied = "screen_applied"
        case dropped
        case prompt
        case tokenCount = "token_count"
        case maxScreenPromptTokens = "max_screen_prompt_tokens"
        case maxPromptTokens = "max_prompt_tokens"
    }
}
