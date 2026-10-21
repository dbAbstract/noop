---
topic: workout-credit
title: How workouts count in the diet budget
keywords: workout calories, workout credit, recorded kcal, counted kcal, played time, bench, futsal, soccer, basketball, intermittent, burned
diet: true
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutBudgetCredit.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/SportEnergy.swift, Strand/Data/DietExpenditure.swift
---
A workout shows two numbers: what was RECORDED, and what the budget COUNTS. Counted is usually lower, for
two reasons.

1. Resting energy is already in the baseline. The recorded figure is gross (resting + active), so the
   resting share of the workout's minutes is subtracted.
2. A strap-recorded session is re-priced from its heart-rate trace with a flex-HR model:
   MET = 1 + max(0, (%HRR − 0.25) / 0.75) × (METmax − 1), with METmax from estimated VO₂max, and
   kcal = MET × kg × hours, capped at the sport's vigorous Compendium value per minute. Older sessions were
   recorded with a model (Keytel) that ran high at easy heart rates.

Intermittent sports (soccer, futsal, basketball and similar): on the bench the heart stays high while the
body rests, so heart rate overstates the cost. "Off" minutes are priced at a recovery pace of 2 MET. The
split comes from the user's confirmed played time, or else from strap motion: a minute counts as played
when its smoothed motion is above a threshold, and a split is only offered when at least 80% of the
session's minutes carry motion. Until the user confirms, played time is UNCONFIRMED.

The coach never proposes a calorie number for a workout. It proposes played minutes
(`workout_played_time`); the app computes the credit and shows before/after on the card.

Typical rotation shares: 3 teams on one pitch ≈ 2/3 played; 4 teams with every team playing every other
≈ 1/2 played.
