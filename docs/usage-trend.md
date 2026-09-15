# Usage pacing chart (personal fork)

Hover a Codex or Claude ring. Codex shows only its main weekly quota (whether the API calls it primary or secondary). Claude starts with Fable Weekly, then the five-hour window, then All Models Weekly. Other available Claude windows follow. Each chart has its own hover cursor and 15-minute controls. The synthetic Claude Daily pace ring is not a quota cycle and is excluded from the charts; the ring setting remains available.

The original card surface, typography and accent are retained. Sessions start collapsed into a single row with a count. Click **Sessions** to expand or collapse the complete list. Cards grow to fit their charts within the display budget; extra charts, account statistics and expanded sessions are vertically scrollable. Expanding sessions keeps the card and its mouse region in place.

- **Target (dashed):** a constant pace from 100% remaining at the start (`reset - duration`) to 0% at reset.
- **Actual (accent):** locally observed remaining quota, with real observation timestamps. History starts when this build begins collecting it; no historical zeroes or synthetic backfill.
- **Forecast (dashed accent):** extends the latest reading using the consumption rate over up to the last hour of continuous readings (at least 15 minutes). With insufficient recent history it uses the average since the quota window started, explicitly labelled. It stops at exhaustion or reset. **Lasts for** estimates the remaining time or states that the allowance lasts until reset under the same workload. Flat consumption does not imply unlimited quota. Stale readings do not produce a forecast.
- **Hover:** snaps to a 15-minute clock grid. Previous/next buttons and accessibility adjustment reach every tick precisely even on a weekly chart. **Now** returns to the current time.
- **Readout:** target at the selected tick, most recent observation at or before it (at most 15 minutes old), and actual minus target in percentage points. Positive means quota in reserve; negative means ahead of the even spending pace. The observation time is shown separately. Future ticks show the target and a separately labelled forecast, when available; predicted values are never stored as observations.
- **Even pace:** the original quota budget per 15 minutes. **From now:** remaining quota divided evenly across the time until reset. In the final partial interval the amount is capped at the quota still available. These are planning values, not a forecast of task cost or a guarantee from the provider.

Only windows with a published duration, reset and percentage offer the chart. Reset timestamps drifting by up to five seconds are matched within the same provider, window and account. This also recovers previously recorded Claude observations fragmented by subsecond reset jitter. The first and last real reading of every 15-minute bucket are retained, so a visible actual segment does not have to wait for the next bucket. History before collection began cannot be reconstructed. Readings are kept locally in UserDefaults, bounded to 120 days and 12,000 samples across providers. Empty clock buckets break the actual line. A reset starts a new cycle. Disabling/signing out or explicitly switching an account clears its history. Cached responses retain their original observation time. When the provider supplies a stable account identifier, a one-way fingerprint separates accounts even across relaunches. No credentials, raw account identifiers, prompts or task contents are stored in chart history.

## Build

Requires macOS 15+, Xcode and XcodeGen. Run `make build` and `make test` (see [CONTRIBUTING](../CONTRIBUTING.md)). This fork does not link or embed Sparkle. Its original automatic update service is unused, and loading its framework in an ad-hoc signed hardened-runtime Release app caused a dyld signature rejection before startup. Update by pulling/building this repository.

The fork does not change the upstream bundle identifier. Quit another Codenotch copy before launching it. A local ad-hoc build is not Apple-notarized.

## Native interaction preview

Launch the built executable with `CODENOTCH_DEMO=trend`. The rings are explicitly labelled Demo and the history is synthetic, in memory only. This mode loads no usage providers. It is used to check all charts together, independent hover scrubbing, the session disclosure and scrolling.

## Package startup check

Run `python3 Scripts/check-app-package.py /path/to/Codenotch-Usage-Trend.zip` on macOS before distributing a local build. It extracts the actual ZIP, checks linked dependencies and signatures, then starts the packaged Release executable for three seconds using the existing test-host guard. This loads the real libraries without polling accounts or terminating an existing Codenotch instance. A signature check alone cannot establish launchability.
