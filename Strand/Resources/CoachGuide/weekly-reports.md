---
topic: weekly-reports
title: Weekly diet reports, balance and alignment
keywords: weekly report, week review, balance, alignment, consistent, mismatch, uncertain, calories in, calories out
diet: true
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/WeeklyDietReview.swift, Strand/Data/WeeklyDietReports.swift
---
Each Monday–Sunday report sums calories in and estimated calories out for the days that have them;
missing days stay unknown, never zero. Balance is in − out over the days that have both.

Alignment asks whether the calories and the scale tell the same story. The weight trend is fitted over
the 5 weeks before plus the week itself; the calorie side is the average daily balance between the first
and last weigh-in, converted at 7,700 kcal/kg.
- consistent: the measured rate is within the trend's ± margin of the calorie-predicted rate.
- mismatch: it is outside that margin.
- uncertain: the comparison was not made, for one reason, checked in this order:
  insufficientWeight (under 21 days between first and last weigh-in, or under 6 weigh-in days),
  staleWeight (the last weigh-in is more than 7 days before the report's Sunday), missingCalories (a day
  in the span lacks intake or expenditure), unknownBurnSource, calibratedBurn (expenditure came from a
  measured baseline, itself derived from the weight trend), roughEstimates (any rough-tagged day in the span), scatter (the margin is as
  big as the effects being compared).

So a user who tags every day rough will always see "uncertain", by design. Rough tags are right for
genuine guesses; packet figures, weighed portions and PDF rows do not need them.
