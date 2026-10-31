-- =====================================================================
-- 04_novelty.sql
-- Is the effect stable over time, or does it fade (novelty effect)?
-- Metric: P(purchase | checkout started) at session level, by week since
-- the user's assignment. Clean population only.
-- Note: sessions of the same user are correlated, so naive session-level
-- standard errors would be too small; here we only look at the trend.
-- =====================================================================

WITH checkout_sessions AS (
  SELECT
    m.variant,
    e.session_id,
    -- weeks 3 and 4 are merged: only users assigned early reach week 4,
    -- so on its own it is too small and noisy
    LEAST(DIV(DATE_DIFF(DATE(e.event_ts), m.assigned_date, DAY), 7) + 1, 3) AS week_since_assignment,
    MAX(CAST(e.event_name = 'purchase' AS INT64))                 AS purchased
  FROM ab_test.events             AS e
  JOIN ab_test.user_metrics_clean AS m USING (user_id)
  WHERE TIMESTAMP(e.event_ts) >= m.assigned_ts
    AND DATE(e.event_ts) < '2026-09-29'
    AND e.event_name IN ('checkout_start', 'purchase')
  GROUP BY m.variant, e.session_id, week_since_assignment
),

weekly AS (
  SELECT
    week_since_assignment,
    COUNTIF(variant = 'control')                       AS checkouts_c,
    COUNTIF(variant = 'treatment')                     AS checkouts_t,
    AVG(IF(variant = 'control',   purchased, NULL))    AS rate_c,
    AVG(IF(variant = 'treatment', purchased, NULL))    AS rate_t
  FROM checkout_sessions
  GROUP BY week_since_assignment
)

SELECT
  week_since_assignment,
  checkouts_c,
  checkouts_t,
  ROUND(rate_c, 4)                          AS checkout_to_purchase_c,
  ROUND(rate_t, 4)                          AS checkout_to_purchase_t,
  ROUND(100 * (rate_t - rate_c) / rate_c, 2) AS rel_lift_pct
FROM weekly
ORDER BY week_since_assignment;
