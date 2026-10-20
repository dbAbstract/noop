---
topic: effort
title: Effort — daily cardiovascular load
keywords: effort, strain, load, trimp, how hard, exertion
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/StrainScorer.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/HRZones.swift, Strand/Data/Profile.swift
---
Effort (0–100) is how much cardiovascular work the day contained, from heart rate. It is logarithmic: going
from 80 to 90 takes far more work than going from 20 to 30. It used to be WHOOP's 0–21 Strain scale;
multiply a 0–21 figure by 100/21 to compare.

How it is computed
1. Heart-rate reserve (Karvonen): HRR = HRmax − resting HR. HRmax is the user's override in Settings, or
   the Tanaka formula 208 − 0.7 × age.
2. Each heart-rate sample becomes %HRR = (HR − resting) / HRR.
3. Samples accumulate TRIMP (training impulse) with Edwards' five zones: time at 50/60/70/80/90 % HRR
   earns weight 1/2/3/4/5 per minute.
4. Effort = 100 × ln(TRIMP + 1) / ln(7201). 7200 is a full 24 hours in the top zone, so 100 is
   practically unreachable.

It needs about 10 minutes of heart-rate coverage before it shows a value. Effort counts heart rate only:
heavy lifting with short sets, or a cold-weather session, can read lower than it felt.

Effort is not calories. The diet budget prices workouts separately (topic `workout-credit`).
