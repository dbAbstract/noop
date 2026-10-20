---
topic: diet-goal
title: Diet goals, deficits and safe pace
keywords: goal, target weight, timeline, deficit, how fast, lose weight, pace, safe, aggressive, bmi
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/DietGoal.swift
---
A goal is a target weight and a timeline in whole months. The daily deficit follows from it:
deficit = (current kg − target kg) × 7,700 kcal/kg ÷ days, with months of 30.44 days.

Pace is judged as a share of CURRENT bodyweight per week:
- up to 0.5%/week: gradual,
- up to 1%/week: aggressive, allowed but lean mass is more at stake,
- over 1%/week: refused.
A target below BMI 18.5 is refused, and the model only describes loss (a target at or above current
weight is refused).

Expected loss per week = deficit × 7 ÷ 7,700. 7,700 kcal/kg assumes the change is fat; early loss
includes glycogen and water, so the first weeks often move faster than predicted and then slow.

The coach can propose a goal; it opens the user's goal editor and nothing changes until they save it.
