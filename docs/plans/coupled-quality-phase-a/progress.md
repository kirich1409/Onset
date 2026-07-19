# Progress: Coupled recording quality — Phase A

> Plan: ./plan.md · Tasks: ./tasks.md

## Status
- [x] T-1 — ChipTier pure enum
- [x] T-2 — ChipTierDetector (pure parse + impure sysctl)
- [x] T-3 — Per-tier budget switch + safe-low
- [x] T-4 — makeDefault(chipTier:) seam
- [x] T-5 — Document ChipTier / budget flow + refresh stale inline docs
- [ ] T-6 — L5 M3 Max worst-case budget calibration (AC-Q4) — remaining hardware gate

## Learnings
<!-- Append one line per completed task: surprises, gotchas, decisions taken during implementation. -->
- T-1 (DONE): ChipTier + ChipTierTests; full-synthesis recipe compiled as planned (no explicit witnesses); build+lint+L2 green. Report: swarm-report/coupled-quality-phase-a-report-T-1.md.
- T-2 (DONE): ChipTierDetector (pure parse + impure sysctl) + ChipTierDetectorTests; concrete sysctl recipe (String(decoding:), NUL-trim, 3 unsafe sites) compiled 0-warnings; build+lint+L2 green. Report: ...-report-T-2.md.
- T-3 (DONE): EngineBudgetCap.budgetCap(for:codec:) exhaustive switch (m3Max 622.08M floor w/ blocker-warning comment, uncalibrated 248.83M) + EngineBudgetCapTierTests (dynamic never-exceed over allCases, seeded-strict, AC-Q7 fits); build+lint+L2 green. Report: ...-report-T-3.md.
- T-4 (DONE): makeMVPDefault trailing defaulted budgetCap param (mvpDefault byte-identical) + makeDefault(chipTier:); RecordingConfigurationTests (995M unchanged, .m3Max=622.08M, .uncalibrated=248.83M, only-budgetCap-differs); full suite green. Report: ...-report-T-4.md.
- T-5 (DONE): docs/architecture.md device-budget flow + #262 reconciliation + floor-vs-ceiling; mvpDefault/EngineBudgetCap docstrings de-staled (no more placeholder/AC-5/MUST-recalibrate); lint green. Report: ...-report-T-5.md.
