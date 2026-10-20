---
topic: baselines
title: Personal baselines, HRV and resting heart rate
keywords: baseline, hrv, rmssd, resting heart rate, rhr, normal for me, calibrating, respiratory rate, skin temperature
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/Baselines.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/ChargeBaselines.swift
---
NOOP judges nightly HRV, resting HR, respiratory rate and skin temperature against the user's OWN rolling
baseline, never a population norm.

- HRV is RMSSD in milliseconds, from overnight beat-to-beat intervals. Higher than your own normal is
  usually better; absolute values vary hugely between people.
- Resting HR is the overnight resting heart rate. Lower than normal is usually better; a sustained rise
  of several bpm can mean fatigue, illness, heat, alcohol or a late meal.

How a baseline is kept
- A recency-weighted average (half-life about 14 nights) with a matching spread. Nights more than 5
  spreads away are rejected as artefacts; others are clamped to 3 spreads before being folded in.
- A baseline is provisional after 4 valid nights and trusted after 14. While young it adapts faster, so
  an unusually high first few nights cannot anchor it.
- 14 nights with no data mark it stale.
- Charge baselines read only the last 21 days. Imported vendor nights seed them until the user has enough
  nights of their own, then drop out.

When a baseline is still calibrating, say the comparisons are provisional rather than treating a z-score
as settled.
