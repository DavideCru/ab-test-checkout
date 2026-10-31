# Decision memo — `checkout_v2`

**Recommendation: ship to all platforms.** For forecasting, use the conservative
estimate below, not the raw test result.

## Result
On 85,886 users over 4 weeks (clean population, CUPED-adjusted):

| Metric | Control | Treatment | Lift | 95% CI |
|---|---|---|---|---|
| **Conversion** (primary) | 27.7% | 29.4% | **+6.1%** | +4.0% to +8.2% |
| Revenue per user | €17.16 | €18.83 | **+9.7%** | +6.8% to +12.7% |
| Sessions per user (guardrail) | 7.85 | 7.80 | −0.7% | n.s. (p = 0.27) |
| Average order value (guardrail) | €43.8 | €43.8 | ≈ 0% | flat |

The new checkout gets more people to finish their purchase. Engagement and basket size
are unaffected, so the extra revenue comes entirely from more orders.

## Three things to know before using these numbers

**1. Some data was lost to a logging bug, and we corrected for it.**
The treatment group had fewer users than expected (SRM, χ² = 10.7, p = 0.001). The
cause is a bug that dropped assignment records for android treatment users on
8–10 September. We removed that cell from *both* variants, so the comparison stays
randomised. Engineering should fix the logging before the next test on android.

**2. The first week overstates the effect.**
The checkout → purchase lift is +15.6% in a user's first week and then settles at
about +8%. Part of the early lift is novelty that will not last. The 4-week averages
above still include that first week, so a conservative forecast discounts them by
about 25%:

> **Planning estimate: about +4.5% conversion and +7% revenue per user.**

**3. iOS benefits most.**
iOS shows +9.2% (significant). Android shows +4.2% and web +4.5%. Android and web are
positive but not significant after correcting for three segment tests. That is weaker
evidence, not evidence of no effect, so it is no reason to hold them back.

## Next steps
1. Ship `checkout_v2` and keep a **5% holdout for 4 weeks** to measure the long-run
   effect directly.
2. Fix the android assignment logging and add an automated daily SRM alert.
3. Investigate why web gains less. It could be an express-payment adoption gap.
