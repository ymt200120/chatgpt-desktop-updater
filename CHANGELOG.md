# Changelog

## 0.2.0.2 — 2026-10-18

- Coordinate rollback and detached activation through durable transaction state
  so a waiting helper cannot reactivate a cancelled update.
- Prepare verified recovery backups before replacing updater files, and retain
  recovery state when activation or restoration is interrupted.
- Keep recovery records and their seals immutable, write activation progress
  separately, and restore files through verified atomic replacements. A saved
  helper provides `-Recover` even when the stable scripts or staging are incomplete.
- Coordinate self-update with the ordinary updater lock and stop on scheduled
  task query errors instead of treating them as a missing task.
- Report incomplete task restoration or pending-marker cleanup as requiring
  recovery rather than a clean activation success.
- Preserve deferred AppX registration state independently of reminder and error
  messages, including legacy deferred state.
- Harden self-update path checks against reparse-point ancestors, disable curl
  URL globbing, and reject mismatched release tags in the release packager.
- Add isolated regression coverage for cancellation, interrupted recovery,
  concurrent operations, postcondition failures, and deferred registration.
- Read transaction JSON explicitly as UTF-8 in both PowerShell runtimes,
  including paths containing non-ASCII characters, spaces, and brackets.
- Real ChatGPT installation continues to require the user's own click on the
  install button; this release does not stop apps or services to force updates.

## 0.2.0.1 — 2026-10-18

- Request Windows deferred registration (`DeferRegistrationWhenPackagesAreInUse`)
  for confirmed installs. When a packaged service or app holds the old package,
  the update is staged and registered after the next Windows sign-in instead of
  failing with `0x80073D02`.
- Report deferred registration as a distinct `Deferred` result and exit code 14,
  never as a completed install. Keep the verified cache entry and candidate;
  the background worker observes completion on its next run, even before the
  seven-day HEAD interval.
- Keep the no-force-close/no-service-stop boundary. If Windows still rejects
  deferred registration, retain the candidate and provide restart guidance.
- Verified on Windows 11 x64 against `CodexSandboxService.OpenAI.Codex`:
  `26.1013.4894.0` was staged with deferred registration, completed at the next
  sign-in, and registered with `Status=Ok`. User data directories were retained.
- Add an explicit updater self-update path (`update-updater.cmd`, `VERSION`
  `0.2.0.1`). It reads a pinned GitHub release manifest, verifies the ZIP and
  every production file with SHA-256, stages the files, and launches a detached
  helper after the current process exits. The background task is paused during
  activation; backups and `-Rollback` are provided.
- Refuse direct updater runs while a self-update is pending. The background
  task never calls `-Apply`; self-update always requires that explicit command.
- Correct package-in-use guidance and missing optional SHA-256 audit values in
  metadata-only background rechecks.
- Add `Test-SelfUpdate.ps1`; the offline suites now total 128 cases across six
  suites in each PowerShell runtime.
- Self-update trust is the pinned GitHub repository over HTTPS plus the user's
  explicit `-Apply`; this release does not embed a separate signing key.
- Windows 11 x64 has been verified. ARM64 and Windows 10 hardware deployment,
  real desktop mouse/focus acceptance, and real task pause/resume during a live
  self-update remain unverified.

## 0.1.0-beta.1 — 2026-10-07

- First source-only community Beta documentation and offline Windows runner.
- Implementation highlights include version and metadata validation, bounded
  segmented downloads, a managed full-package cache, current-user background
  scheduling, and consent-gated installation.
- Current offline suites cover updater validation, managed cache, segmented
  download, background scheduling logic, and confirmation-window event guards.
- The current evidence run covers 53 updater, 16 cache, 19 segmented-download,
  17 background, and 11 UI-events cases in Windows PowerShell 5.1 and
  PowerShell 7.
- Windows 11 x64 was personally verified. ARM64 and Windows 10 hardware
  deployment, real AppX deployment of these modules, and genuine desktop mouse
  and focus acceptance remain unverified or incomplete.

The 0.1.0-beta.1 release was a source-only Beta snapshot.
