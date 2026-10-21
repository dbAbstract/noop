---
topic: rough-estimates
title: Rough-estimate tags on food
keywords: rough, rough guess, rough estimate, rough tag, eyeballed
diet: true
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/AdaptiveExpenditureEngine.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/WeeklyDietReview.swift
---
A rough tag says the AMOUNT eaten is uncertain (an eyeballed portion, a restaurant meal, a recalled
day). It does not change the calories or macros logged.

Effects
- That day's intake counts as less certain: in the measured-burn estimate it widens the range upward
  (0.4 of the allowance an unlogged day gets), but it still counts toward coverage.
- Any rough day inside a weekly report's comparison span makes that week's alignment "uncertain".

Guidance: tag genuine guesses. Packet figures, weighed portions and rows from a stored nutrition PDF are
not rough. Logging a rough guess is always better than skipping the meal.
