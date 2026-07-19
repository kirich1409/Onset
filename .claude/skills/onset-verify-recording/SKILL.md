---
name: onset-verify-recording
description: Verify that an Onset recording actually recorded — frame-level checks on the output MP4s (CFR cadence, motion/freeze detection) instead of trusting exit codes, preview, or container metadata. Use after any recording run, L5 capture test, or when diagnosing "recording looks frozen/black/empty".
---

# Onset recording verification

Preview-live ≠ recording-works. A live preview, a green exit code, and plausible container metadata all coexist with a broken file. The FILE is the truth — verify it.

## Where files are

Session subfolders `Onset <timestamp>/` inside the user-selected base directory (default `~/Movies/Onset/`). Pick the newest folder and confirm its timestamp matches your run.

## Checks

1. **CFR cadence** — `scripts/verify-cfr.sh screen.mp4 camera.mp4 60 30`. It reads real packet timestamps; ffprobe container metadata lies about cadence. Slow: ~1 min per 10 min of video. The fresh-content check requires MOTION in frame — a static scene fails falsely, so ensure something moves during capture (drive a window, play a cursor sweep).
2. **Freeze detection** — when a file is suspected frozen: `ffmpeg -i file.mp4 -vf freezedetect -f null -` and/or `mpdecimate` frame-drop counting. A frozen recording with live preview is a known failure mode.
3. **Device-vs-pipeline discrimination** — when frames are missing, use `ffmpeg -f avfoundation` as an independent third-party capture of the same device: if ffmpeg gets frames and Onset doesn't, the bug is in the pipeline; if neither gets frames, it's the device/OS.
4. **Trust streaming telemetry, not tech-info** — in-app "technical info" panels can show healthy stats over a dead stream; per-frame streaming telemetry (drop counters, PTS progression) is the signal.
5. **fps claims** — measure by wall-clock frame counts from the file, not `nominalFps`/PTS labels (cameras announce 60 and deliver ~20).

## Verdict rules

- PASS = verify-cfr green on both files + motion present + duration matches the driven scenario.
- Any "it should be fine" without a file-level check is NOT a pass.
