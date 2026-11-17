WITH 
-- 1. XÁC ĐỊNH MÃ KỲ VÀ KHOẢNG THỜI GIAN [KỲ TRƯỚC -> KỲ NÀY]
param_periods AS (
  SELECT
    :period_to AS period_cur,
    
    -- Mã kỳ trước
    CASE UPPER(:period_type)
      WHEN 'Y' THEN CAST(CAST(:period_to AS INT) - 1 AS STRING)
      WHEN 'M' THEN DATE_FORMAT(ADD_MONTHS(TO_DATE(CONCAT(:period_to, '-01')), -1), 'yyyy-MM')
      WHEN 'Q' THEN 
        CASE 
          WHEN CAST(SUBSTR(:period_to, 7, 1) AS INT) = 1 
            THEN CONCAT(CAST(SUBSTR(:period_to, 1, 4) AS INT) - 1, '-Q4')
          ELSE CONCAT(SUBSTR(:period_to, 1, 4), '-Q', CAST(SUBSTR(:period_to, 7, 1) AS INT) - 1)
        END
    END AS period_prev,

    -- Ngày bắt đầu của Kỳ trước
    CASE UPPER(:period_type)
      WHEN 'Y' THEN TO_DATE(CONCAT(CAST(:period_to AS INT) - 1, '-01-01'))
      WHEN 'M' THEN ADD_MONTHS(TO_DATE(CONCAT(:period_to, '-01')), -1)
      WHEN 'Q' THEN ADD_MONTHS(
                      TO_DATE(CONCAT(
                        SUBSTR(:period_to, 1, 4), '-', 
                        LPAD(CAST((CAST(SUBSTR(:period_to, 7, 1) AS INT) - 1) * 3 + 1 AS STRING), 2, '0'), 
                        '-01'
                      )), 
                      -3
                    )
    END AS start_date_prev,

    -- Ngày kết thúc của Kỳ này
    CASE UPPER(:period_type)
      WHEN 'Y' THEN TO_DATE(CONCAT(:period_to, '-12-31'))
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(TO_DATE(CONCAT(
                      SUBSTR(:period_to, 1, 4), '-', 
                      LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 AS STRING), 2, '0'), 
                      '-01'
                    )))
    END AS end_date_curr
)
-- 2. GỘP TOÀN BỘ PHẦN DƯ NỢ VÀO 1 CTE DUY NHẤT (LỌC THEO REPORT_YEAR & MONTH)
, du_no_agg AS (
  SELECT
    period_code,
    SUM(max_volume) * 100000 AS tong_du_no
  FROM (
    -- Lọc lấy bản ghi có rk = 1 (tháng mới nhất của mỗi kỳ) và khử trùng lặp theo bond_code
    SELECT
      period_code,
      bond_code,
      MAX(listed_volume) AS max_volume
    FROM (
      SELECT
        CASE UPPER(:period_type)
          WHEN 'M' THEN CONCAT(g.report_year, '-', LPAD(CAST(g.report_month AS STRING), 2, '0'))
          WHEN 'Q' THEN CONCAT(g.report_year, '-Q', CAST(CAST((CAST(g.report_month AS INT) - 1) / 3 AS INT) + 1 AS STRING))
          WHEN 'Y' THEN CAST(g.report_year AS STRING)
        END AS period_code,
        g.bond_code,
        CAST(COALESCE(g.listed_volume, 0) AS DECIMAL(38, 2)) AS listed_volume,
        -- Xếp hạng tháng giảm dần trong từng kỳ
        DENSE_RANK() OVER (
          PARTITION BY 
            CASE UPPER(:period_type)
              WHEN 'M' THEN CONCAT(g.report_year, '-', LPAD(CAST(g.report_month AS STRING), 2, '0'))
              WHEN 'Q' THEN CONCAT(g.report_year, '-Q', CAST(CAST((CAST(g.report_month AS INT) - 1) / 3 AS INT) + 1 AS STRING))
              WHEN 'Y' THEN CAST(g.report_year AS STRING)
            END
          ORDER BY CAST(g.report_month AS INT) DESC
        ) AS rk
      FROM uat_hnx_stg.gov_bond_listed_list g
      CROSS JOIN param_periods p
      -- [TỐI ƯU PARTITION & SCAN THEO NĂM/THÁNG]
      WHERE g.report_year BETWEEN YEAR(p.start_date_prev) AND YEAR(p.end_date_curr)
        AND (CAST(g.report_year AS INT) * 12 + CAST(g.report_month AS INT)) BETWEEN
            (YEAR(p.start_date_prev) * 12 + MONTH(p.start_date_prev))
            AND (YEAR(p.end_date_curr) * 12 + MONTH(p.end_date_curr))
    ) ranked
    WHERE rk = 1
    GROUP BY period_code, bond_code
  ) dedup
  GROUP BY period_code
)
-- 3. TÍNH GT PHÁT HÀNH, KỲ HẠN PHÁT HÀNH BQ, LÃI SUẤT PHÁT HÀNH BQ
, offering_agg AS (
  SELECT
    period_code,
    SUM(winning_value) AS gt_phat_hanh,
    SUM(winning_interest_rate * winning_value) / NULLIF(SUM(winning_value), 0) AS lai_suat_phat_hanh_bq_tpcp, -- Lãi suất bình quân gia quyền (%/năm)
    SUM(term_years * winning_value) / NULLIF(SUM(winning_value), 0) AS ky_han_phat_hanh_bq_tpcp -- Kỳ hạn phát hành bình quân (quy đổi ra năm)
  FROM (
    SELECT 
      CASE UPPER(:period_type)
        WHEN 'M' THEN DATE_FORMAT(issue_date, 'yyyy-MM')
        WHEN 'Q' THEN CONCAT(DATE_FORMAT(issue_date, 'yyyy'), '-Q', QUARTER(issue_date))
        WHEN 'Y' THEN DATE_FORMAT(issue_date, 'yyyy')
      END AS period_code,
      winning_value,
      winning_interest_rate,
      -- Quy đổi kỳ hạn tuần/tháng về số năm
      CASE 
        WHEN LOWER(term) LIKE '%tuần%'  THEN CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4)) / 52.0
        WHEN LOWER(term) LIKE '%tháng%' THEN CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4)) / 12.0
        ELSE CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4))
      END AS term_years
    FROM uat_hnx_stg.gov_bond_offering o
    CROSS JOIN param_periods p
    WHERE o.issue_date >= p.start_date_prev 
      AND o.issue_date <= p.end_date_curr 
  )
  GROUP BY period_code
)
-- 4. KẾT HỢP DỮ LIỆU CẢ 2 KỲ (KỲ NÀY & KỲ TRƯỚC)
, period_metrics AS (
  SELECT
    k.period_code,
    COALESCE(d.tong_du_no, 0)   AS tong_du_no,
    COALESCE(o.gt_phat_hanh, 0) AS gt_phat_hanh,
    o.ky_han_bq,
    o.lai_suat_bq
  FROM (
    SELECT period_cur AS period_code FROM param_periods
    UNION ALL
    SELECT period_prev AS period_code FROM param_periods
  ) k
  LEFT JOIN du_no_agg d    ON k.period_code = d.period_code
  LEFT JOIN offering_agg o ON k.period_code = o.period_code
)
-- 5. SO SÁNH KỲ NÀY VỚI KỲ TRƯỚC VÀ TRẢ VỀ KẾT QUẢ CUỐI CÙNG
SELECT
  p.period_cur AS ky_bao_cao,
  p.period_prev AS ky_truoc,
  -- 1. Tổng dư nợ TPCP & % so với kỳ trước
  cur.tong_du_no AS tong_du_no_tpcp,
  (curr.tong_du_no - prev.tong_du_no) / NULLIF(prev.tong_du_no, 0) * 100.0 AS tong_du_no_so_ky_truoc_pct,
  -- 2. GT phát hành & % so với kỳ trước
  cur.gt_phat_hanh AS gt_phat_hanh,
  (cur.gt_phat_hanh - prev.gt_phat_hanh) / NULLIF(prev.gt_phat_hanh, 0) * 100.0 AS gt_phat_hanh_so_ky_truoc_pct,
  -- 3. Kỳ hạn bình quân (năm) & % so với kỳ trước
  ROUND(cur.ky_han_bq, 2) AS ky_han_bq_nam,
  (cur.ky_han_bq - prev.ky_han_bq) / NULLIF(prev.ky_han_bq, 0) * 100.0 AS ky_han_bq_so_ky_truoc_pct,
  -- 4. Lãi suất bình quân (%/năm) & % thay đổi so với kỳ trước
  ROUND(cur.lai_suat_bq, 4) AS lai_suat_bq_pct,
  (cur.lai_suat_bq - prev.lai_suat_bq) / NULLIF(prev.lai_suat_bq, 0) * 100.0 AS lai_suat_bq_so_ky_truoc_pct
FROM param_periods p
LEFT JOIN period_metrics cur ON p.period_cur = cur.period_code
LEFT JOIN period_metrics prev ON p.period_prev = prev.period_code
;