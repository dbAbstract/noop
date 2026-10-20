---
topic: rest-and-sleep
title: Rest score, sleep need and sleep debt
keywords: rest score, sleep, slept, sleep score, deep sleep, rem, light sleep, sleep efficiency, sleep need, sleep debt, nap, bedtime
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/SleepDebt.swift
---
Rest (0–100) is the night's sleep quality. In the coach's daily lines, "rest Xh" is hours asleep; the
Rest SCORE is the composite below.

Rest score = weighted sum of four parts, each 0–1:
- Duration 50%: hours asleep ÷ sleep need, capped at 1.
- Efficiency 20%: time asleep ÷ time in bed.
- Restorative 20%: (deep + REM) share of sleep against a 50% target, scaled down (never below half) when
  deep sleep is under 13% of the night.
- Consistency 10%: regularity of sleep timing (neutral 0.5 when unknown).

Sleep need starts at 8 h for adults (9 h under 18). After 7 scorable nights it is personalised to the
user's upper-quartile night (what they sleep when unrestricted), but never below the age target and never
above 9.5 h, so a chronic short sleeper cannot "learn" a lower need.

Sleep debt looks at the last 14 nights. Each night, need plus the current debt is compared with sleep;
55% of whatever was missed carries into the next night. Extra sleep pays debt down but never builds a
surplus. Debts under 10 minutes are cleared. Nights without data are skipped, never counted as zero.

Stages come from a consumer strap's motion and heart rate, not a sleep lab: treat deep/REM splits as
estimates, and trends over a week as more meaningful than one night.
