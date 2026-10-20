---
topic: weight-trend
title: The weight trend and whether loss can be told yet
keywords: weight, trend, losing, gaining, plateau, scale, weigh-in, weighed, kg/week, stalled, not losing
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/WeightTrend.swift, Strand/AI/CoachDiet.swift
---
Day-to-day scale weight is mostly water, glycogen, gut contents and sodium. NOOP therefore reports a
trend and how sure it is, never a single reading's change.

- Trend weight: a time-aware moving average with a 10-day half-life. It is for reading; decisions are
  made from the regression.
- Rate: a least-squares line through the weigh-ins since the plan started (up to 42 days), with several
  readings on one day averaged into one. It needs at least 3 distinct days.
- ± margin: 1.96 standard errors of that slope (about 95%). "Distinguishable from no change" is true only
  when the whole range is on one side of zero.

How to talk about it
- If the range includes zero, say it cannot yet be told from no change. Do not call it a loss or a stall.
- How long it takes to tell depends on the deficit and on the user's own scatter: at about 400 kcal/day
  a change usually clears the noise inside a fortnight; at 150 kcal/day it can take over a month.
- Daily weigh-ins under the same conditions (after waking, before food) shorten the wait more than
  anything else.
