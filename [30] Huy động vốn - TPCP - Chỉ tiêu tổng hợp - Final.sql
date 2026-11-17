WITH 
-- 1. XÁC ĐỊNH KỲ BÁO CÁO (KỲ NÀY) VÀ KỲ LIỀN TRƯỚC
param_periods AS (
  SELECT
    :period_type AS period_type,
    :period_to   AS period_cur,
    CASE :period_type
      WHEN 'Y' THEN CAST(CAST(:period_to AS INT) - 1 AS STRING) -- Năm trước
      WHEN 'M' THEN DATE_FORMAT(ADD_MONTHS(TO_DATE(CONCAT(:period_to, '-01')), -1), 'yyyy-MM') -- Tháng trước (Tháng 01 lùi về Tháng 12 năm trước)
      WHEN 'Q' THEN 
        CASE 
          WHEN CAST(SUBSTR(:period_to, 7, 1) AS INT) = 1 THEN CONCAT(CAST(SUBSTR(:period_to, 1, 4) AS INT) - 1, '-Q4')
          ELSE CONCAT(SUBSTR(:period_to, 1, 4), '-Q', CAST(SUBSTR(:period_to, 7, 1) AS INT) - 1)
        END -- Quý trước (Q1 lùi về Q4 năm trước, các quý khác lùi 1 quý)
    END AS period_prev
)
-- 2. TÍNH DƯ NỢ TPCP NIÊM YẾT (TÍNH TỪ DỮ LIỆU TPCP NIÊM YẾT SNAPSHOT THÁNG MỚI NHẤT TRONG KỲ)
, outstanding_agg AS (
  SELECT 
    -- 3. Tính dư nợ từ dữ liệu snapshot tháng mới nhất trong kỳ tra cứu
    period_code,
    SUM(listed_volume) * 100000 AS duno_tpcp
  FROM (
    SELECT 
      -- 2. Lọc tháng thuộc kỳ tra cứu + Sắp xếp để lấy tháng mới nhất của kỳ tra cứu
      g2.*,
      DENSE_RANK() OVER (PARTITION BY period_code ORDER BY CAST(report_month AS INT) DESC) AS rk -- Rank tháng giảm dần trong từng kỳ (tháng mới nhất của quý/năm sẽ có rk = 1)
    FROM (
      -- 1. Lấy thông tin kỳ tháng/quý/năm của report_year + report_month
      SELECT
        CASE UPPER(:period_type)
          WHEN 'M' THEN CONCAT(g.report_year, '-', LPAD(CAST(g.report_month AS STRING), 2, '0'))
          WHEN 'Q' THEN CONCAT(g.report_year, '-Q', CAST(CAST((CAST(g.report_month AS INT) - 1) / 3 AS INT) + 1 AS STRING))
          WHEN 'Y' THEN CAST(g.report_year AS STRING)
        END AS period_code,
        g.report_month,
        g.bond_code,
        g.listed_volume
      FROM uat_hnx_stg.gov_bond_listed_list g
    ) g2
    CROSS JOIN param_periods p
    WHERE g2.period_code IN (p.period_cur, p.period_prev) -- Lấy các tháng thuộc kỳ này, kỳ trước
  ) g3 
  WHERE g3.rk = 1
  GROUP BY period_code
)
-- 3. TÍNH GT PHÁT HÀNH, KỲ HẠN BQ, LÃI SUẤT BQ TỪ BẢNG ĐẤU THẦU
, offering_agg AS (
  SELECT
    period_code,
    SUM(winning_value) AS gt_phat_hanh,
    SUM(term_years * winning_value) / NULLIF(SUM(winning_value), 0) AS ky_han_bq,
    SUM(winning_interest_rate * winning_value) / NULLIF(SUM(winning_value), 0) AS lai_suat_bq
  FROM (
    SELECT
      -- Lấy kỳ Tháng/Quý/Năm của issue_date
      CASE UPPER(:period_type)
        WHEN 'M' THEN DATE_FORMAT(issue_date, 'yyyy-MM')
        WHEN 'Q' THEN CONCAT(DATE_FORMAT(issue_date, 'yyyy'), '-Q', QUARTER(issue_date))
        WHEN 'Y' THEN DATE_FORMAT(issue_date, 'yyyy')
      END AS period_code,
      winning_value,
      winning_interest_rate,
      -- Quy đổi kỳ hạn tuần/tháng về số năm
      CASE 
        WHEN LOWER(term) LIKE '%tuần%' THEN CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4)) / 52.0
        WHEN LOWER(term) LIKE '%tháng%' THEN CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4)) / 12.0
        ELSE CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4))
      END AS term_years
    FROM uat_hnx_stg.gov_bond_offering
  ) o
  CROSS JOIN param_periods p
  WHERE o.period_code IN (p.period_cur, p.period_prev) -- Lấy ngày phát hành thuộc kỳ này, kỳ trước
  GROUP BY o.period_code
)
-- TỔNG HỢP DỮ LIỆU BÁO CÁO
SELECT
  p.period_type AS loaiky,
  p.period_cur  AS ky_bao_cao,
  p.period_prev AS ky_truoc,
  -- 1. Tổng dư nợ TPCP & % so với kỳ trước
  COALESCE(dc.duno_tpcp, 0) AS duno_tpcp_tpcp,
  (COALESCE(dc.duno_tpcp, 0) - COALESCE(dp.duno_tpcp, 0)) / NULLIF(dp.duno_tpcp, 0) * 100.0 AS duno_tpcp_so_ky_truoc_pct,
  -- 2. GT phát hành & % so với kỳ trước
  COALESCE(oc.gt_phat_hanh, 0) AS gt_phat_hanh,
  (COALESCE(oc.gt_phat_hanh, 0) - COALESCE(op.gt_phat_hanh, 0)) / NULLIF(op.gt_phat_hanh, 0) * 100.0 AS gt_phat_hanh_so_ky_truoc_pct,
  -- 3. Kỳ hạn bình quân (năm) & % so với kỳ trước
  ROUND(oc.ky_han_bq, 2) AS ky_han_bq_nam,
  (oc.ky_han_bq - op.ky_han_bq) / NULLIF(op.ky_han_bq, 0) * 100.0 AS ky_han_bq_so_ky_truoc_pct,
  -- 4. Lãi suất bình quân (%/năm) & % thay đổi so với kỳ trước
  ROUND(oc.lai_suat_bq, 4) AS lai_suat_bq_pct,
  (oc.lai_suat_bq - op.lai_suat_bq) / NULLIF(op.lai_suat_bq, 0) * 100.0 AS lai_suat_bq_so_ky_truoc_pct
FROM param_periods p
LEFT JOIN outstanding_agg dc ON dc.period_code = p.period_cur     -- Dư nợ - Kỳ này
LEFT JOIN outstanding_agg dp ON dp.period_code = p.period_prev    -- Dư nợ - Kỳ trước
LEFT JOIN offering_agg oc    ON oc.period_code = p.period_cur     -- Phát hành - Kỳ này
LEFT JOIN offering_agg op    ON op.period_code = p.period_prev    -- Phát hành - Kỳ trước
;