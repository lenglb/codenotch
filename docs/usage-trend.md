# Usage pacing chart (personal fork)

Hover a Codex or Claude ring. Use the arrows above the chart to select any available timed quota window: session, weekly, model-specific weekly, and additional Codex limits supplied by the provider. The selection is remembered per profile. The synthetic Claude Daily pace ring is not a quota cycle and is excluded from chart navigation. If it leads the ring or was selected by an older build, the chart falls back to a real timed quota window; the Daily pace ring setting remains available. The original card surface, typography, accent, bar and session list are retained; the selected window replaces the expanded list so the card stays a fixed height.

- **Target (dashed):** a constant pace from 100% remaining at the start (`reset - duration`) to 0% at reset.
- **Actual (accent):** locally observed remaining quota, with real observation timestamps. History starts when this build begins collecting it; no historical zeroes or synthetic backfill.
- **Hover:** snaps to a 15-minute clock grid. Previous/next buttons and accessibility adjustment reach every tick precisely even on a weekly chart. **Now** returns to the current time.
- **Readout:** target at the selected tick, most recent observation at or before it (at most 15 minutes old), and actual minus target in percentage points. Positive means quota in reserve; negative means ahead of the even spending pace. The observation time is shown separately. Future ticks show only the target.
- **Even pace:** the original quota budget per 15 minutes. **From now:** remaining quota divided evenly across the time until reset. In the final partial interval the amount is capped at the quota still available. These are planning values, not a forecast of task cost or a guarantee from the provider.

Only windows with a published duration, reset and percentage offer the chart. Readings are kept locally in UserDefaults, bounded to 120 days and 12,000 samples across providers. Empty clock buckets break the actual line. A reset starts a new cycle. Disabling/signing out or explicitly switching an account clears its history. Cached responses retain their original observation time. When the provider supplies a stable account identifier, a one-way fingerprint separates accounts even across relaunches. No credentials, raw account identifiers, prompts or task contents are stored in chart history.

## Build

Requires macOS 15+, Xcode and XcodeGen. Run `make build` and `make test` (see [CONTRIBUTING](../CONTRIBUTING.md)). This fork does not link or embed Sparkle. Its original automatic update service is unused, and loading its framework in an ad-hoc signed hardened-runtime Release app caused a dyld signature rejection before startup. Update by pulling/building this repository.

The fork does not change the upstream bundle identifier. Quit another Codenotch copy before launching it. A local ad-hoc build is not Apple-notarized.

## Native interaction preview

Launch the built executable with `CODENOTCH_DEMO=trend`. The rings are explicitly labelled Demo and the history is synthetic, in memory only. This mode loads no usage providers. It is used to check window selection, hover scrubbing and the screen-edge card.

## Package startup check

Run `python3 Scripts/check-app-package.py /path/to/Codenotch-Usage-Trend.zip` on macOS before distributing a local build. It extracts the actual ZIP, checks linked dependencies and signatures, then starts the packaged Release executable for three seconds using the existing test-host guard. This loads the real libraries without polling accounts or terminating an existing Codenotch instance. A signature check alone cannot establish launchability.
