---
topic: measured-burn
title: Measured burn and deficit recalibration
keywords: measured burn, calibration, calibrated, adaptive, metabolism, real tdee, intake-derived, recalibrate, adjust deficit, true expenditure
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/AdaptiveExpenditureEngine.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/CalorieTarget.swift, Strand/Data/DietTrend.swift
---
NOOP can read the user's real average expenditure back out of what they logged and how their weight
moved: expenditure = intake − change in stored energy, at 7,700 kcal per kg.

When it is available
- A window of 21–42 days (the most recent ones), with logged intake on at least 14 days AND at least 70%
  of the window, plus at least 6 weigh-ins. Most early installs do not qualify; that is normal.
- Confidence: high (window ≥ 28 days, coverage ≥ 90%, ≥ 12 weigh-in days), moderate (≥ 21 days,
  ≥ 80%), otherwise building.

It is always a RANGE. The interval combines water swings, a ±5% reporting error, and an upward allowance
for unlogged days (assumed 35% bigger than a logged day, because the days people skip are restaurant
meals and travel). A rough-tagged day carries 0.4 of that allowance, which is why guessing beats skipping.

What it changes
- Nothing automatically. The user can adopt it as their baseline on the diet screen; the measured
  baseline is the average expenditure minus the window's average activity, so steps and workouts still
  ride on top each day.
- Once the weight trend is distinguishable from zero, the app may propose a new deficit: it closes half
  the gap between expected and actual loss (shortfall kg/week × 7,700 ÷ 7 × 0.5), clamped to
  50–750 kcal/day, and only if the change is at least 25 kcal.

It describes logging plus weight, not metabolism: it does not diagnose a "slow metabolism".
