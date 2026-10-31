-- =====================================================================
-- 01_srm_check.sql
-- Sample Ratio Mismatch (SRM) check for experiment checkout_v2.
-- Expected split is 50/50. Chi-square test with 1 degree of freedom:
--   chi2 > 3.84  -> p < 0.05
--   chi2 > 10.83 -> p < 0.001
-- =====================================================================

-- 1) Overall split -----------------------------------------------------
WITH counts AS (
  SELECT
    COUNTIF(variant = 'control')   AS n_control,
    COUNTIF(variant = 'treatment') AS n_treatment,
    COUNT(*)                       AS n_total
  FROM ab_test.assignments
)
SELECT
  n_control,
  n_treatment,
  ROUND(n_treatment / n_total, 4) AS share_treatment,
  ROUND(
    POW(n_control   - n_total / 2, 2) / (n_total / 2)
  + POW(n_treatment - n_total / 2, 2) / (n_total / 2), 2) AS chi2,
  CASE
    WHEN POW(n_control - n_total / 2, 2) / (n_total / 2)
       + POW(n_treatment - n_total / 2, 2) / (n_total / 2) > 10.83 THEN 'SRM (p < 0.001)'
    WHEN POW(n_control - n_total / 2, 2) / (n_total / 2)
       + POW(n_treatment - n_total / 2, 2) / (n_total / 2) > 3.84  THEN 'SRM (p < 0.05)'
    ELSE 'OK'
  END AS verdict
FROM counts;


-- 2) Diagnose: split by platform and assignment date -------------------
-- Run separately. Look for the cells where share_treatment drifts from 0.5.
WITH by_cell AS (
  SELECT
    u.platform,
    DATE(a.assigned_ts)                AS assigned_date,
    COUNTIF(a.variant = 'control')     AS n_control,
    COUNTIF(a.variant = 'treatment')   AS n_treatment,
    COUNT(*)                           AS n_total
  FROM ab_test.assignments AS a
  JOIN ab_test.users       AS u USING (user_id)
  GROUP BY platform, assigned_date
)
SELECT
  platform,
  assigned_date,
  n_control,
  n_treatment,
  ROUND(n_treatment / n_total, 3) AS share_treatment,
  ROUND(
    POW(n_control   - n_total / 2, 2) / (n_total / 2)
  + POW(n_treatment - n_total / 2, 2) / (n_total / 2), 2) AS chi2
FROM by_cell
ORDER BY chi2 DESC
LIMIT 15;
