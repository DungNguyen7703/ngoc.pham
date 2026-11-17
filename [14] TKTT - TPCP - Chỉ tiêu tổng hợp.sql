-- THỐNG KÊ THỊ TRƯỜNG >> TPCP >> CHỈ TIÊU TỔNG HỢP
/* Tham số tra cứu:
 * Loại kỳ: D/M/Q/Y
 * Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH
-- Từ tham số loại kỳ, kỳ báo cáo lấy ra Ngày đầu kỳ trước và ngày cuối kỳ này
params AS (
  SELECT
    period_type,
    period_code,
    period_to_startdate,
    CASE period_type
      WHEN 'D' THEN period_to_startdate
      WHEN 'M' THEN LAST_DAY(period_to_startdate)
      WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 3), 1)
      WHEN 'Y' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 12), 1)
    END AS period_to_enddate,
    CASE period_type
      WHEN 'D' THEN DATE_SUB(period_to_startdate, 1)
      WHEN 'M' THEN ADD_MONTHS(period_to_startdate, -1)
      WHEN 'Q' THEN ADD_MONTHS(period_to_startdate, -3)
      WHEN 'Y' THEN ADD_MONTHS(period_to_startdate, -12)
    END AS period_prev_startdate,
    DATE_SUB(period_to_startdate, 1) AS period_prev_enddate
  FROM (
    SELECT
      :period_type AS period_type, -- Loại kỳ
      :period_to AS period_code, -- Kỳ báo cáo
      CAST(
        CASE :period_type
          WHEN 'D' THEN :period_to
          WHEN 'M' THEN CONCAT(:period_to, '-01')
          WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
          WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
        END AS DATE
      ) AS period_to_startdate -- Ngày đầu kỳ này
  )
)
-- Thời gian Kỳ này, kỳ trước
, periods AS (
  SELECT 
    'CURRENT' AS period_key, 
    period_code,
    period_to_startdate AS period_startdate, 
    period_to_enddate AS period_enddate
  FROM params
  UNION ALL
  SELECT 
    'PREVIOUS' AS period_key, 
    CASE period_type
      WHEN 'D' THEN date_format(period_prev_startdate, 'yyyy-MM-dd')
      WHEN 'M' THEN date_format(period_prev_startdate, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(CAST(year(period_prev_startdate) AS string), '-Q', CAST(CAST(FLOOR((month(period_prev_startdate) - 1) / 3) + 1 AS int) AS string))
      WHEN 'Y' THEN CAST(YEAR(period_prev_startdate) AS string)
    END AS period_code, 
    period_prev_startdate AS period_startdate, 
    period_prev_enddate AS period_enddate
  FROM params
)
-- Tính tổng giao dịch theo ngày: từ ngày đầu năm của kỳ trước đến ngày cuối của kỳ này
, daily_trade_data AS (
  SELECT 
    'OUTRIGHT' order_tool, 
    o.trading_date, 
    SUM(o.volume) AS klgd, 
    SUM(o.trading_value) AS gtgd,
    SUM(CASE WHEN SUBSTR(o.buying_account_no,4,1) IN ('E','F') THEN o.trading_value END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN SUBSTR(o.selling_account_no,4,1) IN ('E','F') THEN o.trading_value END) AS gtgd_ndtnn_ban
  FROM uat_hnx_stg.outright_order_book o 
  CROSS JOIN params p
  WHERE o.order_status = 'ĐTH'
    AND o.trading_date BETWEEN p.period_prev_startdate AND p.period_to_enddate -- Từ ngày đầu kỳ trước đến ngày cuối kỳ này
  GROUP BY o.trading_date
  UNION ALL 
  SELECT 
    'REPO' order_tool, 
    r.trading_date, 
    SUM(r.volume) AS klgd, 
    SUM(r.first_settlement_value) AS gtgd,
    SUM(CASE WHEN SUBSTR(r.buying_account_no,4,1) IN ('E','F') THEN r.first_settlement_value END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN SUBSTR(r.selling_account_no,4,1) IN ('E','F') THEN r.first_settlement_value END) AS gtgd_ndtnn_ban
  FROM uat_hnx_stg.repo_order_book r 
  CROSS JOIN params p
  WHERE r.order_status = 'ĐTH'
    AND r.trading_date BETWEEN p.period_prev_startdate AND p.period_to_enddate -- Từ ngày đầu kỳ trước đến ngày cuối kỳ này
  GROUP BY r.trading_date
)
-- Tính chỉ tiêu thống kê giao dịch TPCP kỳ này, kỳ trước
, period_metrics AS (
  SELECT
    c.period_key,
    c.period_code,
    SUM(d.klgd) AS klgd,
    SUM(d.gtgd) AS gtgd,
    SUM(d.gtgd) AS gtgd_ytd,
    SUM(d.gtgd_ndtnn_mua) AS gtgd_ndtnn_mua,
    SUM(d.gtgd_ndtnn_ban) AS gtgd_ndtnn_ban,
    SUM(NVL(gtgd_ndtnn_mua, 0) - NVL(gtgd_ndtnn_ban, 0)) AS gtgd_ndtnn_rong
  FROM periods c
  LEFT JOIN daily_trade_data d ON d.trading_date BETWEEN c.period_startdate AND c.period_enddate
  GROUP BY c.period_key, c.period_code
)
-- Số liệu lên dashboard (Có So sánh với kỳ trước)
SELECT
  p.period_type AS loaiky, 
  p.period_code AS ky, 
  b.period_code AS kytruoc,
  c.klgd, 
  (NVL(c.klgd, 0) - NVL(b.klgd, 0)) AS klgd_thaydoi, 
  (NVL(c.klgd, 0) - NVL(b.klgd, 0)) / NULLIF(b.klgd, 0) * 100 AS klgd_thaydoi_pt, 
  c.gtgd, 
  (NVL(c.gtgd, 0) - NVL(b.gtgd, 0)) AS gtgd_thaydoi, 
  (NVL(c.gtgd, 0) - NVL(b.gtgd, 0)) / NULLIF(b.gtgd, 0) * 100 AS gtgd_thaydoi_pt, 
  c.gtgd_ndtnn_mua, 
  (NVL(c.gtgd_ndtnn_mua, 0) - NVL(b.gtgd_ndtnn_mua, 0)) AS gtgd_ndtnn_mua_thaydoi, 
  (NVL(c.gtgd_ndtnn_mua, 0) - NVL(b.gtgd_ndtnn_mua, 0)) / NULLIF(b.gtgd_ndtnn_mua, 0) * 100 AS gtgd_ndtnn_mua_thaydoi_pt, 
  c.gtgd_ndtnn_ban, 
  (NVL(c.gtgd_ndtnn_ban, 0) - NVL(b.gtgd_ndtnn_ban, 0)) AS gtgd_ndtnn_ban_thaydoi, 
  (NVL(c.gtgd_ndtnn_ban, 0) - NVL(b.gtgd_ndtnn_ban, 0)) / NULLIF(b.gtgd_ndtnn_ban, 0) * 100 AS gtgd_ndtnn_ban_thaydoi_pt, 
  c.gtgd_ndtnn_rong, 
  (NVL(c.gtgd_ndtnn_rong, 0) - NVL(b.gtgd_ndtnn_rong, 0)) AS gtgd_ndtnn_rong_thaydoi, 
  (NVL(c.gtgd_ndtnn_rong, 0) - NVL(b.gtgd_ndtnn_rong, 0)) / NULLIF(ABS(b.gtgd_ndtnn_rong), 0) * 100 AS gtgd_ndtnn_rong_thaydoi_pt 
FROM params p
CROSS JOIN period_metrics c -- Kỳ này
CROSS JOIN period_metrics b -- Kỳ trước
WHERE c.period_key = 'CURRENT'
  AND b.period_key = 'PREVIOUS'
;