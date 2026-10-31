-- =====================================================================
-- 02_user_metrics.sql
-- One row per assigned user, with:
--   * experiment metrics: only activity AFTER the user's assignment
--   * pre-period metrics: 28 days before the experiment (for CUPED)
-- Output table: ab_test.user_metrics
-- =====================================================================

DECLARE pre_start DATE DEFAULT '2026-08-04';
DECLARE exp_start DATE DEFAULT '2026-09-01';
DECLARE exp_end   DATE DEFAULT '2026-09-29';  -- exclusive

CREATE OR REPLACE TABLE ab_test.user_metrics AS

WITH assigned AS (
  SELECT
    a.user_id,
    a.variant,
    TIMESTAMP(a.assigned_ts)                         AS assigned_ts,
    u.platform,
    u.country,
    DATE(u.signup_ts) >= pre_start                   AS is_new_user
  FROM ab_test.assignments AS a
  JOIN ab_test.users       AS u USING (user_id)
),

-- experiment window: sessions after assignment ------------------------
exp_sessions AS (
  SELECT
    s.user_id,
    COUNT(*) AS sessions
  FROM ab_test.sessions AS s
  JOIN assigned         AS a USING (user_id)
  WHERE TIMESTAMP(s.session_start_ts) >= a.assigned_ts
    AND DATE(s.session_start_ts) < exp_end
  GROUP BY s.user_id
),

-- experiment window: funnel steps after assignment --------------------
exp_funnel AS (
  SELECT
    e.user_id,
    COUNTIF(e.event_name = 'checkout_start') AS checkout_starts,
    COUNTIF(e.event_name = 'purchase')       AS purchases
  FROM ab_test.events AS e
  JOIN assigned       AS a USING (user_id)
  WHERE TIMESTAMP(e.event_ts) >= a.assigned_ts
    AND DATE(e.event_ts) < exp_end
  GROUP BY e.user_id
),

-- experiment window: revenue after assignment -------------------------
exp_orders AS (
  SELECT
    o.user_id,
    COUNT(*)           AS orders,
    SUM(o.revenue_eur) AS revenue
  FROM ab_test.orders AS o
  JOIN assigned       AS a USING (user_id)
  WHERE TIMESTAMP(o.order_ts) >= a.assigned_ts
    AND DATE(o.order_ts) < exp_end
  GROUP BY o.user_id
),

-- pre-period: covariates for CUPED ------------------------------------
pre_sessions AS (
  SELECT user_id, COUNT(*) AS pre_sessions
  FROM ab_test.sessions
  WHERE DATE(session_start_ts) >= pre_start
    AND DATE(session_start_ts) <  exp_start
  GROUP BY user_id
),

pre_orders AS (
  SELECT user_id, COUNT(*) AS pre_orders, SUM(revenue_eur) AS pre_revenue
  FROM ab_test.orders
  WHERE DATE(order_ts) >= pre_start
    AND DATE(order_ts) <  exp_start
  GROUP BY user_id
)

SELECT
  a.user_id,
  a.variant,
  a.platform,
  a.country,
  a.is_new_user,
  a.assigned_ts,
  DATE(a.assigned_ts)                         AS assigned_date,

  -- experiment metrics
  COALESCE(s.sessions, 0)                     AS sessions,
  COALESCE(f.checkout_starts, 0)              AS checkout_starts,
  COALESCE(f.purchases, 0)                    AS purchases,
  COALESCE(o.orders, 0)                       AS orders,
  ROUND(COALESCE(o.revenue, 0), 2)            AS revenue,
  CAST(COALESCE(o.orders, 0) > 0 AS INT64)    AS converted,

  -- pre-period covariates
  COALESCE(ps.pre_sessions, 0)                AS pre_sessions,
  COALESCE(po.pre_orders, 0)                  AS pre_orders,
  ROUND(COALESCE(po.pre_revenue, 0), 2)       AS pre_revenue

FROM assigned          AS a
LEFT JOIN exp_sessions AS s  USING (user_id)
LEFT JOIN exp_funnel   AS f  USING (user_id)
LEFT JOIN exp_orders   AS o  USING (user_id)
LEFT JOIN pre_sessions AS ps USING (user_id)
LEFT JOIN pre_orders   AS po USING (user_id);


-- Quick look at the result (run after the table is created) -----------
SELECT
  variant,
  COUNT(*)                         AS users,
  ROUND(AVG(converted), 4)         AS conversion_rate,
  ROUND(AVG(revenue), 2)           AS revenue_per_user,
  ROUND(SAFE_DIVIDE(SUM(revenue), SUM(orders)), 2) AS aov,
  ROUND(AVG(sessions), 2)          AS sessions_per_user
FROM ab_test.user_metrics
GROUP BY variant
ORDER BY variant;
