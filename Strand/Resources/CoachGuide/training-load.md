---
topic: training-load
title: Training load, ACWR and monotony
keywords: training load, acwr, acute, chronic, monotony, overtraining, fitness, fatigue, form, tsb, deload
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/ReadinessEngine.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/TrainingLoadEngine.swift
---
These read the daily Effort series over weeks. They are trend signals, not prescriptions.

- ACWR (acute:chronic workload ratio): mean Effort of the last 7 days ÷ mean of the last 28. 0.8–1.3 is
  the usual sweet spot; above 1.5 is associated with higher injury risk (Gabbett 2016).
- Monotony (Foster): mean ÷ standard deviation of the last week's daily Effort. High monotony means
  every day is similar, which is associated with staleness and illness; vary hard and easy days.
- Fitness / fatigue / form: exponentially weighted Effort with 42-day (chronic, "fitness") and 7-day
  (acute, "fatigue") time constants; form = fitness − fatigue. These are in Effort units, not TRIMP or
  TSS, and need several weeks of contiguous days. Missing days are not filled with zero.
- The readiness read also flags HRV more than about half a spread below baseline, resting HR above
  baseline, and a rise in sleeping respiratory rate.

All of these describe the user's own data; none is medical advice.
