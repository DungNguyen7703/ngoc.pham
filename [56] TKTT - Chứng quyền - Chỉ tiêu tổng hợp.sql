-- THỐNG KÊ THỊ TRƯỜNG >> CHỨNG QUYỀN (CW) >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ, SO SÁNH KỲ LIỀN TRƯỚC
/* Tham số tra cứu:
 * :period_type - Loại kỳ: D/M/Q/Y
 * :period_to   - Kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * Quy tắc:
 *   - Chứng quyền: jad_stockinfor.floorcode = '10' (HOSE) AND stocktype = '4'; giao dịch lấy từ uat_hose_stg.trade_book (market_id = 'STK')
 */
WITH
-- 1. THAM SỐ KỲ TRA CỨU: Ngày đầu - ngày cuối kỳ
params_base AS (
  SELECT
    :period_type AS period_type,
    :period_to   AS period_to,
    CASE :period_type
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN TO_DATE(CONCAT(:period_to, '-01'))
      WHEN 'Q' THEN ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), (CAST(RIGHT(:period_to, 1) AS INT) - 1) * 3)
      WHEN 'Y' THEN MAKE_DATE(CAST(:period_to AS INT), 1, 1)
    END AS period_startdate, -- Ngày đầu kỳ tra cứu
    CASE :period_type
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), CAST(RIGHT(:period_to, 1) AS INT) * 3 - 1))
      WHEN 'Y' THEN MAKE_DATE(CAST(:period_to AS INT), 12, 31)
    END AS period_enddate    -- Ngày cuối kỳ tra cứu
)
-- Phiên giao dịch liền trước (chỉ dùng cho loại kỳ D)
, prev_session AS (
  SELECT MAX(m.tradingdate) AS prev_date
  FROM uat_mdds_stg.jad_marketinfor m
  CROSS JOIN params_base b
  WHERE b.period_type = 'D'
    AND m.tradingdate <  b.period_startdate
)
-- 2. THAM SỐ 2 KỲ: cur = kỳ tra cứu, prev = kỳ liền trước
, params AS (
  SELECT 'cur' AS period_tag, period_startdate, period_enddate
  FROM params_base
  UNION ALL
  SELECT
    'prev' AS period_tag,
    CASE WHEN b.period_type = 'D' THEN ps.prev_date
      ELSE ADD_MONTHS(b.period_startdate, MAP('M',-1,'Q',-3,'Y',-12)[b.period_type])
    END AS period_startdate,
    CASE WHEN b.period_type = 'D' THEN ps.prev_date
      ELSE LAST_DAY(ADD_MONTHS(b.period_enddate, MAP('M',-1,'Q',-3,'Y',-12)[b.period_type]))
    END AS period_enddate
  FROM params_base b
  CROSS JOIN prev_session ps
)
-- Khoảng ngày đọc dữ liệu: từ ngày đầu kỳ trước đến ngày cuối kỳ này
, date_range AS (
  SELECT MIN(period_startdate) AS from_date, MAX(period_enddate) AS to_date
  FROM params
)
-- 3. DANH SÁCH MÃ CHỨNG QUYỀN trong khoảng ngày đọc dữ liệu
, stock_eod AS (
  SELECT tradingdate, symbol
  FROM (
    SELECT s.tradingdate, s.symbol, ROW_NUMBER() OVER(PARTITION BY s.tradingdate, s.symbol ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN date_range r
    WHERE s.tradingdate BETWEEN r.from_date AND r.to_date
      AND s.floorcode = '10' AND s.stocktype = '4'  -- Chứng quyền
  ) WHERE rn = 1
)
-- 4. KLGD, GTGD chứng quyền theo ngày
, trade_daily AS (
  SELECT /*+ BROADCAST(c) */
    t.trade_date,
    SUM(t.execution_volume) AS klgd,
    SUM(t.execution_value)  AS gtgd
  FROM uat_hose_stg.trade_book t
  JOIN stock_eod s ON t.symbol = s.symbol AND t.tradedate = s.tradingdate
  CROSS JOIN date_range r
  WHERE t.market_id = 'STK'
    AND t.trade_date BETWEEN r.from_date AND r.to_date
  GROUP BY t.trade_date
)
-- 5. Ngày giao dịch --> để tính số phiên
, session_daily AS (
  SELECT DISTINCT m.tradingdate
  FROM uat_mdds_stg.jad_marketinfor m
  CROSS JOIN date_range r
  WHERE m.tradingdate BETWEEN r.from_date AND r.to_date
)
-- 6. Tổng hợp theo kỳ
, period_agg AS (
  SELECT
    p.period_tag,
    NVL(t.klgd, 0) AS klgd,
    NVL(t.gtgd, 0) AS gtgd,
    s.so_phien,
    NVL(t.klgd, 0) / NULLIF(s.so_phien, 0) AS klgd_bq,
    NVL(t.gtgd, 0) / NULLIF(s.so_phien, 0) AS gtgd_bq
  FROM params p
  LEFT JOIN (
    SELECT p.period_tag, SUM(t.klgd) AS klgd, SUM(t.gtgd) AS gtgd
    FROM params p
    JOIN trade_daily t ON t.trade_date BETWEEN p.period_startdate AND p.period_enddate
    GROUP BY p.period_tag
  ) t ON t.period_tag = p.period_tag
  LEFT JOIN (
    SELECT p.period_tag, COUNT(s.tradingdate) AS so_phien
    FROM params p
    JOIN session_daily s ON s.tradingdate BETWEEN p.period_startdate AND p.period_enddate
    GROUP BY p.period_tag
  ) s ON s.period_tag = p.period_tag
)
-- 7. Chuyển chỉ tiêu thành hàng, ghép kỳ này - kỳ trước
, metric_list AS (
  SELECT u.sort_order, u.metric, u.metric_name,
    MAX(CASE WHEN a.period_tag = 'cur'  THEN u.value END) AS curr_value,
    MAX(CASE WHEN a.period_tag = 'prev' THEN u.value END) AS prev_value
  FROM period_agg a
  LATERAL VIEW STACK(4,
    1, 'KLGD',    'Khối lượng giao dịch',            CAST(a.klgd    AS DECIMAL(38,4)),
    2, 'GTGD',    'Giá trị giao dịch',               CAST(a.gtgd    AS DECIMAL(38,4)),
    3, 'KLGD_BQ', 'Khối lượng giao dịch bình quân',  CAST(a.klgd_bq AS DECIMAL(38,4)),
    4, 'GTGD_BQ', 'Giá trị giao dịch bình quân',     CAST(a.gtgd_bq AS DECIMAL(38,4))
  ) u AS sort_order, metric, metric_name, value
  GROUP BY u.sort_order, u.metric, u.metric_name
)
SELECT
  b.period_type,
  b.period_to,
  m.metric,
  m.metric_name,
  m.curr_value,
  m.prev_value,
  m.curr_value - m.prev_value AS change_value,
  ROUND((m.curr_value - m.prev_value) / NULLIF(ABS(m.prev_value), 0) * 100, 2) AS change_percent -- % so với kỳ trước
FROM params_base b
CROSS JOIN metric_list m
ORDER BY m.sort_order
;