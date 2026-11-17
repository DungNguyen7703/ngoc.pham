-- THỐNG KÊ THỊ TRƯỜNG >> TPCP >> DIỄN BIẾN GIAO DỊCH / GIÁ TRỊ MUA/BÁN RÒNG NĐTNN
/* Tham số tra cứu:
 * Loại kỳ: D/M/Q/Y
 * Từ kỳ - Đến kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH 
-- Tham số tra cứu: Loại kỳ, Từ kỳ, Đến kỳ -> Lấy ra ngày đầu - ngày cuối lọc dữ liệu
params AS (
  SELECT
    :period_type AS period_type, -- Loại kỳ
    CAST(CASE :period_type
      WHEN 'D' THEN :period_from
      WHEN 'M' THEN CONCAT(:period_from, '-01')
      WHEN 'Q' THEN CONCAT(SUBSTR(:period_from, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_from, 7, 1) AS int) * 3 - 2 AS string), 2, '0'), '-01')
      WHEN 'Y' THEN CONCAT(:period_from, '-01-01')
    END AS date) AS period_from_startdate, -- Ngày đầu của "Từ kỳ"
  CAST(CASE :period_type
    WHEN 'D' THEN :period_to
    WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01'), 'yyyy-MM-dd'))
    WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01'), 'yyyy-MM-dd'), CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3),1)
    WHEN 'Y' THEN CONCAT(:period_to, '-12-31')
  END AS date) AS period_to_enddate --Ngày cuối của "Đến kỳ"
)
-- Tính tổng giao dịch theo ngày: từ ngày đầu của Từ kỳ đến ngày cuối của Đến kỳ
, daily_trade_data AS (
  SELECT 
    CASE period_type
      WHEN 'D' THEN date_format(trading_date, 'yyyy-MM-dd')
      WHEN 'M' THEN date_format(trading_date, 'yyyy-MM')
      WHEN 'Q' THEN concat(CAST(year(trading_date) AS string), '-Q', CAST(CAST(floor((month(trading_date) - 1) / 3) + 1 AS int) AS string))
      WHEN 'Y' THEN CAST(year(trading_date) AS string)
    END AS period_code,
    x.*
  FROM (
    SELECT
      p.period_type,
      'OUTRIGHT' order_tool, 
      o.trading_date, 
      SUM(o.volume) AS klgd, 
      SUM(o.trading_value) AS gtgd,
      SUM(CASE WHEN SUBSTR(o.buying_account_no,4,1) IN ('E','F') THEN o.trading_value END) AS gtgd_ndtnn_mua,
      SUM(CASE WHEN SUBSTR(o.selling_account_no,4,1) IN ('E','F') THEN o.trading_value END) AS gtgd_ndtnn_ban
    FROM uat_hnx_stg.outright_order_book o 
    CROSS JOIN params p
    WHERE o.order_status = 'ĐTH'
      AND o.trading_date BETWEEN p.period_from_startdate AND p.period_to_enddate -- Từ ngày đầu kỳ trước đến ngày cuối kỳ này
    GROUP BY o.trading_date, p.period_type
    UNION ALL 
    SELECT 
      p.period_type,
      'REPO' order_tool, 
      r.trading_date, 
      SUM(r.volume) AS klgd, 
      SUM(r.first_settlement_value) AS gtgd,
      SUM(CASE WHEN SUBSTR(r.buying_account_no,4,1) IN ('E','F') THEN r.first_settlement_value END) AS gtgd_ndtnn_mua,
      SUM(CASE WHEN SUBSTR(r.selling_account_no,4,1) IN ('E','F') THEN r.first_settlement_value END) AS gtgd_ndtnn_ban
    FROM uat_hnx_stg.repo_order_book r 
    CROSS JOIN params p
    WHERE r.order_status = 'ĐTH'
      AND r.trading_date BETWEEN p.period_from_startdate AND p.period_to_enddate -- Từ ngày đầu kỳ trước đến ngày cuối kỳ này
    GROUP BY r.trading_date, p.period_type
  ) x
)
-- Dữ liệu lên dashboard -> Tổng theo kỳ
SELECT 
  period_type,
  period_code,
  SUM(klgd) AS klgd, 
  SUM(gtgd) AS gtgd, 
  SUM(gtgd_ndtnn_mua) AS gtgd_ndtnn_mua, 
  SUM(gtgd_ndtnn_ban) AS gtgd_ndtnn_ban
FROM daily_trade_data t
GROUP BY period_type, period_code
;