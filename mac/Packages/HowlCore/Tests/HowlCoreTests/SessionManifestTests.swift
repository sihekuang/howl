import Foundation
import Testing
@testable import HowlCore

@Suite("SessionManifest decoding")
struct SessionManifestTests {

    @Test func decodes_screen_keywords_whisper_prompt_and_token_count() throws {
        let json = """
        {
          "version": 1, "id": "2026-08-29T00:00:00Z", "preset": "default", "duration_sec": 3.5,
          "stages": [],
          "transcripts": {"raw": "raw.txt", "dict": "dict.txt", "cleaned": "cleaned.txt"},
          "screen_keywords": ["SpeakerGate", "DeepFilterNet"],
          "whisper_prompt": "SpeakerGate, DeepFilterNet",
          "whisper_prompt_tokens": 11
        }
        """
        let manifest = try JSONDecoder().decode(SessionManifest.self, from: Data(json.utf8))
        #expect(manifest.screenKeywords == ["SpeakerGate", "DeepFilterNet"])
        #expect(manifest.whisperPrompt == "SpeakerGate, DeepFilterNet")
        #expect(manifest.whisperPromptTokens == 11)
    }

    @Test func legacy_manifest_without_the_new_fields_decodes_with_defaults() throws {
        // Exactly the shape a pre-feature session.json has on disk:
        // none of the three keys present at all.
        let json = """
        {
          "version": 1, "id": "2026-01-01T00:00:00Z", "preset": "default", "duration_sec": 1.0,
          "stages": [],
          "transcripts": {"raw": "raw.txt", "dict": "dict.txt", "cleaned": "cleaned.txt"}
        }
        """
        let manifest = try JSONDecoder().decode(SessionManifest.self, from: Data(json.utf8))
        #expect(manifest.screenKeywords == [])
        #expect(manifest.whisperPrompt == "")
        #expect(manifest.whisperPromptTokens == 0)
        // Pre-existing fields still decode correctly alongside the new
        // defaults — the point of `omitempty` is that old and new
        // manifests both decode cleanly through the same type.
        #expect(manifest.id == "2026-01-01T00:00:00Z")
        #expect(manifest.preset == "default")
    }

    @Test func round_trips_through_encode_and_decode() throws {
        let json = """
        {
          "version": 1, "id": "x", "preset": "default", "duration_sec": 1.0,
          "stages": [],
          "transcripts": {"raw": "raw.txt", "dict": "dict.txt", "cleaned": "cleaned.txt"},
          "screen_keywords": ["Foo"],
          "whisper_prompt": "Foo",
          "whisper_prompt_tokens": 3
        }
        """
        let decoded = try JSONDecoder().decode(SessionManifest.self, from: Data(json.utf8))
        let reEncoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(SessionManifest.self, from: reEncoded)
        #expect(roundTripped == decoded)
    }
}
