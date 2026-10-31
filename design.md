# Experiment design — `checkout_v2`

*Written before looking at the results.*

## Context
The current checkout is a 3-step flow: address → shipping → payment. `checkout_v2` puts
everything on a single page and adds express payment (Apple Pay / Google Pay).
About half of the users who start checkout abandon it, so this is the step with the
most room to improve.

## Hypothesis
Removing steps from checkout reduces abandonment. More users who start checkout will
complete a purchase, which raises the share of users who buy at least once.

- **H0:** conversion is the same in both variants
- **H1:** conversion differs (two-sided test, α = 0.05)

## Unit, population, assignment
- **Randomisation unit:** user (`user_id`), split 50/50 and kept for the whole test.
- **Population:** every user with at least one session during the test window. Users
  are assigned at their first session in the window, which is also when they are exposed.
- **Window:** 4 full weeks, 2026-09-01 → 2026-09-28. Whole weeks avoid day-of-week
  bias and leave time to see a novelty effect fade.
- **Metric window:** for each user, only activity *after* assignment counts.

## Metrics
| Type | Metric | Definition (per user) | Expected |
|---|---|---|---|
| **Primary** | Conversion | 1 if ≥ 1 order after assignment | ↑ |
| Secondary | Revenue per user | sum of order revenue (€), 0 for non-buyers | ↑ |
| Secondary | P(purchase \| checkout) | session-level checkout → purchase rate | ↑ (mechanism) |
| Guardrail | Sessions per user | engagement must not drop | = |
| Guardrail | Average order value | a simpler checkout must not shrink baskets | = |

## Sample size
- Baseline conversion over 4 weeks: **27.5%** (from the pre-period).
- Minimum detectable effect: **3% relative** (27.5% → 28.3%). That is the smallest lift
  that would pay back the engineering cost.
- α = 0.05 (two-sided), power = 80%:

$$n = \frac{(z_{1-\alpha/2} + z_{1-\beta})^2\,[p_1(1-p_1) + p_2(1-p_2)]}{(p_2 - p_1)^2} \approx 46{,}500 \text{ users per variant}$$

| MDE (relative) | users / variant |
|---|---|
| 2% | 104,000 |
| **3%** | **46,500** |
| 5% | 17,000 |

We expect about 44,000 users per variant in 4 weeks, which gives roughly 78% power at
a 3% MDE. CUPED (below) brings this back above 80%.

## Analysis plan
1. **SRM check first.** Run a χ² test on the 50/50 split. If p < 0.001, find the cause
   (by platform × day) before reading any metric.
2. **Test:** Welch / unpooled z-test on per-user means, reporting a 95% CI and the
   relative lift.
3. **Variance reduction:** CUPED, using **pre-period sessions** as the covariate
   (28 days before the test, so treatment cannot affect it).
4. **Segments:** iOS / android / web. These are exploratory, with Bonferroni α = 0.05/3.
5. **Novelty check:** checkout → purchase lift by week since assignment.
6. **No peeking:** the decision is made only at the end of the 4 weeks.

## Decision rule
- **Ship** if primary CI > 0 and no guardrail is significantly worse.
- **Don't ship** if primary CI < 0 or a guardrail is significantly worse.
- **Iterate / extend** otherwise.
