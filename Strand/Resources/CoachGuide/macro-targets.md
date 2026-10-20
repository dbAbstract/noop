---
topic: macro-targets
title: Protein, fat and carbohydrate targets
keywords: macros, protein, protein target, fat, carbs, carbohydrate, grams, g/kg
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/MacroTargets.swift
---
The day's calorie budget is divided into three parts:
- Protein = the user's chosen rate × bodyweight. The rate is set on the goal, 0.8–2.0 g/kg, default 1.2.
  1.6–2.2 g/kg is the range studied for people lifting several times a week; 1.2 suits someone who
  is not. It is the user's choice.
- Fat floor = 0.7 g/kg. A minimum, not a target: eating more fat is fine, it just leaves fewer carbs.
- Carbohydrate = whatever the budget has left after protein and the fat floor (4 kcal/g protein and carbs,
  9 kcal/g fat).

Because carbs are the remainder, they rise on training days when the budget rises. If protein and the fat
floor alone exceed the budget, the app flags it rather than showing 0 g of carbs: the deficit and the
protein rate are asking for incompatible things.
