-- DATA EXPLORER >> TÀI KHOẢN GIAO DỊCH
/* Tham số:
 *  :period_type  D | M | Q | Y
 *  :period_from, :period_to  Từ kỳ: D = yyyy-MM-dd | M = yyyy-MM | Q = yyyy-Q[1-4] | Y = yyyy
 */
WITH
-- ====================================================
-- 0. THAM SỐ: ngày đầu của Từ kỳ, ngày cuối của Đến kỳ
params AS (
  SELECT
    UPPER(:period_type) AS period_type,
    CASE UPPER(:period_type)
      WHEN 'D' THEN TO_DATE(:period_from)
      WHEN 'M' THEN TO_DATE(CONCAT(:period_from, '-01'))
      WHEN 'Q' THEN MAKE_DATE(CAST(SUBSTR(:period_from, 1, 4) AS INT), (CAST(SUBSTR(:period_from, 7, 1) AS INT) - 1) * 3 + 1, 1)
      WHEN 'Y' THEN MAKE_DATE(CAST(:period_from AS INT), 1, 1)
    END AS from_date,
    CASE UPPER(:period_type)
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(MAKE_DATE(CAST(SUBSTR(:period_to, 1, 4) AS INT), CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3, 1))
      WHEN 'Y' THEN MAKE_DATE(CAST(:period_to AS INT), 12, 31)
    END AS to_date
)
-- ====================================================
-- I. THỊ TRƯỜNG CƠ SỞ 
-- 1.1. Số lượng TK mở/đóng theo ngày x chiều tính đến hết [Đến kỳ]
, underlying_acc_events_daily AS (
  SELECT 
    'OPEN' AS event_type, 
    'CO_SO' market_type, 
    MAP('3', 'TRONG_NUOC', '4', 'NUOC_NGOAI', '5', 'TRONG_NUOC', '6', 'NUOC_NGOAI')[investor_type] AS origin_type, 
    MAP('3', 'CA_NHAN', '4', 'CA_NHAN', '5', 'TO_CHUC', '6', 'TO_CHUC')[investor_type] AS investor_kind, 
    o.open_date AS event_date, 
    COUNT(o.trading_account_no) AS acc_count
  FROM uat_vsdc_stg.open_investors o
  JOIN params p ON o.open_date <= p.to_date --> Lọc dữ liệu <= Ngày cuối kỳ
  GROUP BY o.investor_type, o.open_date
  UNION ALL
  SELECT 
    'CLOSE' AS event_type, 
    'CO_SO' market_type, 
    MAP('3', 'TRONG_NUOC', '4', 'NUOC_NGOAI', '5', 'TRONG_NUOC', '6', 'NUOC_NGOAI')[investor_type] AS origin_type, 
    MAP('3', 'CA_NHAN', '4', 'CA_NHAN', '5', 'TO_CHUC', '6', 'TO_CHUC')[investor_type] AS investor_kind, 
    c.close_date AS event_date, 
    COUNT(c.trading_account_no) AS acc_count
  FROM uat_vsdc_stg.closed_investors c
  JOIN params p ON c.close_date <= p.to_date --> Lọc dữ liệu <= Ngày cuối kỳ
  GROUP BY c.investor_type, c.close_date
)
-- 1.2. Số lượng TK lũy kế trước [Từ kỳ] theo chiều
, underlying_acc_count_openbalance AS (
  SELECT 'CO_SO' market_type, e.origin_type, e.investor_kind, SUM(IF(e.event_type = 'OPEN', e.acc_count, -e.acc_count)) AS begin_cum
  FROM underlying_acc_events_daily e
  JOIN params p ON e.event_date < p.from_date
  GROUP BY e.origin_type, e.investor_kind
)
-- 1.3. Phát sinh mở/đóng theo kỳ và chiều trong [Từ kỳ, Đến kỳ]
, underlying_period_counts AS (
  SELECT
    period_type, period_code, market_type, origin_type, investor_kind,
    SUM(IF(event_type = 'OPEN',  acc_count, 0)) AS open_in_period,
    SUM(IF(event_type = 'CLOSE', acc_count, 0)) AS close_in_period
  FROM (
    SELECT
      p.period_type,
      CASE p.period_type
        WHEN 'D' THEN DATE_FORMAT(e.event_date, 'yyyy-MM-dd')
        WHEN 'M' THEN DATE_FORMAT(e.event_date, 'yyyy-MM')
        WHEN 'Q' THEN CONCAT(YEAR(e.event_date), '-Q', QUARTER(e.event_date))
        WHEN 'Y' THEN CAST(YEAR(e.event_date) AS STRING)
      END AS period_code, -- Gom theo loại kỳ
      e.market_type, e.origin_type, e.investor_kind, e.event_type, e.acc_count
    FROM underlying_acc_events_daily e
    JOIN params p ON e.event_date BETWEEN p.from_date AND p.to_date -- Ngày mở/đóng trong kỳ
  ) s
  GROUP BY period_type, period_code, market_type, origin_type, investor_kind
)
-- 1.4. SL TK CƠ SỞ LŨY KẾ CUỐI KỲ (cộng dồn theo từng tổ hợp chiều)
, underlying_result AS (
  SELECT
    d.period_type, d.period_code, d.market_type, d.origin_type, d.investor_kind,
    NVL(b.begin_cum, 0) AS begin_cum,
    -- SL TK lũy kế cuối kỳ = đầu kỳ + mở - đóng
    NVL(b.begin_cum, 0)
      + SUM(d.open_in_period - d.close_in_period) OVER (PARTITION BY d.market_type, d.origin_type, d.investor_kind ORDER BY d.period_code ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS acc_cum,
    d.open_in_period,
    d.close_in_period
  FROM underlying_period_counts d
  LEFT JOIN underlying_acc_count_openbalance b ON b.market_type = d.market_type AND b.origin_type = d.origin_type AND b.investor_kind = d.investor_kind
)
-- ====================================================
-- II. THỊ TRƯỜNG PHÁI SINH (báo cáo TTLK01_1, chỉ theo tháng)
-- 2.1. Dữ liệu TTLK01_1: Tổng số tài khoản phái sinh theo tháng, gắn nhãn kỳ theo loại kỳ
, derivatives_reportdata AS (
  SELECT
    p.period_type,
    CASE p.period_type
      WHEN 'M' THEN DATE_FORMAT(f2.report_month_startdate, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(f2.report_month_startdate), '-Q', QUARTER(f2.report_month_startdate))
      WHEN 'Y' THEN CAST(YEAR(f2.report_month_startdate) AS STRING)
      -- 'D': báo cáo TTLK01 chỉ có theo tháng -> NULL => không có dòng kết quả
    END AS period_code, -- Gom theo loại kỳ
    f2.report_month_startdate,
    f2.report_year,
    f2.report_month,
    CASE column_path
      WHEN 'TỔNG CỘNG'                      THEN NULL
      WHEN 'SỐ LƯỢNG CUỐI KỲ > TRONG NƯỚC'  THEN 'TRONG_NUOC'
      WHEN 'SỐ LƯỢNG CUỐI KỲ > NƯỚC NGOÀI'  THEN 'NUOC_NGOAI'
    END AS origin_type,
    f2.field_value
  FROM (
    SELECT
      MAKE_DATE(report_year, report_month, 1) AS report_month_startdate,
      f.report_year,
      f.report_month,
      TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) AS column_path,
      CAST(NULLIF(f.field_value, '') AS BIGINT) AS field_value,
      DENSE_RANK() OVER (PARTITION BY f.report_year, f.report_month ORDER BY f.ds_snpst_dt DESC) AS rk_snapshotdate -- Lọc snapshot date
    FROM uat_iss_ods.flat_report f
    WHERE f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
      AND f.submit_source = 'ICP'
      AND f.report_code = 'TTLK01_1'
      AND TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) = 'TỔNG CỘNG'
      AND f.date_type = 'MONTHLY'
      AND f.report_year BETWEEN CAST(SUBSTR(:period_from, 1, 4) AS INT) AND CAST(SUBSTR(:period_to, 1, 4) AS INT) -- Lọc tạm giới hạn năm
  ) f2
  CROSS JOIN params p
  WHERE f2.rk_snapshotdate = 1 -- Lấy snapshot date mới nhất cho mỗi kỳ báo cáo
)
-- 2.2. SỐ LIỆU TK PHÁI SINH THEO TỪNG KỲ: tháng mới nhất có dữ liệu của kỳ
, derivatives_result AS (
  SELECT period_type, period_code, 'PHAI_SINH' market_type, origin_type, field_value AS acc_cum
  FROM (
    SELECT
      period_type, period_code, report_month_startdate, origin_type, field_value,
      DENSE_RANK() OVER (PARTITION BY period_code ORDER BY report_year, report_month DESC) AS month_rk -- Tháng mới nhất của kỳ
    FROM derivatives_reportdata
    WHERE period_code BETWEEN :period_from AND :period_to   -- kỳ thuộc khoảng tra cứu [Từ kỳ, Đến kỳ]
  ) r
  WHERE r.month_rk = 1
)
-- ====================================================
-- III. TỔNG HỢP SỐ LIỆU THÀNH CHỈ TIÊU X CHIỀU
SELECT period_type, period_code, market_type, origin_type, investor_kind,
       stack(3, 'TONG', acc_cum, 'MOI', open_in_period, 'DONG', close_in_period) AS (metric, value)
FROM underlying_result -- Thị trường cơ sở
UNION ALL
SELECT period_type, period_code, market_type, NULL origin_type, NULL investor_kind, 'TONG' metric, acc_cum AS value
FROM derivatives_result -- Thị trường phái sinh
ORDER BY period_code, market_type, origin_type, investor_kind, metric;