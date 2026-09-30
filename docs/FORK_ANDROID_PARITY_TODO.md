# Fork-local Android parity TODO

**Read this before touching `android/` on this fork.**

Everything below was built on the Apple side only. `AGENTS.md` normally requires the Kotlin twin in the
same PR; that rule was deliberately suspended here so the diet work could be validated on one platform
first. This file is the ledger of what is owed, so the Android work can be done later without
archaeology.

Nothing here is a bug. It is all accepted, tracked debt.

---

## Why the debt exists

This fork adds a **food and diet-targeting feature** that upstream does not have. It was built
iOS-first because:

1. The author's test device is an iPhone with a WHOOP 5.0, so only the Apple side could be validated
   against real strap data.
2. The data model changed twice during the build (UserDefaults → SQLite once backup coverage was
   understood), and committing Room to a schema mid-design would have meant migrating twice.

The Apple side is now settled. Android can follow the finished shape rather than chasing it.

---

## The parity contract that still applies

From `AGENTS.md`, unchanged and non-negotiable when the twin is written:

- **Analytics and stored data must be byte-identical.** Verify by ORACLE, not by eye: compile the Swift
  helper standalone over a spread of inputs and paste its stdout verbatim as the Kotlin test's expected
  literal. Reading the two implementations side by side does not catch what this does.
- **Room column ORDER must match the GRDB `create(table:)` exactly.** Room emits columns in declaration
  order; a reordering is a real schema divergence even when every column is present.
- **Both `schema_oracle.json` copies must stay byte-identical** — `Packages/WhoopStore/Tests/WhoopStoreTests/Resources/`
  and `android/app/src/test/resources/`. The new tables are currently marked `"platform": "ios_only"`;
  flip each to `"both"` and fill in the Android column order when its Room entity lands.
- **Cross-platform hashes/dedup keys** must use a platform-neutral algorithm — never Swift `hashValue`
  or Kotlin `hashCode` for anything crossing the `.noopbak` boundary.

---

## 1. Pure analytics — `Packages/StrandAnalytics/` → `com.noop.analytics`

All of these are pure functions with no store or UI. They are the highest-value twins to write first,
because the oracle-test approach works cleanly on them and everything else depends on their numbers.

| Swift | Kotlin twin needed | Notes |
|---|---|---|
| `NutritionMath.swift` | `NutritionMath.kt` | `MacroTotals`, portion scaling, day totals, Atwater 4/4/9 consistency check. Non-finite/negative portions collapse to zero — pin that, it is the NaN guard. |
| `DietGoal.swift` | `DietGoal.kt` | Goal weight + months → daily deficit. Pace bands (gradual/aggressive/unsafe) and the BMI 18.5 destination floor. |
| `CalorieTarget.swift` | `CalorieTarget.kt` | **Mifflin-St Jeor** BMR (NOT the Harris–Benedict in `WorkoutDetector`), activity multipliers 1.2/1.375, day assembly, damped+clamped recalibration. |
| `StepNeat.swift` | `StepNeat.kt` | Steps above a 3,000 baseline → kcal at `0.0004 × weightKg` per step. |
| `TimeWindows.swift` | `TimeWindows.kt` | Interval merging so overlapping workouts never subtract a shared second twice. |
| `WeightTrend.swift` | *(stage 2, on branch `diet-trend`)* | EWMA trend weight, regression slope + standard error, detectability window. Not yet merged. |

**Two constants that must not drift:** `AdaptiveExpenditureEngine.kcalPerKg` (7,700) is shared by
`DietGoal` and `WeightTrend` rather than redeclared, because one converts a deficit into expected loss
and the other reads expenditure back out of observed loss — if they disagreed the app would predict
against one number and measure itself against another. Keep that sharing in Kotlin.

---

## 2. Storage — GRDB migrations needing Room twins

Two migrations, both currently `ios_only` in the schema oracle.

### `v48-food-log` — `foodItem`, `foodEntry`

Column order (authoritative — Room must match):

```
foodItem   id, deviceId, name, servingLabel, kcal, protein, carbs, fat, fiber, createdAt, lastUsedTs
foodEntry  id, deviceId, day, itemId, nameSnapshot, portion, kcal, protein, carbs, fat, fiber,
           loggedAt, mealType
```

Indices: `idx_foodItem_device_used (deviceId, lastUsedTs)`, `idx_foodEntry_device_day (deviceId, day)`.

Design points the twin must preserve:
- `foodEntry` carries a **snapshot** of name and macros. Editing a library item must not rewrite what a
  past day says you ate; deleting it must not strand the history. `itemId` is nullable and has **no
  foreign key** for exactly that reason — it exists only so the picker can offer "log this again".
- Names are **not** unique. Two foods can honestly share one ("porridge" made two ways).

### `v49-diet-goal` — `dietGoal`

```
dietGoal   id, deviceId, startedOn, endedOn, startWeightKg, targetWeightKg, months, activityLevel,
           dailyDeficitKcal, targetOverrideKcal, createdAt
```

Index: `idx_dietGoal_device_started (deviceId, startedOn)`.

- **Rows, not a row.** Superseding a goal sets `endedOn`; nothing is deleted. A day logged in March must
  still resolve against the target that governed it then, or past adherence silently changes whenever
  the plan does.
- `dailyDeficitKcal` is stored rather than recomputed, so a past day keeps the number it was judged
  against even after the weight it was derived from has moved.

### `deviceScopedTables`

`foodItem`, `foodEntry` and `dietGoal` are all registered in
`Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift`. The Android twin needs the same, or
"forget this source" deletes the day totals in `metricSeries` and leaves the detail on disk — a delete
that looks complete on every chart and is not. A guard test catches this on the Swift side; add its
Kotlin equivalent.

---

## 3. `metricSeries` keys — no schema change, but the writers must match

These are written into the existing tall table, so Android needs the same source ids and key strings or
the two platforms produce series that cannot be compared.

| Source id | Keys |
|---|---|
| `food-log` | `calories_in`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g` |
| `weight-log` | `weight` |
| `diet` | `calorie_target`, `diet_expenditure` |

`fiber_g` is **new** — the existing nutrition CSV importer has no fibre column, so this key did not
previously exist on either platform.

`diet_expenditure` is deliberately **not** `energy_kcal`. That key is NOOP's own heart-rate figure and
this is a second, different answer to the same question; sharing a key would let one silently stand in
for the other on a chart, which is precisely the comparison the feature exists to make visible.

---

## 4. App-layer / UI

| Swift | Android equivalent |
|---|---|
| `Strand/Data/FoodLogStore.swift` | `com.noop.analytics.FoodLogStore` over Room |
| `Strand/Data/DietExpenditure.swift` | the day-assembly orchestration |
| `Strand/Screens/FoodLogView.swift`, `AddFoodSheet.swift` | food logging UI |
| `Strand/Screens/DietGoalSheet.swift` | goal setup (target weight + months slider) |
| `Strand/Screens/DietBudgetCard.swift` | Today's diet card |
| `Strand/Screens/DietDetailView.swift` | diet detail screen |
| `TodaySection.diet` (`Strand/Data/TodayLayoutPrefs.swift`) | matching `TodaySection` entry — **raw key `"diet"` appended LAST**, default order position directly after `hero` |
| `TabRoute.food`, `TabRoute.diet` | `Destination` entries in `ui/AppRoot.kt` |
| `MetricCatalog` additions | `TrendsExploreScreen` metric specs |

`TodaySection`'s raw keys are a byte-identical wire format across platforms (`today.sectionOrder`), so
`"diet"` must be appended last in the Kotlin enum too — the back-fill relies on position.

---

## 5. The step-attribution logic — the subtle one

`DietExpenditure.workoutStepsForDay` is where the real care went. Android needs the same behaviour:

1. Take **deduped** workouts (`Repository.workoutRows` collapses strap/Apple twins). Using raw store rows
   would subtract the same session twice.
2. **Merge overlapping windows** before counting. Two distinct sessions that intersect would otherwise
   have their shared minutes subtracted twice.
3. Count steps per window from the strap's cumulative counter, divided by `stepTicksPerStep`.
4. NEAT steps = daily steps − workout steps − sedentary baseline, floored at zero.

**Why workout steps are excluded at all:** they are already counted by heart rate at their *true
intensity*. 2,000 incline-treadmill steps cost far more than 2,000 walking to the shop, and a flat
per-step rate cannot tell them apart — leaving them in would both double-count and misprice them.

**Degrade conservatively.** Where the strap cannot answer (WHOOP 4.0 has no counter; a 5.0 has nothing
until the window offloads), return **0 excluded steps**, not nil. Those steps then stay in NEAT at the
flat walking rate — an under-credit of a hard session rather than an invented one.

---

## 6. Non-diet changes also owed

- **Calorie source precedence** (`MetricCatalog.todayCaloriesMetric`, key `noop.preferStrapCalories`) —
  an opt-in that prefers NOOP's own estimate over Apple Health's. Useful to anyone without an Apple
  Watch and the most plausible candidate for upstreaming, but currently entangled with food-log changes
  in the same files.
- **HealthKit entitlement removal** (`project.yml`) — Apple-only, nothing owed.
- **Dev build markers** (`NOOP_DEV_BUILD`, `AppIcon-Dev`) — Apple-only, nothing owed.

---

## 7. Known gaps NOT introduced here

Worth fixing while in the area, but pre-existing on both platforms:

- **Hydration entries and caffeine intakes are still in UserDefaults/SharedPreferences**, so they are
  **not in `.noopbak`**. A restore returns their day totals and silently loses the per-entry detail. The
  food log had this same hole and it was closed by moving to SQLite (`v48`); these two still have it.

---

## Suggested order

1. Pure analytics twins with oracle tests — cheapest, and everything else depends on their numbers.
2. `v48` + `v49` Room migrations, schema oracle flipped to `"both"`, `deviceScopedTables` guard.
3. Store layer and the day-assembly orchestration.
4. UI: food logging, then goal setup, then the Today card and detail screen.
5. Flip the oracle entries and delete the corresponding rows from this file as each lands.
