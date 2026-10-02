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

## 0. READ FIRST — stage 5 MODIFIED shared analytics, it did not only add to them

Every stage before this one only ADDED pure files, so the Kotlin side was merely incomplete. Stage 5 is
the first to change an engine that **already has a Kotlin twin**: `AdaptiveExpenditureEngine`.

Two consequences:

- **The Kotlin twin and its oracle test now disagree with Swift**, and that disagreement is the parity
  contract doing its job rather than a bug to route around. Do not silence it by regenerating the Kotlin
  expectations from Kotlin — re-derive them from the Swift side, per the oracle rule in `AGENTS.md`.
- **The change is behavioural, not cosmetic.** `lowerKcal`/`upperKcal` are no longer symmetric about
  `estimatedDailyKcal`, there is a new `intakeIsRough` input and a new `roughIntakeDays` output, and
  three new constants (`baseReportingError`, `unloggedDayExcess`, `roughGuessDiscount`). A Kotlin twin
  that keeps the old symmetric margin will hand Android users a measurably tighter budget.

What changed and why, in one line: the days someone fails to log are the big ones, so an estimate taken
over logged days is biased LOW — the old code said so in a comment and then widened the interval evenly,
which presents a bias as noise.

---

## 1. Pure analytics — `Packages/StrandAnalytics/` → `com.noop.analytics`

All of these are pure functions with no store or UI. They are the highest-value twins to write first,
because the oracle-test approach works cleanly on them and everything else depends on their numbers.

| Swift | Kotlin twin needed | Notes |
|---|---|---|
| `NutritionMath.swift` | `NutritionMath.kt` | `MacroTotals`, portion scaling, day totals, Atwater 4/4/9 consistency check. Non-finite/negative portions collapse to zero — pin that, it is the NaN guard. |
| `DietGoal.swift` | `DietGoal.kt` | Goal weight + months → daily deficit. Pace bands (gradual/aggressive/unsafe) and the BMI 18.5 destination floor. |
| `CalorieTarget.swift` | `CalorieTarget.kt` | **Mifflin-St Jeor** BMR (NOT the Harris–Benedict in `WorkoutDetector`), activity multipliers 1.2/1.375, day assembly, damped+clamped recalibration. |
| `StepNeat.swift` | `StepNeat.kt` | Steps above a **4,000** baseline → kcal at **`0.0003 × weightKg`** per step. **Use these numbers, not the ones in the first draft** (3,000 / 0.0004) — see the note below. |
| `TimeWindows.swift` | `TimeWindows.kt` | Interval merging so overlapping workouts never subtract a shared second twice. |
| `WeightTrend.swift` | `WeightTrend.kt` | EWMA trend weight (time-aware, 10-day half-life), least-squares slope + standard error, detectability window. `confidenceK` is 1.96; a fit needs >=3 DISTINCT days. |
| `AdaptiveExpenditureEngine.swift` | **twin EXISTS and now diverges** | See section 0. Asymmetric interval (upward only, for unlogged and rough days), `intakeIsRough` in, `roughIntakeDays` + `isLikelyUnderstated` out. `unloggedDayExcess` (0.35) is the one assumed figure and must match exactly or the two platforms price budgets differently. |
| `CalorieTarget.swift` (additions) | `CalorieTarget.kt` | `measuredBaseline(measuredTdeeKcal:meanActivityKcal:)` and `sanitisedBaselineOverride`. The subtraction is the double-count guard — a measured average TDEE already contains its window's average activity. The BMR floor REFUSES rather than clamps. |
| `ProgressiveBurn.swift` | `ProgressiveBurn.kt` | What has been spent SO FAR today. **The contract is an identity, not a formula**: at elapsed 24h the result must equal `dayExpenditure.totalKcal` EXACTLY, which is why the waking rate is solved rather than chosen. Only the BASELINE is prorated — step NEAT and workout kcal are measured-to-date and are added whole, or an early workout gets discounted. No recorded sleep falls back to linear AND reports which path ran. The running total is capped at the day's baseline, so a nap cannot push it past the figure it converges on. |
| `MealGrouping.swift` | `MealGrouping.kt` | Which meal an entry belongs to, and grouping with subtotals. **`breakfastEndsMinute` is 11:00, not the conventional 10:00** — see the note below. Explicit meal always beats the clock; an unknown time infers NOTHING and lands in `unassigned`. Empty groups are dropped. The `Meal` raw values are the `foodEntry.mealType` wire format, so a rename orphans every logged entry. |
| `WakeBriefWindow.swift` | `WakeBriefWindow.kt` | When a wake-triggered morning brief is due. Pure minute-of-day arithmetic. The case to get right: the target has usually ALREADY PASSED, because a strap reports its night on offload rather than on waking — so "late" is normal and must fire, while "hours late" must not. The cutoff is checked against the TARGET before the waiting check, or a target already past the cutoff reports `waiting` for something that can never become due. |
| `MacroTargets.swift` | `MacroTargets.kt` | Budget → protein (user-set g/kg, slider 0.8–2.0, default **1.2**), fat FLOOR at 0.7 g/kg, carbs as the remainder. The invariant to pin: the three targets spend exactly the budget. `isOverCommitted` must be surfaced, not hidden — 0 g of carbs on its own reads as a rounding artefact rather than a plan that does not fit. |
| `MacroEstimateParse.swift` | `MacroEstimateParse.kt` | Pulls macros out of an LLM reply. Tolerant about wrapping (fences, prose, nested objects, braces inside strings), strict about content. **A truncated reply must FAIL, never be salvaged**, and a reply whose kcal contradicts its own macros is refused rather than repaired. Ceilings collapse to zero rather than capping. |
| `RecipeMath.swift` | `RecipeMath.kt` | Composes a recipe from its parts through the SAME portion-scaling helper a logged entry uses. **A missing ingredient refuses the total** (nil, not a partial sum) — an absent number and a smaller number are different claims. Empty recipe composes to zero and counts complete. Zero quantities are invalid, and ordinals renumber dense. A part is either a `Reference.library(id)` (looked up, can go missing) or a `Reference.inline(macros)` (carried, cannot) — an inline part must NEVER consult the lookup, or every ad-hoc recipe is refused. |

**On the 11:00 breakfast boundary, which looks wrong and is not.** The fork owner wakes at 09:30–10:30 and
takes their first meal at 11:30 as LUNCH, having skipped breakfast. A conventional 10:00 boundary labels
that a late breakfast, and the day then shows a breakfast they did not eat and no lunch they did. An early
riser's 10:30 breakfast still reads correctly either way, so the generosity costs nothing. Do not "correct"
this to 10:00 in the Kotlin twin.

**On the step constants, which were revised after real use.** The first pass used a 3,000-step baseline
and 0.0004 kcal/step/kg; both over-credited NEAT, together by roughly 2x, and on a 10,000-step day that
is 204 kcal of claimed burn against an honest ~131. For a user on a 169 kcal/day deficit that erased
most of it — a diet that plateaus while every figure on screen says it is working, which is the hardest
failure to notice from the inside.

- **Baseline 4,000.** Tudor-Locke & Bassett class under 5,000 steps/day as sedentary and 5,000–7,499 as
  low-active (no sport or exercise at all); adult accelerometer means sit near 4,800–5,100. 3,000 was not
  a cautious baseline, it was a low one, and a low baseline charges for ordinary pottering. 4,000 is the
  deliberately conservative middle, held below 5,000 because the baseline and the x1.2 multiplier
  describe the SAME incidental movement and moving one alone would subtract it twice.
- **Rate 0.0003.** 0.0004 derives from 2.5 net METs, which is DELIBERATE walking at ~4.8 km/h. The steps
  reaching this function have already had workouts and the baseline removed, so what remains is slow,
  fragmented movement at 1.0–1.5 net METs. Honest range is 0.00025–0.0003; the top of it is taken.
- **Err low, on purpose.** Under-crediting is visible (you lose faster than predicted); over-crediting is
  invisible. `AdaptiveExpenditureEngine` overrides this from the scale once it has the data, so these
  constants only govern the first few weeks — which is exactly when trust is being decided.

**On the protein default.** 1.2 g/kg is deliberately below the usually-quoted 1.6–2.2. That range comes
from studies on people training several times a week; the lifting stimulus is what creates the demand.
The fork owner lifts roughly once a fortnight and holds their numbers at 1.2. Do not "correct" this in
the Kotlin twin — a different default would make the two platforms prescribe different diets.

**Two constants that must not drift:** `AdaptiveExpenditureEngine.kcalPerKg` (7,700) is shared by
`DietGoal` and `WeightTrend` rather than redeclared, because one converts a deficit into expected loss
and the other reads expenditure back out of observed loss — if they disagreed the app would predict
against one number and measure itself against another. Keep that sharing in Kotlin.

---

## 2. Storage — GRDB migrations needing Room twins

Five migrations, all currently `ios_only` in the schema oracle.

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

### `v50-diet-v3` — protein target, recipes, macro provenance

Everything here is **ALTER-appended**, so the added columns land LAST in each table. Room's column order
must match that, not the logical grouping a fresh `CREATE TABLE` would suggest.

```
dietGoal   … , proteinGPerKg                    (nullable; nil = untargeted)
foodItem   … , macroSource                      (nullable text; nil = user-stated, "ai-estimate")
foodEntry  … , macroSource                      (same vocabulary, snapshotted independently)
recipeComponent  id, deviceId, recipeId, foodItemId, quantity, ord
```

Design points the twin must preserve:
- **`macroSource` rides BOTH the item and the entry.** The entry's copy is not redundant: the snapshot
  outlives library edits, and "this number was once a guess" is exactly the kind of fact a log should
  keep. An estimate that reads as a label figure is the failure the column exists to prevent.
- **A recipe has no `isRecipe` flag.** Having `recipeComponent` rows IS being a recipe. A flag would be a
  second answer to a question the components already answer, and the two can disagree.
- **A recipe's macros are computed, never authoritative in storage.** The item's `kcal`/macro columns are
  kept in sync as a CACHE for one case only: the picker renders the whole library at once, and a recipe
  whose ingredient has since been deleted has no computable total, so the last-known figure is shown and
  marked incomplete. Everywhere else, compose from the parts.
- **`recipeComponent.foodItemId` has no foreign key**, the same reason `foodEntry.itemId` has none.
  Deleting an ingredient must NOT cascade away the recipe that mentioned it — the recipe keeps naming it
  and reports itself incomplete, which is a visible problem the user can fix rather than a total that
  silently shrank.
- **Logging a recipe snapshots like any other food**, so a log-time quantity tweak affects only that
  entry. On Apple, a tweaked recipe deliberately logs with `saveToLibrary: false` — otherwise the
  re-save that stamps `lastUsedAt` would push today's amounts onto the saved recipe.

### `v51-inline-recipe-ingredients` — ad-hoc ingredients

Makes `recipeComponent.foodItemId` NULLABLE and adds seven `inline*` columns. **This migration REBUILDS
the table** (create-copy-drop-rename), because SQLite cannot drop NOT NULL in place — so the column order
below is authoritative and Room must match it exactly:

```
recipeComponent  id, deviceId, recipeId, foodItemId, quantity, ord,
                 inlineName, inlineServingLabel, inlineKcal, inlineProtein, inlineCarbs,
                 inlineFat, inlineFiber
```

- **Exactly one shape per row.** Non-null `foodItemId` = a library reference, whose macros resolve LIVE.
  Null = the `inline*` columns hold the ingredient outright. That nil IS the discriminator; a row
  carrying both would make every reader guess.
- **Only a reference can go missing**, which is the only reason the two cases are distinguished in
  `RecipeMath` at all. An inline ingredient has nothing to delete out from under it.
- The index does **not** survive the rebuild — the migration recreates it afterwards. A Room twin doing
  its own rebuild has the same trap.
- Inline macros are PER SERVING, the same convention `foodItem` uses, so one scaling path covers both.

### `v52-measured-baseline` — closing the loop

`dietGoal` gains `measuredBaselineKcal` (nullable, ALTER-appended so it lands LAST; Room must match).

```
dietGoal   … , measuredBaselineKcal
```

- **A BASELINE, not a total.** The engine reports average TDEE over 3–6 weeks, which already contains
  that window's average steps and workouts. The window's mean activity is subtracted BEFORE storing, so
  the per-day terms ride on top exactly as they ride on the modelled baseline. Store a total instead and
  you either double-count today's activity or freeze the budget — the twin must get this right.
- **The mean activity must come from the SAME window the estimate spans** (`adaptive.windowDays`, which
  is what the engine kept, not what the caller asked for). A different span shifts the baseline silently.
- **BMR floor, refused not clamped.** A measured baseline under resting metabolism is a food log missing
  meals; clamping to BMR would still be a figure nobody measured.
- **Opt-in and revertible**, written by editing the OPEN goal in place — superseding it would reset
  `startedOn` and rewrite the history adherence is measured against.
- `targetOverrideKcal` remains **unread by anything** on both platforms. Left deliberately.

### `foodEntry.mealType` becomes a WRITTEN column

No migration either side — the column has existed since v48 and Room's entity already has it. What changed
is that something finally writes it, and the rule matters:

- A caller-stated meal is honoured; otherwise it is inferred from the clock **for a same-day log only** and
  left NULL for a backfill. A backfilled entry is stamped at exactly 12:00:00 as an admission that its time
  is unknown, so inferring "lunch" from it would be a guess stored as a fact.
- NULL means UNKNOWN, not "no meal". It is the display layer that maps NULL → `unassigned`; that case is
  deliberately NOT storable, or there would be two spellings of one state.
- Entries written before this change fall back to time inference, with an exact-12:00:00 check sending them
  to `unassigned`. That check is legacy-only and documented as such — safe because `logTimestamp` was its
  only writer.

### Two new `metricSeries` keys — no migration

`metricSeries` is tall, so these need no schema change, but the Kotlin writer must use the same key
strings and the same semantics:

- **`diet_activity_kcal`** (source `diet`) — step NEAT + workout kcal for the day, banked by
  `refreshDietDay` so a measured baseline can be derived without replaying every past day's steps. Must
  be in the "clear all keys" list, or a stale figure survives the last entry of a day being deleted.
- **`intake_rough`** (source `food-log`) — 1 when any of the day's entries was an admitted guess. Banked
  beside the day totals because the engine needs it for every day in a six-week window; re-derived on
  every write so deleting the rough entry clears the flag.

### `deviceScopedTables`

`foodItem`, `foodEntry`, `dietGoal` and `recipeComponent` are all registered in
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
| `Strand/Data/DietExpenditure.swift` | the day-assembly orchestration — including `dailyStepsForDiet`, see section 5 |
| `Strand/Screens/FoodLogView.swift`, `AddFoodSheet.swift` | food logging UI — includes the day stepper (**past-day logging**: every write threads a `day` key, defaulting to today only at the edge) |
| `Strand/Screens/EditFoodItemSheet.swift`, `EditWeightSheet.swift` | editing a saved food / a past weigh-in |
| `Strand/Data/RecipeStore.swift`, `Strand/Screens/RecipeBuilderSheet.swift` | recipes — builder plus the log-time per-ingredient tweak in `AddFoodSheet` |
| `Strand/System/FoodLogReminder.swift` | **net-new on both sides** — Android has no food or meal notifier at all. See section 6. |
| `AICoachEngine.estimateMacros(describing:)` (`Strand/AI/AICoach.swift`) | the AI macro-estimation egress path. See section 6. |
| `Strand/Screens/DietGoalSheet.swift` | goal setup (target weight + months slider) |
| `Strand/Screens/DietBudgetCard.swift` | Today's diet card |
| `Strand/Screens/DietDetailView.swift` | diet detail screen |
| `TodaySection.diet` (`Strand/Data/TodayLayoutPrefs.swift`) | matching `TodaySection` entry — **raw key `"diet"` appended LAST**, default order position directly after `hero` |
| `TodaySection.weight`, `Strand/Screens/WeightTodayCard.swift`, `WeightView.swift` | the weigh-in surfaces — **raw key `"weight"` appended LAST**, default order directly after `diet`. Weigh-ins were previously only reachable from the bottom of the food log; they are now a Today card, their own screen, and a quick-action row, and the food log no longer logs them at all. Worth copying the reasoning: the engine gates on weigh-in days as hard as on intake days, so the half of the calibration people skip most was also the hardest to reach. |
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

### `dailyStepsForDiet` — which step count the budget may use

The twin of the above for the OTHER term, and a bug fix the Kotlin port must not reintroduce. The
original read the merged daily cache's `steps` column directly, which for TODAY only gains a value once
the strap has offloaded the window. Between offloads it was nil, NEAT was computed from 0, and the budget
sat at `BMR x 1.2 - deficit` all day while the Today tile — reading its own fresher series — showed
thousands of steps. The arithmetic was correct and it was being fed a step count from hours ago.

The resolution order, which is a PRECEDENCE and deliberately neither a sum nor a max across instruments
(these are alternative measurements of the same legs — adding double-counts, and taking the highest hands
the budget to whichever device over-reports):

1. The measured strap count for that day. A **zero column counts as no answer**, not as "no steps" — the
   daily cache writes 0 for a day it has not seen, and treating that as measured pins the budget at
   baseline for anyone whose steps come from their phone.
2. Apple Health's `steps` series for that day.
3. **Today only, and only upward:** the live phone pedometer may RAISE the resolved figure, never lower
   it. It is the only source that knows about the last ten minutes. If the strap has already offloaded
   more steps than the phone saw, the phone was in a bag and the strap is right. Taking the larger of two
   counts that both lag for different reasons is the least-wrong way to track a day in progress, and it
   cannot invent movement because both are measurements.

Nothing resolvable means nil, which the caller treats as no NEAT credit rather than a guess.

The UI half matters too: the budget card recomputes when the app becomes **active**, because that is when
the user has been walking. A sync-keyed refresh alone does not fire, since a sync is not what changes the
pedometer's figure.

---

## 6. Non-diet changes also owed

- **Calorie source precedence** (`MetricCatalog.todayCaloriesMetric`, key `noop.preferStrapCalories`) —
  an opt-in that prefers NOOP's own estimate over Apple Health's. Useful to anyone without an Apple
  Watch and the most plausible candidate for upstreaming, but currently entangled with food-log changes
  in the same files.
- **The food-log reminder** (`Strand/System/FoodLogReminder.swift`) — **net-new on both platforms**.
  Android has no food or meal notifier at all; `android/.../alarm/WindDownScheduler.kt` is the template.
  What must carry over is the DESIGN rather than the code:
  - A repeating daily trigger with a FIXED message, so nothing has to run at fire time. The Apple side is
    deliberately not the `CoachBriefScheduler`/BGTask shape — that one needs a background task only
    because it generates its payload with an AI call.
  - Time stored as **minutes since local midnight**, an Int. A stored `Date`/timestamp would carry a
    calendar day with it, so "20:00" would silently mean one particular evening.
  - It **fires whether or not the day is logged**, and only an ALREADY-DELIVERED notification is cleared
    once food is logged — gated on the entry landing on TODAY, since backfilling last Tuesday says
    nothing about whether today has been logged. Suppressing today properly needs a background task, and
    a reminder that silently misses days is the worse failure.
  - Two dead-state guards: the settings toggle seeds from the scheduler rather than from stored prefs
    (denial must persist as `false`, and a direct binding would write an "on" back over the refusal), and
    turning food logging off cancels the reminder — otherwise it keeps firing nightly for a feature whose
    screen and off switch are both gone.
  - Tapping it must route to the food log (`NavRouter.food` / `openFood()` on Apple).
- **Conversational logging, expanded.** The action protocol now carries an `actions` ARRAY (capped at 6),
  a per-action `day` ("today" / "yesterday" / ISO, range-checked against the food log's own 14-day limit),
  and three more verbs: `save` (library only, logs nothing), `weight`, and the existing `edit`. Things the
  twin must keep:
  - **One bad action does not discard the good ones.** A described meal of three items with one nonsense
    figure must still offer the other two, or conversational logging is less reliable than manual.
  - **A vague day is REFUSED, not resolved.** "A few days ago" parsed into a date is a model guessing.
  - **The day is resolved when the proposal is BUILT and the write takes it from the proposal**, never from
    whatever screen the user is on — a card saying "Yesterday" must write to yesterday after midnight too.
  - **The pounds guard is an APP-LAYER check**, not a range. 160 kg is a real weight, so only a comparison
    against the user's own last weigh-in (>25 kg jump) can tell a measurement from a unit error. A test
    pins that the pure parser accepts 160, so nobody narrows the range and locks out heavier users.
  - The system prompt now tells the model to ESTIMATE macros from its own knowledge rather than sending the
    user to another app, and to ask only when the ambiguity is about WHICH FOOD. The guardrails that make
    that safe are the Atwater check, the `aiEstimate` stamp, and the confirmation card.
- **AI macro estimation** (`AICoachEngine.estimateMacros`) — the parsing half is pure and lives in
  `MacroEstimateParse` (section 1); this is the egress half. It is **prompt-only across all four
  providers**, not native structured output: a native path means a second code path per provider, a
  separate parser for Anthropic (tool-use only, no JSON mode), and the tolerant parser is still needed as
  the Custom/Ollama fallback anyway. That choice was made partly so this twin stays cheap to write — keep
  it prompt-only. The gate stack, in this order: coach master switch checked **at egress** (not just in
  the UI) → provider configured → data consent → resolved key. The button must be **user-initiated**:
  never on appear, never on a settings change. Estimated fields land **pre-filled but editable**, so the
  user's confirmation is what turns an estimate into a stated figure.
- **Wake-triggered morning brief** (`CoachBriefScheduler` + `Repository.detectedWakeMinuteOfDay`) —
  opt-in, default OFF, so the fixed-time path is unchanged for every existing install. Three things the
  twin must keep:
  - The fixed time stays the FALLBACK, not a thing replaced. A night the strap did not record has no wake
    to time anything off, and someone who asked for a morning brief should still get one.
  - The wake read spans the last **36 hours**, not "today": a night running 23:30 → 07:00 has its onset on
    one day and its wake on the next, so a today-bounded read misses it on the morning it matters. The
    returned DAY is then checked against today, so a wake inside the window but belonging to yesterday
    cannot trigger anything.
  - It falls back to the **computed** sleep source when the imported read is empty (#1150's reasoning).
    A Bluetooth-only 4.0 banks every night as computed, so without this the feature silently never fires
    for them.
  The decisive trigger is the **post-sync** re-check, not the scene-phase one: becoming active happens
  before the strap offloads, so the wake is usually still unknown at that point.
- **The Calories tile prefers the diet figure** (`MetricCatalog.todayCaloriesMetric` +
  `preferDietExpenditureKey`, default ON). A display-precedence change, not a new computation —
  `diet_expenditure` already existed. Android's Today would need the same rule.
  The reasoning, because it is the kind of change that looks like it is hiding a measurement: NOOP's
  on-device figure integrates its resting floor ONLY over intervals the strap produced samples for, so a
  gappy day reads BELOW the user's own resting metabolism (observed: 1,557 kcal against a 1,743 kcal RMR),
  and its 50% HRR gate discards walking entirely. It is precise about something other than "what did I burn
  today". **`energy_kcal` is untouched** — still computed, banked and charted as the strap diagnostic; only
  which series the tile prefers changed. And because `diet_expenditure` is computed through
  `CalorieTarget.dayExpenditure`, it becomes measurement-backed on its own the day a measured baseline is
  adopted, with no switchover to build.
- **The Calories tile shows a RUNNING total** (`Repository.burnedSoFar` + `sleepHoursForDay`). Display only:
  nothing is banked, the budget stays whole-day (one that shrank through the day would read as nearly blown
  by a normal breakfast), and `diet_expenditure` stays a day total because history charts it and the
  measured-baseline derivation subtracts against it. The sleep read must clip sessions to the DAY's bounds
  and merge them first — a 23:30–07:00 night belongs partly to each day, and overlapping sessions would
  double-count — and must fall back to the computed sleep source, or a Bluetooth-only 4.0 is stuck on the
  linear path forever. The multiplier is re-derived from the baseline rather than read off the goal's
  activity level, so an adopted measured baseline flows through with whatever multiplier it implies.
- **One food screen** (`DietDetailView` with a Day/Progress segmented control; `FoodLogView` composed as
  the Day half via `ownsScaffold: false` rather than copied). `TabRoute.food` lands there so the reminder's
  tap-through still works. The FAB's "Log food" now opens the ADD SHEET directly — logging used to be
  FAB → Log food → Add food → sheet, and the middle step existed only because the sheet had no other home.
  Android's FAB mirrors that entry-point change; the segmented layout is Apple-only UI.
- **HealthKit entitlement removal** (`project.yml`) — Apple-only, nothing owed.
- **Dev build markers** (`NOOP_DEV_BUILD`, `AppIcon-Dev`) — Apple-only, nothing owed.

---

## 7. Translation debt (blocks upstreaming, not the fork)

Every string added by this feature is **English only**. `i18n-coverage.yml` hard-fails on a missing de /
es / fr / pt-PT translation, but it triggers only on PRs into `main` and on pushes to `main` — so it
never sees this fork's branches, and the debt accumulates silently.

That is fine for a personal build and is a hard blocker the first time any of this is offered upstream.
Whoever does that should run `python3 Tools/i18n_audit.py --ci` first (it needs **Python 3.10+**; the
`str | None` alias at module scope fails outright on 3.9) and expect a long list.

Note also that `Tools/seed-string-catalog.py` is **not** the way to extract these. It rebuilds the
catalogue from whatever `.stringsdata` happens to be in DerivedData, which on a machine that has built
other targets means thousands of unrelated strings and a whole-file rewrite — not the small additive
diff the previous extraction commits show.

---

## 8. Known gaps NOT introduced here

Worth fixing while in the area, but pre-existing on both platforms:

- **Hydration entries and caffeine intakes are still in UserDefaults/SharedPreferences**, so they are
  **not in `.noopbak`**. A restore returns their day totals and silently loses the per-entry detail. The
  food log had this same hole and it was closed by moving to SQLite (`v48`); these two still have it.

---

## Suggested order

1. Pure analytics twins with oracle tests — cheapest, and everything else depends on their numbers.
2. `v48` + `v49` Room migrations, schema oracle flipped to `"both"`, `deviceScopedTables` guard.
3. Store layer and the day-assembly orchestration.
4. UI: food logging (with the day stepper from the start — retrofitting past-day writes means touching
   every call site again), then goal setup, then the Today card and detail screen.
5. `v50`: protein target, recipes, macro provenance. Last of the schema work, and the recipe UI depends
   on the food library already existing.
6. The reminder and the AI estimation path — both independent of everything above, and both safe to defer
   since neither changes a stored number.
7. Flip the oracle entries and delete the corresponding rows from this file as each lands.
