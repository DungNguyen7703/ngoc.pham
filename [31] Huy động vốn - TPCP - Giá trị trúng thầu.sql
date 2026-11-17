-- HUY ĐỘNG VỐN >> TPCP >> Giá trị trúng thầu TPCP
/* THAM SỐ TRA CỨU:
 *   :period_type -> Loại kỳ: M (Tháng) | Q (Quý) | Y (Năm)
 *   :from_period - :to_period -> Kỳ báo cáo: Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH 
-- Từ tham số kỳ -> Lấy ra ngày đầu của "Từ kỳ", ngày cuối của "Đến kỳ"
params AS (
  SELECT 
    -- Ngày bắt đầu của [Từ kỳ]
    (CASE :period_type
      WHEN 'M' THEN TO_DATE(CONCAT(:period_from, '-01')) -- Ngày đầu tháng
      WHEN 'Q' THEN TO_DATE(CONCAT(SUBSTR(:period_from, 1, 4), '-', LPAD(CAST((CAST(SUBSTR(:period_from, 7, 1) AS INT) - 1) * 3 + 1 AS STRING), 2, '0'), '-01')) -- Ngày đầu quý
      WHEN 'Y' THEN TO_DATE(CONCAT(:period_from, '-01-01')) -- Ngày đầu năm
    END) AS period_from_startdate,
    -- Ngày kết thúc của [Đến kỳ]
    (CASE UPPER(:period_type)
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01'))) -- Ngày cuối tháng
      WHEN 'Q' THEN LAST_DAY(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 AS STRING), 2, '0'), '-01'))) -- Ngày cuối quý
      WHEN 'Y' THEN TO_DATE(CONCAT(:period_to, '-12-31')) -- Ngày cuối năm
    END) AS period_to_endate
) 
-- TỔNG HỢP DỮ LIỆU BIỂU ĐỒ
SELECT
  :period_type AS loaiky,
  period_code  AS ky,
  SUM(calling_value) AS gt_goi_thau,
  SUM(winning_value) AS gt_trung_thau,
  SUM(winning_value) / NULLIF(SUM(calling_value), 0) * 100.0 AS ty_le_trung_thau_pct -- Tỷ lệ trúng thầu (%) = Trúng thầu / Gọi thầu * 100.0
FROM (
  SELECT
    -- Lấy kỳ (period_code) theo tham số :period_type
    CASE :period_type
      WHEN 'M' THEN DATE_FORMAT(issue_date, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(DATE_FORMAT(issue_date, 'yyyy'), '-Q', QUARTER(issue_date))
      WHEN 'Y' THEN DATE_FORMAT(issue_date, 'yyyy')
    END AS period_code,
    calling_value,
    winning_value
  FROM uat_hnx_stg.gov_bond_offering o
  CROSS JOIN params p -- Lấy ra ngày đầu, ngày cuối lọc dữ liệu
  WHERE o.issue_date >= p.period_from_startdate
    AND o.issue_date <= p.period_to_endate
)
GROUP BY period_code
ORDER BY period_code;


-- HUY ĐỘNG VỐN >> TPCP >> Giá trị trúng thầu TPCP
/* THAM SỐ TRA CỨU:
 *   :period_type -> Loại kỳ: M (Tháng) | Q (Quý) | Y (Năm)
 *   :from_period - :to_period -> Kỳ báo cáo: Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
-- Tổng hợp dữ liệu biểu đồ
SELECT
  :period_type AS loaiky,
  period_code  AS ky,
  SUM(calling_value) AS gt_goi_thau,
  SUM(winning_value) AS gt_trung_thau,
  SUM(winning_value) / NULLIF(SUM(calling_value), 0) * 100.0 AS ty_le_trung_thau_pct -- Tỷ lệ trúng thầu (%) = Trúng thầu / Gọi thầu * 100.0
FROM (
  SELECT
    -- Lấy kỳ (period_code) theo tham số :period_type
    CASE :period_type
      WHEN 'M' THEN DATE_FORMAT(issue_date, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(DATE_FORMAT(issue_date, 'yyyy'), '-Q', QUARTER(issue_date))
      WHEN 'Y' THEN DATE_FORMAT(issue_date, 'yyyy')
    END AS period_code,
    calling_value,
    winning_value
  FROM uat_hnx_stg.gov_bond_offering
  WHERE 
  -- Chặn dưới: issue_date >= Ngày bắt đầu của [Từ kỳ]
      issue_date >= (CASE :period_type
                      WHEN 'M' THEN TO_DATE(CONCAT(:from_period, '-01')) -- Ngày đầu tháng
                      WHEN 'Q' THEN TO_DATE(CONCAT(SUBSTR(:from_period, 1, 4), '-', LPAD(CAST((CAST(SUBSTR(:from_period, 7, 1) AS INT) - 1) * 3 + 1 AS STRING), 2, '0'), '-01')) -- Ngày đầu quý
                      WHEN 'Y' THEN TO_DATE(CONCAT(:from_period, '-01-01')) -- Ngày đầu năm
                    END)
  -- Chặn trên: issue_date <= Ngày kết thúc của [Đến kỳ]
  AND issue_date <= (CASE UPPER(:period_type)
                      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:to_period, '-01'))) -- Ngày cuối tháng
                      WHEN 'Q' THEN LAST_DAY(TO_DATE(CONCAT(SUBSTR(:to_period, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:to_period, 7, 1) AS INT) * 3 AS STRING), 2, '0'), '-01'))) -- Ngày cuối quý
                      WHEN 'Y' THEN TO_DATE(CONCAT(:to_period, '-12-31')) -- Ngày cuối năm
                    END)
)
GROUP BY period_code
ORDER BY period_code;