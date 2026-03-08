# V.05 - Vision Model Size Variants and Qwen3 4B Retirement

**Epic:** Vision Integration
**Status:** Implemented
**Priority:** P1 (High)
**Estimated Effort:** 3-4 days
**Dependencies:** V.02
**Target:** macOS 26 (Tahoe)
**Design Reference:** None

---

## 1. Objective

Expand the local vision model lineup from a single 4B option to three size variants (4B, 8B, 32B) so users with capable hardware can trade accuracy for speed as they see fit. Simultaneously, retire the legacy text-only Qwen 3 4B model (`qwen3_4B` / `"qwen3-4b-instruct-4bit"`) and replace it with the vision-capable Qwen 3.5 4B as the new default. Because the text-only Qwen 3 4B is currently the app default for all users, this requires a migration path that auto-downloads the replacement model and notifies the user without requiring manual intervention.

## 2. User Story

As a user, I want to choose from multiple sizes of the Qwen 3.5 Vision model (4B, 8B, 32B) so that I can balance inference speed against response quality on my hardware, and I want the app to automatically upgrade my existing Qwen 3 4B model to the vision-capable replacement so I do not have to manage the transition manually.

## 3. Scope

### In Scope

- Add `qwen35_8B_Vision` and `qwen35_32B_Vision` enum cases to `ModelIdentifier`.
- Add HuggingFace repo, storage path, required files, estimated size, display name, RAM thresholds, and `supportsImageInput = true` for each new variant.
- Add `knownFiles` entries in `HuggingFaceStrategy` for both new variants (must be verified against actual HF repos before implementing — see Section 5 pre-implementation note).
- Change `ModelsState.primaryLLM` default and `ModelManager.recommendedLLM()` from `.qwen3_4B` to `.qwen35_4B_Vision`.
- Change `AppSettings.primaryLLMModel` default string from `"qwen3-4b-instruct-4bit"` to `"qwen3.5-4b-vision-4bit"`.
- Update `SetupCoordinator.resolvePrimaryLLM()` to treat `.qwen3_4B` as a legacy/deprecated identifier (like existing `.qwen7B`/`.qwen3B` identifiers), resolving it to `.qwen35_4B_Vision` in all flows.
- Update `LLMService` low-RAM warning references and fallback paths to use `.qwen35_4B_Vision` instead of `.qwen3_4B`.
- Update `LLMProviderManager` to reference `.qwen35_4B_Vision` as the baseline local model where `.qwen3_4B` is currently hardcoded.
- Mark `qwen3_4B` with `isLegacy = true` (it already has the mechanism; extend the `isLegacy` computed property).
- Implement **migration UX**: on app launch, if the stored primary LLM is `.qwen3_4B`, automatically begin downloading `.qwen35_4B_Vision`, show an in-app notification/banner with live progress, switch the primary on completion, and handle failures gracefully.
- Surface all three vision size variants in Preferences > Models with RAM guidance.
- Update setup wizard model explanation and download step text for the new default.
- Update all affected unit tests.

### Out of Scope

- Cloud vision support.
- Any VLM inference or agent loop changes (those live in V.02/V.04).
- Changing the ASR or TTS model defaults.
- Deleting on-disk files for the old Qwen 3 4B model automatically (users keep their files; only the primary pointer moves).
- UI to switch between models at runtime mid-session.

## 4. Architecture Alignment

- Keep `ModelIdentifier` as the single enum that describes every model variant. Adding new cases here is the only required schema change.
- Keep `HuggingFaceStrategy` as the download manifests owner. New variants add new `case` branches to `knownFiles(for:)`.
- Keep `ModelManager` as the single source of truth for `primaryLLM`. The migration trigger and download live here.
- The migration download is a silent background download that reuses `ModelManager.downloadModel(_:progress:)`. It is not part of `downloadRequiredModels` (which is setup-flow only).
- Migration notification: use an **in-app banner/toast** in the overlay to show live download progress (the overlay is the natural place — it's always available via hotkey). On completion or failure, post a **single** `UNUserNotification` system notification so the user is informed even if the overlay is closed. Do not use repeated system notifications for progress updates — macOS `UNUserNotificationCenter` does not support live-updating progress bars and replacing notifications repeatedly is UX-hostile. The existing `ModelManager` download infrastructure already tracks `ModelDownloadProgress`; the migration coordinator observes these updates via `NotificationCenter` and drives the in-app banner.
- Migration coordinator: implement as a lightweight `@MainActor` class `ModelMigrationCoordinator` (new file). It checks the persisted primary LLM once on startup, starts the download if needed, and marks migration complete in `UserDefaults`.
- On download failure: keep `.qwen3_4B` as primary, show an in-app error banner with a "Retry in Preferences" action, and post a system notification. Let the user manually trigger the migration from Preferences > Models.
- Threading: migration coordinator runs on `@MainActor`; download itself runs on `ModelManager`'s actor. Progress updates flow via `NotificationCenter` then `@MainActor` then the in-app banner UI.
- RAM thresholds for new variants:
  - 4B Vision: 16 GB (existing)
  - 8B Vision: 24 GB minimum
  - 32B Vision: 48 GB minimum (the verified 32B 4-bit repository is ~19.7 GB on disk, so 48 GB provides realistic headroom on Apple Silicon)

## 5. Implementation Plan (Draft)

**Pre-implementation requirement (CRITICAL):** Before writing any code for the 8B and 32B variants, verify each candidate HuggingFace repo exists and that every file listed in `knownFiles` returns HTTP 200 when fetched with redirects. Per the project MEMORY.md policy, use `curl -sL -o /dev/null -w "%{http_code}"` for each file against both `lmstudio-community/Qwen3-VL-8B-Instruct-MLX-4bit` and `lmstudio-community/Qwen3-VL-32B-Instruct-MLX-4bit`. Large models such as the 32B use sharded safetensors (`model-00001-of-NNNNN.safetensors`); check the HuggingFace API tree to enumerate actual shards and update `knownFiles`/`requiredFiles` accordingly.

### 5.1 Files to Create

- `Ora/Models/ModelMigrationCoordinator.swift` - `@MainActor` class that checks `UserDefaults` for completed migration, triggers background download of `.qwen35_4B_Vision` when primary is `.qwen3_4B`, posts `UNUserNotification` with progress, and marks migration done on success. Also handles retry-on-failure path.

### 5.2 Files to Modify

**Model definitions:**

- `Ora/Models/ModelTypes.swift`
  - Add `qwen35_8B_Vision = "qwen3.5-8b-vision-4bit"` and `qwen35_32B_Vision = "qwen3.5-32b-vision-4bit"` enum cases.
  - Extend `isLegacy` to return `true` for `.qwen3_4B` (in addition to existing `.qwen7B`, `.qwen3B`).
  - Add `displayName`, `huggingFaceRepo`, `storagePath`, `estimatedSizeBytes`, `sizeDisplay`, `requiredFiles`, `expectedFileSizes` (empty dict), `supportsImageInput = true`, `isAdvancedLocalModel = true`, and `minimumSupportedRAMBytes` (24 GB for 8B, 48 GB for 32B) for both new cases.
  - Update `ModelsState.primaryLLM` default: `.qwen3_4B` → `.qwen35_4B_Vision`.
  - Update `ModelsState.hasLegacyModels` (line 325): add `.qwen3_4B` to the legacy check alongside `.qwen7B` and `.qwen3B`.
  - Update `isRequired` for `.qwen3_4B` to `false` (it was `false` via the LLM handling comment; now it is explicitly legacy).

- `Ora/Models/Strategies/HuggingFaceStrategy.swift`
  - Add `case .qwen35_8B_Vision` and `case .qwen35_32B_Vision` to `knownFiles(for:)` with the verified file list.

- `Ora/Models/ModelManager.swift`
  - `recommendedLLM()` → return `.qwen35_4B_Vision`.
  - `loadMetadata()` fallback (currently returns `.qwen3_4B` when persisted model is unsupported): change fallback to `.qwen35_4B_Vision`.

- `Ora/Persistence/Models/AppSettings.swift`
  - `primaryLLMModel` default string: `"qwen3-4b-instruct-4bit"` → `"qwen3.5-4b-vision-4bit"`.

- `Ora/Setup/SetupCoordinator.swift`
  - `loadSystemInfo()` hardcoded `recommendedLLM` constant → `.qwen35_4B_Vision`.
  - `resolvePrimaryLLM()`: because `.qwen3_4B` is now `isLegacy`, the existing `isLegacy` branch already resolves it to the default. Confirm every `return .qwen3_4B` fallback in the function is changed to `return .qwen35_4B_Vision`.
  - Remove or update the guard that returned `.qwen3_4B` when `persistedLLM == .qwen35_4B_Vision && !isRepairFlow`, since `.qwen35_4B_Vision` is now the intended default for all flows.

- `Ora/LLM/LLMService.swift`
  - Low-RAM warning condition (currently `model == .qwen3_4B && totalRAM < 8_000_000_000`): update to reference `.qwen35_4B_Vision` or generalize using `model.minimumSupportedRAMBytes`.
  - Fallback `return .qwen3_4B` → `return .qwen35_4B_Vision`.

- `Ora/Cloud/LLMProviderManager.swift`
  - Any hardcoded `.qwen3_4B` references → `.qwen35_4B_Vision`.

- `Ora/Setup/SetupState.swift`
  - `primaryLLM` default (line 52): `.qwen3_4B` → `.qwen35_4B_Vision`.
  - `recommendedModel` string (line 57): `"Qwen 3 4B"` → `"Qwen3 VL 4B"`.
  - `totalModelSizeDisplay` static computed property (line 73): `.qwen3_4B` → `.qwen35_4B_Vision`.

- `Ora/Setup/Steps/ModelExplanationStepView.swift` and `Ora/Setup/Steps/DownloadStepView.swift`
  - Update model name/size strings if they reference Qwen 3 4B by name.

- `Ora/Preferences/Tabs/ModelsPreferencesView.swift`
  - Surface `qwen35_8B_Vision` and `qwen35_32B_Vision` alongside `qwen35_4B_Vision` with RAM guidance badges.
  - Mark `.qwen3_4B` rows as "Retired" or hide them from new selection (still show as downloaded if present on disk so users can see and delete the files).

- `Ora/Preferences/Tabs/ProviderPreferencesViewModel.swift`
  - Update any hardcoded `.qwen3_4B` default references to `.qwen35_4B_Vision`.

**App startup:**

- `Ora/main.swift` or the existing app delegate / `AppController.swift` startup sequence
  - Call `ModelMigrationCoordinator.shared.runIfNeeded()` after the model manager is initialized and before the overlay is shown.

### 5.3 Tests to Add

- `OraTests/Models/ModelMigrationCoordinatorTests.swift`
  - Migration skipped when persisted primary is already `.qwen35_4B_Vision`.
  - Migration triggered when persisted primary is `.qwen3_4B`.
  - Migration marked complete in `UserDefaults` after download succeeds.
  - Migration not re-triggered after completion flag is set.
  - Primary stays `.qwen3_4B` if download fails; retry flag exposed.

- `OraTests/Models/ModelTypesTests.swift` (extend existing)
  - New variants (`qwen35_8B_Vision`, `qwen35_32B_Vision`) have `supportsImageInput == true`.
  - `qwen3_4B.isLegacy == true`.
  - RAM thresholds: 8B requires 24 GB minimum, 32B requires 48 GB minimum.
  - `activeModels` does not include `.qwen3_4B`.

- `OraTests/Models/HuggingFaceDownloaderTests.swift` (extend existing)
  - `knownFiles(for: .qwen35_8B_Vision)` returns non-empty list.
  - `knownFiles(for: .qwen35_32B_Vision)` returns non-empty list.

- `OraTests/SetupCoordinatorTests.swift` (extend existing, ~6 test methods)
  - `resolvePrimaryLLM(persistedLLM: .qwen3_4B, ...)` resolves to `.qwen35_4B_Vision`.
  - First-run (no persisted LLM) resolves to `.qwen35_4B_Vision`.
  - Repair flow with `.qwen35_8B_Vision` persisted on sufficient RAM resolves correctly.
  - Repair flow with `.qwen35_32B_Vision` on insufficient RAM falls back to `.qwen35_4B_Vision`.

- `OraTests/Models/ModelManagerTests.swift` (extend existing)
  - `recommendedLLM()` returns `.qwen35_4B_Vision`.
  - `setPrimaryLLM(.qwen35_8B_Vision, ...)` on a machine with under 24 GB RAM is rejected.
  - `setPrimaryLLM(.qwen35_32B_Vision, ...)` on a machine with under 48 GB RAM is rejected.

### 5.4 Dependencies/Config

- No new Swift packages required (MLXVLM is already added in V.02).
- `project.yml` — no changes required.
- Notification permission: `UNUserNotificationCenter` (used only for the single completion/failure notification) requires user permission. Request it when the migration coordinator first needs to post. If permission is denied, the in-app banner already covers the user — no silent failure.

## 6. Acceptance Criteria

- [x] AC-1: Ora exposes three local vision model options in Preferences > Models: Qwen3 VL 4B (~3.5 GB, 16 GB RAM minimum), Qwen3 VL 8B (~5.8 GB, 24 GB RAM minimum), and Qwen3 VL 32B (~19.7 GB, 48 GB RAM minimum). Sizes and RAM requirements reflect verified values from the actual HF repos.
- [ ] AC-2: The default primary model for new installs and first-run setup is `qwen35_4B_Vision`, not `qwen3_4B`.
- [ ] AC-3: `qwen3_4B.isLegacy == true`. It does not appear as a selectable model in Preferences > Models for new model selection (but remains available in-code for migration detection).
- [ ] AC-4: On first launch after this update, if the persisted primary LLM is `qwen3-4b-instruct-4bit`, the migration coordinator automatically starts downloading `qwen3.5-4b-vision-4bit`.
- [ ] AC-5: During migration download, an in-app banner in the overlay informs the user of the upgrade with live progress. On completion/failure, a single system notification is posted (if permission granted).
- [ ] AC-6: On migration download completion, the primary LLM switches to `.qwen35_4B_Vision` and a completion notification is shown.
- [ ] AC-7: If the migration download fails, the primary LLM stays as `.qwen3_4B`, an in-app error banner with a "Retry in Preferences" action is shown (plus a system notification if permitted), and the app continues to function normally.
- [ ] AC-8: Migration is not triggered a second time if already completed (idempotent via `UserDefaults` flag).
- [x] AC-9: On a machine with under 24 GB RAM, `qwen35_8B_Vision` is visible but not selectable as primary. On a machine with under 48 GB RAM, `qwen35_32B_Vision` is visible but not selectable.
- [ ] AC-10: All existing text-only and vision flows continue to work after migration; no regressions in `./build.sh test`.

## 7. Verification Plan

### Automated Tests

- [ ] `./build.sh test` — full suite must pass.
- [ ] New `ModelMigrationCoordinatorTests` cover all migration paths (see Section 5.3).
- [ ] `ModelTypesTests` cover new variant properties and `qwen3_4B.isLegacy`.
- [ ] `SetupCoordinatorTests` cover all `resolvePrimaryLLM` branches with the new legacy status.
- [ ] `ModelManagerTests` cover `recommendedLLM()` and RAM-gated `setPrimaryLLM` for new variants.

### Manual Tests

- [ ] Simulate migration: edit the metadata file to set `qwen3-4b-instruct-4bit` as primary, launch app, and confirm migration notification appears with download progress.
- [ ] Let migration complete; confirm notification shows success and Preferences > Models shows `qwen35_4B_Vision` as the active primary.
- [ ] Simulate migration failure (network off during migration download); confirm error notification appears and app still launches normally with `qwen3_4B` still active.
- [ ] On a 16 GB Mac, confirm `qwen35_8B_Vision` and `qwen35_32B_Vision` are visible but blocked in Preferences > Models.
- [ ] On a 24 GB+ Mac, confirm `qwen35_8B_Vision` is selectable and downloads successfully.
- [ ] Run a basic vision turn (image attached) with all three variants on appropriate hardware.
- [ ] Confirm first-run setup (fresh install simulation) downloads `qwen35_4B_Vision` by default.

## 8. Performance / Reliability Considerations

- Migration download runs as a background `Task` and does not block app activation or the overlay hotkey. The user can use Ora normally during migration.
- The 8B and 32B models have significantly longer download times (~5.8 GB and ~19.7 GB on disk). Progress notifications must update incrementally rather than only on completion.
- GPU cache limits set in V.02 for VLM generation continue to apply; no changes needed here.
- The migration coordinator must be idempotent: if the app is killed mid-migration and relaunched, it should resume or restart the download cleanly (rely on `ModelManager.downloadModel` which already handles re-entrant downloads gracefully).
- `UserDefaults` key for migration completion: `"com.ora.migration.qwen35VisionMigrationComplete"`. Check this before triggering migration.

## 9. Risks & Mitigations

- **8B or 32B HF repos may not exist or may have different file layouts**
  - Mitigation: run the curl verification described in the Section 5 pre-implementation note before writing any code. If repos are absent, hold those variants until community MLX conversions are available and only ship the retirement and 4B default change in this story.

- **32B model requires sharded safetensors**
  - Mitigation: check actual file layout during verification. If sharded, update `knownFiles` to enumerate all shards and update `requiredFiles` accordingly. Use the HuggingFace API tree call to enumerate shards automatically if the count varies by conversion.

- **Migration notification permission denied on some systems**
  - Mitigation: the primary progress display is the in-app banner (always works, no permission needed). The system notification is only used for completion/failure and is a nice-to-have. If permission is denied, the user still sees everything in the overlay.

- **`qwen3_4B` marked legacy but still used as fallback in many code paths**
  - Mitigation: the implementation plan above lists all affected files explicitly. Change all fallback constants to `.qwen35_4B_Vision`. Keeping the enum case avoids a wide refactor — only the `isLegacy` flag and default constants need updating.

- **Migration triggers in a repair flow (setup wizard repair)**
  - Mitigation: `ModelMigrationCoordinator` checks `UserDefaults.standard.oraSetupComplete`. Do not trigger migration during the first-run setup flow itself (setup coordinator handles model selection). Only run migration after setup is complete and the app is fully initialized.

## 10. Open Questions

- Do the 8B and 32B HF repos exist as of implementation time? (Must verify before coding — see Section 5 pre-implementation note.)
- Does the 32B model use sharded safetensors? If so, how many shards? (Check HF repo tree.)
- Should the Qwen3 VL 8B also be offered in the setup wizard as an alternative model for users who want higher quality? Currently the plan is 4B as default in setup; 8B/32B only in Preferences > Models.
- ~~What should the notification style be?~~ **Decided:** in-app overlay banner for live progress (always works), single system notification for completion/failure (requires permission, graceful degradation).

---

## Implementation Summary

Implemented with the verified upstream MLX repositories:
- `lmstudio-community/Qwen3-VL-8B-Instruct-MLX-4bit`
- `lmstudio-community/Qwen3-VL-32B-Instruct-MLX-4bit`

The shipping behavior differs slightly from the original draft:
- model-size variants use `8B` and `32B`, not `9B` and `27B`, because those are the available upstream artifacts
- the migration UX uses the existing overlay prompt path plus a retry section in Preferences > Models
- `qwen3_4B` is legacy-only and no longer selectable as a primary model

## Code Review Findings

(TBD by review agent.)

## Completion Status

Implemented on `feat/v05-vision-model-variants` and verified locally with `./build.sh test`, `./build.sh run`, and `codex review`.
