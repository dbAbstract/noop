---
topic: charge
title: Charge — the daily recovery score
keywords: charge, recovery, readiness, recovered, green, yellow, red, ready
sources: Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/ChargeBaselines.swift, Packages/StrandAnalytics/Sources/StrandAnalytics/Baselines.swift
---
Charge (0–100) is how recovered the body looks this morning compared with the user's OWN normal. It is
NOOP's transparent approximation, not WHOOP's proprietary score. "Readiness" in the morning brief is Charge.

How it is computed
- Each overnight signal becomes a robust z-score against the user's personal baseline
  (see topic `baselines`): how many "usual spreads" tonight sits above or below normal.
- The z-scores are weighted and summed:
  HRV higher than normal 55% (the dominant driver), resting HR lower than normal 20%,
  last night's Rest score 15%, respiratory rate lower than normal 5%,
  skin-temperature deviation from baseline 5% (a penalty either way, hot or cold).
  Two optional 5% terms join when available: the overnight resting-HR decline slope (falling through the
  night is good) and yesterday's Effort against the user's usual Effort.
- A missing signal is dropped and the remaining weights are rescaled, so a night without skin temperature
  is still scored, from fewer inputs.
- The weighted z is squashed through a logistic curve anchored so that an exactly-average night scores
  about 58, the published population average. Roughly ±2 z spans the whole red-to-green range.

Bands: 0–33 red (recover), 34–66 yellow (maintain), 67–100 green (push).

Cold start: Charge needs at least 4 valid nights of HRV before it scores at all, and baselines are only
fully trusted after 14. Baselines read the last 21 days; imported WHOOP nights only seed them until the
user's own nights take over.

What to tell the user
- Charge is relative: 60 for one person and 60 for another are not comparable, and a high-HRV athlete is
  not "more recovered" by default.
- One low night is a prompt to check sleep, alcohol, illness, late training or stress, not a diagnosis.
- Very fit people can occasionally show low HRV with low resting HR on a well-rested night; Charge may
  under-read that pattern.
