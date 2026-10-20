---
topic: diet-budget
title: The daily calorie budget and expenditure
keywords: budget, calories left, kcal left, expenditure, tdee, burn, bmr, neat, steps, deficit today, how many calories, calorie target, maintenance
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/CalorieTarget.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/StepNeat.swift, Strand/Data/DietExpenditure.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/DietDayBoundary.swift
---
The budget is what may be eaten today: today's expenditure minus the goal's daily deficit. It is never
negative.

Expenditure = baseline + step NEAT + workout credit
- Baseline: Mifflin–St Jeor BMR × 1.2. BMR = 10 × kg + 6.25 × cm − 5 × age, +5 for men, −161 for women, the midpoint (−78)
  for non-binary.
  1.2 means "a day with no measured movement"; there is deliberately no activity-level picker, because
  movement is measured below and a picker would count it twice. If the user has adopted their measured
  burn (topic `measured-burn`), that replaces BMR × 1.2.
- Step NEAT: steps outside workouts above a 4,000-step baseline, priced at 0.0003 kcal per step per kg of
  bodyweight. A WHOOP 4.0 has no step counter, so this part is zero there.
- Workout credit: each workout's priced energy minus the resting share the baseline already covers,
  capped per sport (topic `workout-credit`).

The budget therefore rises through the day as steps and workouts arrive, and a rest day's budget is lower
than a training day's. That is intended, not an error.

NOOP's own "active energy" figure is a separate heart-rate estimate shown beside this model; the two
answer different questions and can differ by hundreds of kcal.

Which day food belongs to: the diet day rolls over at sleep, not midnight. Before 04:00, food goes on the
previous day until at least 3 hours of sleep have been recorded since midnight. Every other metric still
uses midnight.
