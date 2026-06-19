# Speech to Text Prompt — Budget Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface whisper's tiny initial-prompt budget in the Dictionary tab (the dictionary already *is* the speech-to-text prompt), and right-size the built-in occupation packs with an automated guard.

**Architecture:** A pure byte-budget helper (`DictStats.whisperPromptFit`) in the HowlCore package mirrors the Go `DictionaryPrompt` bound; the Dictionary tab renders it as a second, clearly-labeled meter plus an always-visible limitations line. `OccupationPacks` relocates from the app target into HowlCore so a package test can guard each pack's size.

**Tech Stack:** Swift 5.9+ (SwiftUI + AppKit app target `Howl`, SwiftPM package `HowlCore`), swift-testing (`import Testing`), xcodegen-generated Xcode project, `make` wrappers.

**Branch:** `claude/whisper-go-custom-dict-k2vy6i` (continues the custom-dictionary feature).

## Global Constraints

- **Budget constant:** `whisperPromptBudgetBytes = 896` — mirrors Go `transcribe.MaxInitialPromptLen` in `core/internal/transcribe/prompt.go`. Comment must point at the Go source.
- **Byte-based, UTF-8:** all budget math uses `String.utf8.count`, never `.count` (characters), because the Go bound truncates by bytes.
- **Token estimate:** `bytes / 4`, rounded up — matching the existing `DictStats.compute` convention.
- **Pack soft cap:** each occupation pack's joined `", "` size ≤ `whisperPromptBudgetBytes / 2` (448 bytes), so a single pack fits comfortably and any two still fit 896.
- **No new config plumbing:** no `Config` / `EngineConfig` / `UserSettings` field, no Go change for the core feature. (The optional Task 4 replay.go fix is the only Go touch and is independent.)
- **Tests:** swift-testing in `mac/Packages/HowlCore/Tests/HowlCoreTests/`; run with `cd mac/Packages/HowlCore && swift test`. There is no app-target test bundle.

---

### Task 1: `whisperPromptFit` budget helper (HowlCore)

**Files:**
- Modify: `mac/Packages/HowlCore/Sources/HowlCore/Storage/DictStats.swift`
- Test: `mac/Packages/HowlCore/Tests/HowlCoreTests/DictStatsTests.swift`

**Interfaces:**
- Consumes: nothing (leaf helper).
- Produces:
  - `DictStats.whisperPromptBudgetBytes: Int` (== 896)
  - `DictStats.WhisperPromptFit` with public lets `usedBytes, budgetBytes, usedTokens, budgetTokens, termsThatFit, totalTerms: Int` and `overBudget: Bool`
  - `DictStats.whisperPromptFit(from terms: [String]) -> WhisperPromptFit`

- [ ] **Step 1: Write the failing tests**

Append to `mac/Packages/HowlCore/Tests/HowlCoreTests/DictStatsTests.swift`, inside the existing `struct DictStatsTests { ... }` (before the closing brace):

```swift
    @Test func whisperFit_empty_is_not_over_budget() {
        let f = DictStats.whisperPromptFit(from: [])
        #expect(f.usedBytes == 0)
        #expect(f.budgetBytes == 896)
        #expect(f.budgetTokens == 224)
        #expect(f.totalTerms == 0)
        #expect(f.termsThatFit == 0)
        #expect(f.overBudget == false)
    }

    @Test func whisperFit_small_dict_all_fit() {
        // "MCP, WebRTC" = 11 bytes
        let f = DictStats.whisperPromptFit(from: ["MCP", "WebRTC"])
        #expect(f.usedBytes == 11)
        #expect(f.usedTokens == 3)        // ceil(11/4)
        #expect(f.termsThatFit == 2)
        #expect(f.totalTerms == 2)
        #expect(f.overBudget == false)
    }

    @Test func whisperFit_large_dict_truncates_leading_terms() {
        // 50 × 20-byte term. Joined length of first k terms = 22k - 2.
        // 22*50 - 2 = 1098 > 896 -> over. Largest k with 22k-2 <= 896 is 40 (878).
        let terms = Array(repeating: "supercalifragilistic", count: 50)
        let f = DictStats.whisperPromptFit(from: terms)
        #expect(f.overBudget == true)
        #expect(f.totalTerms == 50)
        #expect(f.termsThatFit == 40)
    }

    @Test func whisperFit_boundary_exactly_at_budget_fits() {
        let f = DictStats.whisperPromptFit(from: [String(repeating: "a", count: 896)])
        #expect(f.usedBytes == 896)
        #expect(f.overBudget == false)
        #expect(f.termsThatFit == 1)
    }

    @Test func whisperFit_boundary_one_over_does_not_fit() {
        let f = DictStats.whisperPromptFit(from: [String(repeating: "a", count: 897)])
        #expect(f.usedBytes == 897)
        #expect(f.overBudget == true)
        #expect(f.termsThatFit == 0)
    }

    @Test func whisperFit_uses_utf8_byte_length() {
        // "世界" = 2 characters but 6 UTF-8 bytes.
        let f = DictStats.whisperPromptFit(from: ["世界"])
        #expect(f.usedBytes == 6)
        #expect(f.overBudget == false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd mac/Packages/HowlCore && swift test --filter DictStats`
Expected: compile FAILURE — `value of type 'DictStats.Type' has no member 'whisperPromptFit'`.

- [ ] **Step 3: Write the implementation**

In `mac/Packages/HowlCore/Sources/HowlCore/Storage/DictStats.swift`, add the following members inside `public enum DictStats { ... }` (after the existing `compute` function, before the closing brace):

```swift
    /// Byte budget for whisper's initial prompt. Mirrors
    /// `transcribe.MaxInitialPromptLen` in
    /// core/internal/transcribe/prompt.go (896 bytes ≈ ~224 tokens;
    /// whisper.cpp keeps only the last ~n_text_ctx/2 prompt tokens). The
    /// Go side joins the dictionary ", " and bounds it to this, so terms
    /// past the cap never reach whisper's recognition. Keep in sync with Go.
    public static let whisperPromptBudgetBytes = 896

    /// How the dictionary fits whisper's initial-prompt budget. Byte-based
    /// (UTF-8) because the Go bound truncates by bytes, not characters.
    public struct WhisperPromptFit: Equatable, Sendable {
        public let usedBytes: Int
        public let budgetBytes: Int
        public let usedTokens: Int
        public let budgetTokens: Int
        public let termsThatFit: Int
        public let totalTerms: Int
        public let overBudget: Bool
    }

    /// Mirror of the Go `DictionaryPrompt` bound: join terms with ", ",
    /// measure UTF-8 bytes, and count how many leading terms fit within
    /// `whisperPromptBudgetBytes`. Go truncates the joined string from the
    /// back, so the leading terms are the ones that reach whisper.
    public static func whisperPromptFit(from terms: [String]) -> WhisperPromptFit {
        let budget = whisperPromptBudgetBytes
        let used = terms.joined(separator: ", ").utf8.count
        let over = used > budget
        var fit = terms.count
        if over {
            var running = 0
            fit = 0
            for (i, term) in terms.enumerated() {
                let add = (i == 0 ? 0 : 2) + term.utf8.count  // ", " before all but first
                if running + add > budget { break }
                running += add
                fit += 1
            }
        }
        return WhisperPromptFit(
            usedBytes: used,
            budgetBytes: budget,
            usedTokens: Int((Double(used) / 4.0).rounded(.up)),
            budgetTokens: budget / 4,
            termsThatFit: fit,
            totalTerms: terms.count,
            overBudget: over
        )
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd mac/Packages/HowlCore && swift test --filter DictStats`
Expected: PASS (all `whisperFit_*` and the existing `DictStats` tests green).

- [ ] **Step 5: Commit**

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/Storage/DictStats.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/DictStatsTests.swift
git commit -m "feat(dict): whisperPromptFit budget helper in HowlCore

Pure byte-based helper mirroring the Go DictionaryPrompt bound (896-byte
MaxInitialPromptLen). Reports used/budget bytes+tokens and how many leading
dictionary terms reach whisper's initial prompt.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Relocate `OccupationPacks` to HowlCore + guard test + value-order

**Files:**
- Move: `mac/Howl/UI/Settings/OccupationPacks.swift` → `mac/Packages/HowlCore/Sources/HowlCore/OccupationPacks.swift`
- Modify: the moved file (add `public`, reorder terms)
- Create: `mac/Packages/HowlCore/Tests/HowlCoreTests/OccupationPacksTests.swift`
- Regenerate: `mac/Howl.xcodeproj` (via `make project`)

**Interfaces:**
- Consumes: `DictStats.whisperPromptBudgetBytes` (Task 1).
- Produces: `public enum OccupationPacks` with `public struct Pack: Identifiable, Hashable { public let id, name: String; public let terms: [String] }` and `public static let all: [Pack]`. Same surface `DictionaryTab` already uses (`OccupationPacks.all`, `pack.id/name/terms`).

- [ ] **Step 1: Move the file into the package**

```bash
git mv mac/Howl/UI/Settings/OccupationPacks.swift \
       mac/Packages/HowlCore/Sources/HowlCore/OccupationPacks.swift
```

- [ ] **Step 2: Make the type public**

In `mac/Packages/HowlCore/Sources/HowlCore/OccupationPacks.swift`, add `public` to the type, the struct, its stored properties, and `all`:

```swift
public enum OccupationPacks {
    /// Pack metadata for the picker UI. `name` is the display label;
    /// `terms` is the word list applied on selection.
    public struct Pack: Identifiable, Hashable {
        public let id: String       // stable key, also used as the picker tag
        public let name: String     // user-visible label
        public let terms: [String]
    }

    // ... doc comment unchanged ...
    public static let all: [Pack] = [
        // ... pack literals unchanged for now ...
    ]
}
```

No `public init` is needed on `Pack`: every `Pack(...)` literal lives inside `all` (same module), and `DictionaryTab` only reads `.all`/`.id`/`.name`/`.terms`.

- [ ] **Step 3: Regenerate the Xcode project**

The app target globs `Howl/**` for sources; the package globs its own `Sources/`. Regenerate so the moved file leaves the app target's source list. Force the regen — Make compares mtimes and may not notice a *removed* source, leaving a stale `.pbxproj` that still references the old path:

Run: `cd mac && rm -f Howl.xcodeproj/project.pbxproj && make project`
Expected: `xcodegen generate` runs and rewrites `Howl.xcodeproj/project.pbxproj`.

- [ ] **Step 4: Build the app to confirm the reference still resolves**

`DictionaryTab` already `import HowlCore`s, so `OccupationPacks.all` now resolves from the package.

Run: `cd mac && make build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Write the guard test**

Create `mac/Packages/HowlCore/Tests/HowlCoreTests/OccupationPacksTests.swift`:

```swift
import Foundation
import Testing
@testable import HowlCore

@Suite("OccupationPacks")
struct OccupationPacksTests {

    // Each pack must stay within half the whisper prompt budget, so a
    // single pack fits comfortably AND any two packs still fit 896 bytes.
    @Test func every_pack_fits_half_the_whisper_budget() {
        let cap = DictStats.whisperPromptBudgetBytes / 2   // 448
        for pack in OccupationPacks.all {
            let bytes = pack.terms.joined(separator: ", ").utf8.count
            #expect(bytes <= cap, "pack '\(pack.id)' is \(bytes) bytes, over the \(cap)-byte cap")
        }
    }

    @Test func pack_ids_are_unique() {
        let ids = OccupationPacks.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func no_pack_is_empty() {
        for pack in OccupationPacks.all {
            #expect(!pack.terms.isEmpty, "pack '\(pack.id)' has no terms")
        }
    }
}
```

- [ ] **Step 6: Run the guard test**

Run: `cd mac/Packages/HowlCore && swift test --filter OccupationPacks`
Expected: PASS — all 7 current packs are ≤ 377 bytes, well under the 448 cap.

- [ ] **Step 7: Value-order the packs (highest-value first)**

Front-load each pack with the terms whisper most reliably mangles — proper nouns / product names / multi-word terms — since truncation drops the tail when packs combine. Apply this concrete reorder to the `software-engineer` pack as the worked example:

```swift
        Pack(
            id: "software-engineer",
            name: "Software Engineer",
            terms: [
                // Proper nouns / products first (highest mis-transcribe risk)
                "Kubernetes", "Terraform", "Ansible", "Helm", "Docker",
                "PostgreSQL", "MongoDB", "Cassandra", "DynamoDB", "Redis",
                "GitHub", "GitLab", "Bitbucket", "Jenkins", "CircleCI",
                "GraphQL", "WebSocket", "WebRTC", "gRPC", "OAuth", "OAuth2", "OIDC",
                "TypeScript", "JavaScript", "Golang", "Kotlin", "Python", "Rust", "Swift",
                "Jira", "Linear", "Notion",
                "AWS", "GCP", "Azure", "Lambda", "EC2", "S3",
                // Short acronyms last (whisper usually gets these)
                "API", "JWT", "REST", "MCP", "LLM", "RAG", "SDK", "CLI", "IDE",
                "TLS", "DNS", "CDN", "VPN",
            ]
        ),
```

For the other six packs, leave the current order — they already fit and their proper nouns are reasonably front-loaded; reordering them is optional curation, not required for correctness. (The guard test enforces size only, not order, so no test changes here.)

- [ ] **Step 8: Rebuild + re-run tests, then commit**

Run: `cd mac && make build` → expect `** BUILD SUCCEEDED **`
Run: `cd mac/Packages/HowlCore && swift test --filter OccupationPacks` → expect PASS

```bash
git add mac/Packages/HowlCore/Sources/HowlCore/OccupationPacks.swift \
        mac/Packages/HowlCore/Tests/HowlCoreTests/OccupationPacksTests.swift \
        mac/Howl.xcodeproj/project.pbxproj
git commit -m "refactor(dict): move OccupationPacks into HowlCore + size guard

Relocate the vocabulary packs into the package so a test can guard each
against half the whisper prompt budget (448 bytes), and front-load the
software-engineer pack's high-value terms so they survive truncation.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Dictionary tab — STT budget meter + limitations copy

**Files:**
- Modify: `mac/Howl/UI/Settings/DictionaryTab.swift`

**Interfaces:**
- Consumes: `DictStats.whisperPromptFit(from:)` and `DictStats.WhisperPromptFit` (Task 1).
- Produces: UI only.

This task has no unit test — it renders the already-tested helper. Verification is a clean build plus a manual check.

- [ ] **Step 1: Add the always-visible limitations line**

In `DictionaryTab.swift`, in `var body`, add a caption between the add-term `HStack` and `termsCard`:

```swift
            HStack {
                TextField("Add term", text: $newTerm)
                Button("Add") { addManualTerm() }
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Your dictionary also primes speech recognition. Whisper's prompt is small (~224 tokens); past that, extra terms only affect cleanup, not recognition.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            termsCard
```

- [ ] **Step 2: Add the STT budget stat view**

In `DictionaryTab.swift`, add this computed view next to the existing `statsView` (e.g. directly after it):

```swift
    /// Whisper initial-prompt budget — distinct from the LLM-cleanup token
    /// count in `statsView`. The dictionary doubles as whisper's STT prompt,
    /// which has a tiny (~224-token) budget; over it, trailing terms stop
    /// biasing recognition (but still apply during cleanup).
    @ViewBuilder
    private var sttBudgetStat: some View {
        let f = DictStats.whisperPromptFit(from: settings.customDict)
        VStack(alignment: .leading, spacing: 1) {
            Text("Speech-to-text: ~\(f.usedTokens) / \(f.budgetTokens) tokens")
                .font(.caption.monospacedDigit())
                .foregroundStyle(f.overBudget ? Color.orange : Color.primary)
            Text(f.overBudget
                 ? "Over budget — biases only the first \(f.termsThatFit) terms"
                 : "Primes whisper speech recognition")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help("Whisper's initial prompt is tiny (~\(f.budgetTokens) tokens). Terms past the budget still apply during LLM cleanup, but stop biasing recognition.")
    }
```

- [ ] **Step 3: Place the stat in the card header**

In `DictionaryTab.swift`, update `manageSection` to show both stats side by side:

```swift
    @ViewBuilder
    private var manageSection: some View {
        HStack(spacing: 12) {
            statsView
            Divider().frame(height: 28)
            sttBudgetStat
            Spacer()
            Button("Export…") { exportToFile() }
                .disabled(settings.customDict.isEmpty)
            Button("Import…") { importFromFile() }
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Text("Clear all")
            }
            .disabled(settings.customDict.isEmpty)
        }
    }
```

- [ ] **Step 4: Build**

Run: `cd mac && make build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual verification**

Run: `cd mac && make run`
Then in the app: **menu bar → Settings → Dictionary**.
- With a small/empty dictionary: "Speech-to-text: ~N / 224 tokens" shows in primary color, sub-label "Primes whisper speech recognition", and the limitations caption is visible.
- Add several occupation packs (Quick add from preset) until the joined dictionary exceeds 896 bytes: the stat turns orange and reads "Over budget — biases only the first K terms". Confirm the existing "Added to every cleanup request" stat is unchanged beside it.

- [ ] **Step 6: Commit**

```bash
git add mac/Howl/UI/Settings/DictionaryTab.swift
git commit -m "feat(dict): surface whisper STT prompt budget in Dictionary tab

A second, clearly-labeled meter shows the dictionary against whisper's
~224-token initial-prompt budget (distinct from the LLM-cleanup count), with
an always-visible note that over-budget terms still apply during cleanup but
stop biasing recognition.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4 (optional, independent): replay.go dictionary-bias fix

Closes the earlier code-review finding — the Compare/replay harness builds whisper with no initial prompt, so its transcripts lack the dictionary recognition bias the live pipeline has. This is the only Go touch and is independent of Tasks 1–3.

**Files:**
- Modify: `core/internal/replay/replay.go` (~line 114)

- [ ] **Step 1: Add the initial prompt to the replay transcriber**

In `core/internal/replay/replay.go`, the `transcribe.NewWhisperCpp(transcribe.WhisperOptions{...})` call inside `runReplays` builds the shared transcriber. Add the same prompt the live pipeline uses:

```go
			t, err := transcribe.NewWhisperCpp(transcribe.WhisperOptions{
				ModelPath: cfg.WhisperModelPath,
				Language:  cfg.Language,
				// Match the live pipeline (build.go) so Compare reflects the
				// dictionary's recognition bias, not just post-correction.
				InitialPrompt: transcribe.DictionaryPrompt(cfg.CustomDict),
			})
```

- [ ] **Step 2: Build the Go core**

Run: `cd core && go build ./...`
Expected: no output (success).

- [ ] **Step 3: Run the replay + transcribe tests**

Run: `cd core && go test ./internal/replay/... ./internal/transcribe/...`
Expected: `ok` for both packages.

- [ ] **Step 4: Commit**

```bash
git add core/internal/replay/replay.go
git commit -m "fix(replay): apply dictionary initial prompt in Compare runs

replay.go built whisper with no initial prompt, so Compare transcripts
lacked the recognition bias the live pipeline gets from the dictionary.
Mirror build.go's DictionaryPrompt so Compare stays apples-to-apples.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

- [ ] `cd mac/Packages/HowlCore && swift test` — all package tests green.
- [ ] `cd mac && make build` — `** BUILD SUCCEEDED **`.
- [ ] (if Task 4 done) `cd core && go test ./...` — green.
