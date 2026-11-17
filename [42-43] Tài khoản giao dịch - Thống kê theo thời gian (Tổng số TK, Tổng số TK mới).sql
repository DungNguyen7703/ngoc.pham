-- 42-43. TÀI KHOẢN GIAO DỊCH >> THỐNG KÊ THEO THỜI GIAN >> TỔNG SỐ TÀI KHOẢN (LŨY KẾ) + TỔNG SỐ TK MỞ MỚI
/* Tham số:
 *  :period_type  Loại kỳ: D (Ngày) | M (Tháng) | Q (Quý) | Y (Năm)
 *  :period_code  Kỳ: D = yyyy-MM-dd | M = yyyy-MM | Q = yyyy-Q[1-4] | Y = yyyy
 */
WITH
-- I. THAM SỐ
-- 1. Xác định ngày đầu và ngày cuối khoảng báo cáo.
params AS (
  SELECT
    period_type,
    MAX(IF(boundary_type = 'FROM', start_date, NULL)) AS from_date,
    MAX(IF(boundary_type = 'TO', CASE period_type WHEN 'D' THEN start_date WHEN 'M' THEN LAST_DAY(start_date) WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(start_date, 2)) WHEN 'Y' THEN LAST_DAY(ADD_MONTHS(start_date, 11)) END, NULL)) AS to_date
  FROM (
    SELECT
        period_type,
        boundary_type,
        CASE period_type
          WHEN 'D' THEN TO_DATE(period_code, 'yyyy-MM-dd')
          WHEN 'M' THEN TO_DATE(CONCAT(period_code, '-01'), 'yyyy-MM-dd')
          WHEN 'Q' THEN MAKE_DATE(CAST(SUBSTR(period_code, 1, 4) AS INT), (CAST(SUBSTR(period_code, 7, 1) AS INT) - 1) * 3 + 1, 1)
          WHEN 'Y' THEN MAKE_DATE(CAST(period_code AS INT), 1, 1)
        END AS start_date
    FROM VALUES (:period_type, 'FROM', :period_from), (:period_type, 'TO', :period_to) AS t(period_type, boundary_type, period_code)
  ) s
  GROUP BY period_type
)
-- 2. Sinh đầy đủ các kỳ trong khoảng [Từ kỳ, Đến kỳ] để vẽ biểu đồ lũy kế từng kỳ
, periods AS (
  SELECT
    p.period_type,
    CASE p.period_type
      WHEN 'D' THEN DATE_FORMAT(period_start, 'yyyy-MM-dd')
      WHEN 'M' THEN DATE_FORMAT(period_start, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(period_start), '-Q', QUARTER(period_start))
      WHEN 'Y' THEN DATE_FORMAT(period_start, 'yyyy')
    END AS period_code
  FROM params p
  LATERAL VIEW EXPLODE(
    CASE p.period_type
      WHEN 'D' THEN SEQUENCE(p.from_date, p.to_date, INTERVAL 1 DAY)
      WHEN 'M' THEN SEQUENCE(p.from_date, p.to_date, INTERVAL 1 MONTH)
      WHEN 'Q' THEN SEQUENCE(p.from_date, p.to_date, INTERVAL 3 MONTHS)
      WHEN 'Y' THEN SEQUENCE(p.from_date, p.to_date, INTERVAL 1 YEAR)
    END
  ) t AS period_start
  WHERE p.from_date <= p.to_date
)
-- II. Bắt đầu lấy số liệu
-- 3. Tổng số lượng tài khoản mở/đóng theo ngày đến hết [Đến kỳ]
, count_acc_open_close_daily AS (
  SELECT 'OPEN' AS event_type, o.open_date AS event_date, COUNT(o.trading_account_no) AS acc_cnt
  FROM uat_vsdc_stg.open_investors o
  JOIN params p ON o.open_date <= p.to_date
  GROUP BY o.open_date
  UNION ALL
  SELECT 'CLOSE' AS event_type, c.close_date AS event_date, COUNT(c.trading_account_no) AS acc_cnt
  FROM uat_vsdc_stg.closed_investors c
  JOIN params p ON c.close_date <= p.to_date
  GROUP BY c.close_date
)
-- 4. Số tài khoản lũy kế trước [Từ kỳ]
, opening_balance AS (
  SELECT NVL(SUM(IF(a.event_type = 'OPEN', a.acc_cnt, -a.acc_cnt)), 0) AS begin_acc_cum
  FROM count_acc_open_close_daily a
  JOIN params p ON a.event_date < p.from_date
)
-- 5. Tổng hợp phát sinh theo kỳ trong khoảng [Từ kỳ, Đến kỳ]
, period_counts AS (
  SELECT
    period_type,
    period_code,
    SUM(IF(event_type = 'OPEN', acc_cnt, 0)) AS open_in_period,
    SUM(IF(event_type = 'CLOSE', acc_cnt, 0)) AS close_in_period
  FROM (
    SELECT
      p.period_type,
      CASE p.period_type
        WHEN 'D' THEN DATE_FORMAT(a.event_date, 'yyyy-MM-dd')
        WHEN 'M' THEN DATE_FORMAT(a.event_date, 'yyyy-MM')
        WHEN 'Q' THEN CONCAT(CAST(YEAR(a.event_date) AS STRING), '-Q', CAST(QUARTER(a.event_date) AS STRING))
        WHEN 'Y' THEN CAST(YEAR(a.event_date) AS STRING)
      END AS period_code,
      a.event_type,
      a.acc_cnt
    FROM count_acc_open_close_daily a
    CROSS JOIN params p
    WHERE a.event_date BETWEEN p.from_date AND p.to_date
  ) s
  GROUP BY period_type, period_code
)
-- 6. Bổ sung kỳ không phát sinh, điền số lượng bằng 0.
, period_data AS (
  SELECT
    p.period_type,
    p.period_code,
    NVL(c.open_in_period, 0) AS open_in_period,
    NVL(c.close_in_period, 0) AS close_in_period
  FROM periods p
  LEFT JOIN period_counts c ON p.period_type = c.period_type AND p.period_code = c.period_code
)
-- 7. Chỉ tiêu lên báo cáo
SELECT
  c.period_type,
  c.period_code,
  b.begin_acc_cum + SUM(c.open_in_period - c.close_in_period) OVER (ORDER BY c.period_code ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_cum,
  c.open_in_period
FROM period_data c
CROSS JOIN opening_balance b
ORDER BY c.period_code;

---------------------------------------------------------------------
-- 42-43. TÀI KHOẢN GIAO DỊCH >> THỐNG KÊ THEO THỜI GIAN >> TỔNG SỐ TÀI KHOẢN (LŨY KẾ) + TỔNG SỐ TK MỞ MỚI
/* CHỈ LÊN CÁC KỲ CÓ PHÁT SINH TK MỚI
 * Tham số:
 *  :period_type  Loại kỳ: D (Ngày) | M (Tháng) | Q (Quý) | Y (Năm)
 *  :period_code  Kỳ: D = yyyy-MM-dd | M = yyyy-MM | Q = yyyy-Q[1-4] | Y = yyyy
 */
WITH
-- 1. THAM SỐ -> Xác định khoảng ngày báo cáo.
params AS (
  SELECT
    period_type,
    MAX(IF(boundary_type = 'FROM', start_date, NULL)) AS from_date, -- Ngày đầu của Từ kỳ
    MAX(IF(boundary_type = 'TO', 
      CASE period_type 
        WHEN 'D' THEN start_date 
        WHEN 'M' THEN LAST_DAY(start_date) 
        WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(start_date, 2)) 
        WHEN 'Y' THEN LAST_DAY(ADD_MONTHS(start_date, 11)) END, NULL)
    ) AS to_date -- Ngày cuối của Đến kỳ
  FROM (
    SELECT
      period_type,
      boundary_type,
      CASE :period_type
          WHEN 'D' THEN TO_DATE(period_code, 'yyyy-MM-dd')
          WHEN 'M' THEN TO_DATE(CONCAT(period_code, '-01'), 'yyyy-MM-dd')
          WHEN 'Q' THEN MAKE_DATE(CAST(SUBSTR(period_code, 1, 4) AS INT), (CAST(SUBSTR(period_code, 7, 1) AS INT) - 1) * 3 + 1, 1)
          WHEN 'Y' THEN MAKE_DATE(CAST(period_code AS INT), 1, 1)
      END AS start_date -- Ngày đầu của Từ kỳ, Đến kỳ
    FROM (SELECT * FROM VALUES (:period_type, 'FROM', :period_from), (:period_type, 'TO', :period_to) AS t(period_type, boundary_type, period_code)) -- Tham số đầu vào
  ) GROUP BY period_type
)
-- 2. Tổng số lượng TK mở/đóng theo ngày đến hết kỳ kết thúc
, count_acc_open_close_daily AS (
  SELECT 'OPEN' event_type, o.open_date AS event_date, COUNT(o.trading_account_no) acc_cnt
  FROM uat_vsdc_stg.open_investors o
  JOIN params p ON o.open_date <= p.to_date --> Lọc dữ liệu <= Ngày cuối kỳ
  GROUP BY o.investor_type, o.open_date
  UNION ALL
  SELECT 'CLOSE' event_type, c.close_date AS event_date, COUNT(c.trading_account_no) acc_cnt
  FROM uat_vsdc_stg.closed_investors c
  JOIN params p ON c.close_date <= p.to_date --> Lọc dữ liệu <= Ngày cuối kỳ
  GROUP BY c.investor_type, c.close_date
)
-- 3. SL TK lũy kế đầu kỳ
, opening_balance AS (
  SELECT NVL(SUM(IF(a.event_type = 'OPEN', a.acc_cnt, -1 * a.acc_cnt)), 0) AS begin_acc_cum
  FROM count_acc_open_close_daily a
  JOIN params p ON a.event_date < p.from_date -- Tính tổng số TK đến trước ngày đầu kỳ
)
-- 4. Tổng hợp số lượng tài khoản phát sinh mở/đóng từng kỳ trong khoảng [Từ kỳ, Đến kỳ]
, period_counts AS (
  SELECT
    period_type,
    period_code,
    SUM(IF(event_type = 'OPEN', acc_cnt, 0)) AS open_in_period,  -- SL TK mở mới trong kỳ
    SUM(IF(event_type = 'CLOSE', acc_cnt, 0)) AS close_in_period -- SL TK đóng trong kỳ
  FROM (
    -- Lọc dữ liệu trong khoảng và xác định kỳ
    SELECT
      p.period_type,
      CASE p.period_type
        WHEN 'D' THEN DATE_FORMAT(a.event_date, 'yyyy-MM-dd')
        WHEN 'M' THEN DATE_FORMAT(a.event_date, 'yyyy-MM')
        WHEN 'Q' THEN CONCAT(CAST(YEAR(a.event_date) AS STRING), '-Q', CAST(QUARTER(a.event_date) AS STRING))
        WHEN 'Y' THEN CAST(YEAR(a.event_date) AS STRING)
      END AS period_code,
      a.event_type,
      acc_cnt
    FROM count_acc_open_close_daily a
    CROSS JOIN params p
    WHERE event_date >= p.from_date AND event_date <= p.to_date
  ) GROUP BY period_type, period_code
)
-- Chỉ tiêu lên báo cáo: SL TK lũy kế cuối kỳ = SL TK lũy kế đầu kỳ + SL mở - SL đóng trong kỳ
SELECT
  c.period_type,
  c.period_code,
  b.begin_acc_cum + SUM(c.open_in_period - c.close_in_period) OVER (ORDER BY c.period_code ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS total_cum,
  c.open_in_period
FROM period_counts c
CROSS JOIN opening_balance b
ORDER BY c.period_code;