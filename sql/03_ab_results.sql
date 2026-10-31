-- =====================================================================
-- 03_ab_results.sql
-- 1) Clean population: drop the cell hit by the logging bug (SRM source)
-- 2) Two-sample tests (Welch / unpooled z) with 95% CI and p-values
-- 3) CUPED variance reduction using pre-period covariates
-- 4) Segments by platform
-- Output table: ab_test.results
-- =====================================================================

-- Two-sided p-value from a z-score (normal approximation,
-- Abramowitz & Stegun 26.2.17, abs error < 7.5e-8)
CREATE TEMP FUNCTION t_(z FLOAT64) AS (1 / (1 + 0.2316419 * ABS(z)));
CREATE TEMP FUNCTION p_two_sided(z FLOAT64) AS (
  2 * EXP(-0.5 * z * z) / SQRT(2 * ACOS(-1)) * t_(z) * (
      0.319381530 + t_(z) * (-0.356563782 + t_(z) * (1.781477937
    + t_(z) * (-1.821255978 + t_(z) * 1.330274429))))
);

-- 1) Clean population ---------------------------------------------------
-- The SRM check located the problem in android users assigned on
-- 2026-09-08..10. We drop that whole cell in BOTH variants, so the
-- remaining comparison is still randomised.
CREATE OR REPLACE TABLE ab_test.user_metrics_clean AS
SELECT *
FROM ab_test.user_metrics
WHERE NOT (platform = 'android'
           AND assigned_date BETWEEN '2026-09-08' AND '2026-09-10');

-- 2-4) Results table ----------------------------------------------------
CREATE OR REPLACE TABLE ab_test.results AS

WITH base AS (
  SELECT
    variant,
    platform,
    CAST(converted AS FLOAT64)           AS conversion,
    revenue                              AS revenue_per_user,
    CAST(sessions AS FLOAT64)            AS sessions_per_user,   -- guardrail
    CAST(pre_sessions AS FLOAT64)        AS x_pre   -- CUPED covariate
  FROM ab_test.user_metrics_clean
),

-- CUPED: Y_adj = Y - theta * (X - mean(X)), theta = cov(Y, X) / var(X)
-- X = pre-period sessions: the most correlated pre-experiment covariate
-- (corr ~0.30 with both metrics, vs ~0.22-0.27 for pre-orders / pre-revenue).
-- theta is estimated on the pooled sample; X is unaffected by treatment.
theta AS (
  SELECT
    COVAR_SAMP(conversion, x_pre)       / VAR_SAMP(x_pre) AS th_conv,
    COVAR_SAMP(revenue_per_user, x_pre) / VAR_SAMP(x_pre) AS th_rev,
    AVG(x_pre)                                            AS mx
  FROM base
),

adjusted AS (
  SELECT
    b.*,
    b.conversion       - th_conv * (b.x_pre - mx) AS conversion_cuped,
    b.revenue_per_user - th_rev  * (b.x_pre - mx) AS revenue_per_user_cuped
  FROM base AS b CROSS JOIN theta
),

-- every user counts once in 'all' and once in their platform segment
segmented AS (
  SELECT 'all' AS segment, * FROM adjusted
  UNION ALL
  SELECT platform AS segment, * FROM adjusted
),

long AS (
  SELECT segment, variant, metric, value
  FROM segmented
  UNPIVOT (value FOR metric IN (
    conversion, conversion_cuped,
    revenue_per_user, revenue_per_user_cuped,
    sessions_per_user
  ))
),

stats AS (
  SELECT segment, metric, variant,
         COUNT(*) AS n, AVG(value) AS mean, VAR_SAMP(value) AS var
  FROM long
  GROUP BY segment, metric, variant
),

wide AS (
  SELECT
    c.segment, c.metric,
    c.n AS n_c, t.n AS n_t,
    c.mean AS mean_c, t.mean AS mean_t,
    t.mean - c.mean AS diff,
    SQRT(c.var / c.n + t.var / t.n) AS se
  FROM stats AS c
  JOIN stats AS t
    ON  c.segment = t.segment AND c.metric = t.metric
    AND c.variant = 'control' AND t.variant = 'treatment'
)

SELECT
  segment,
  metric,
  n_c,
  n_t,
  ROUND(mean_c, 4)                       AS mean_control,
  ROUND(mean_t, 4)                       AS mean_treatment,
  ROUND(diff, 4)                         AS diff,
  ROUND(diff - 1.96 * se, 4)             AS ci95_low,
  ROUND(diff + 1.96 * se, 4)             AS ci95_high,
  ROUND(100 * diff / mean_c, 2)          AS rel_lift_pct,
  ROUND(diff / se, 2)                    AS z,
  ROUND(p_two_sided(diff / se), 5)       AS p_value,
  ROUND(se, 5)                           AS se
FROM wide;


-- Main results ----------------------------------------------------------
SELECT segment, metric, mean_control, mean_treatment, rel_lift_pct,
       ci95_low, ci95_high, p_value, se
FROM ab_test.results
WHERE segment = 'all'
ORDER BY metric;

-- Platform segments (primary metric only) -------------------------------
-- 3 segments tested -> Bonferroni threshold 0.05 / 3 = 0.0167
SELECT segment, mean_control, mean_treatment, rel_lift_pct,
       ci95_low, ci95_high, p_value,
       p_value < 0.05 / 3 AS significant_bonferroni
FROM ab_test.results
WHERE metric = 'conversion_cuped' AND segment != 'all'
ORDER BY rel_lift_pct DESC;
