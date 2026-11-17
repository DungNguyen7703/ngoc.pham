-- THỐNG KÊ THỊ TRƯỜNG >> TPDNNY >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ
-- Lưu ý: GTGD YTD và GTGD bình quân YTD so sánh với CẢ NĂM TRƯỚC (01/01 - 31/12 năm trước); các chỉ tiêu còn lại so với kỳ trước. Phần tính theo kỳ (trade_period) và phần tính YTD (ytd_period) được tách riêng thành 2 CTE độc lập
/* Tham số tra cứu:
 * Loại kỳ: D/M/Q/Y
 * Kỳ: Ngày yyyy-MM-dd, Tháng yyyy-MM, Quý yyyy-Q[1-4], Năm yyyy
 */
WITH
-- 1. Tham số tra cứu -> Ngày đầu kỳ
params AS (
  SELECT
    period_type,
    -- Kỳ này
    period_to,
    period_to_startdate, -- Ngày đầu kỳ này
    CASE period_type
      WHEN 'D' THEN period_to_startdate
      WHEN 'M' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 1), 1)
      WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 3), 1)
      WHEN 'Y' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 12), 1)
    END AS period_to_enddate, -- Ngày cuối kỳ này
    -- Kỳ trước
    CASE period_type
      WHEN 'D' THEN DATE_SUB(period_to_startdate, 1)
      WHEN 'M' THEN ADD_MONTHS(period_to_startdate, -1)
      WHEN 'Q' THEN ADD_MONTHS(period_to_startdate, -3)
      WHEN 'Y' THEN ADD_MONTHS(period_to_startdate, -12)
    END AS period_prev_startdate,
    -- YTD: 01/01 năm của kỳ này; cả năm trước 01/01 - 31/12
    CAST(DATE_TRUNC('YEAR', period_to_startdate) AS DATE) AS period_to_ytd_start, -- 01/01 năm của kỳ này
    ADD_MONTHS(CAST(DATE_TRUNC('YEAR', period_to_startdate) AS DATE), -12) AS period_py_ytd_start, -- 01/01 năm trước
    DATE_SUB(CAST(DATE_TRUNC('YEAR', period_to_startdate) AS DATE), 1) AS period_py_ytd_end -- 31/12 năm trước
  FROM (
    SELECT
    :period_type AS period_type, -- Loại kỳ: D/M/Q/Y
    :period_to AS period_to, -- Kỳ: Ngày yyyy-MM-dd, Tháng yyyy-MM, Quý yyyy-Q[1-4], Năm yyyy
    CAST(CASE :period_type
      WHEN 'D' THEN :period_to
      WHEN 'M' THEN CONCAT(:period_to, '-01')
      WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-',LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
      WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
      END AS DATE) AS period_to_startdate -- Ngày đầu kỳ này
    )
)
-- 2. Thông tin kỳ này, kỳ trước (dùng cho KLGD, GTGD, GTGD NĐTNN và số mã niêm yết)
, periods AS (
  SELECT -- Kỳ này
    'CURRENT' AS period_key, period_type, period_to AS period_code, period_to_startdate AS startdate, period_to_enddate AS enddate
  FROM params
  UNION ALL
  SELECT -- Kỳ trước
    'PREVIOUS' AS period_key,
    period_type,
      CASE period_type
      WHEN 'D' THEN date_format(period_prev_startdate, 'yyyy-MM-dd')
      WHEN 'M' THEN date_format(period_prev_startdate, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(CAST(year(period_prev_startdate) AS string), '-Q', CAST(CAST(FLOOR((month(period_prev_startdate) - 1) / 3) + 1 AS int) AS string))
        WHEN 'Y' THEN CAST(YEAR(period_prev_startdate) AS string)
    END AS period_code,
    period_prev_startdate AS startdate,
    DATE_SUB(period_to_startdate, 1) AS enddate
  FROM params
)
-- 2b. Thời gian YTD (dùng cho GTGD YTD, GTGD bình quân YTD): kỳ này = 01/01 năm nay -> ngày cuối kỳ; năm trước = cả năm trước 01/01 - 31/12
, ytd_periods AS (
  SELECT 'CURRENT' AS ytd_key, period_to_ytd_start AS ytd_startdate, period_to_enddate AS ytd_enddate
  FROM params
  UNION ALL
  SELECT 'PREVIOUS_YEAR' AS ytd_key, period_py_ytd_start AS ytd_startdate, period_py_ytd_end AS ytd_enddate
  -- Dự phòng nếu muốn so với CÙNG KỲ năm trước (01/01 đến cùng ngày cuối kỳ năm trước) thay period_py_ytd_end bằng:
  --   CASE WHEN period_type = 'D' THEN ADD_MONTHS(period_to_enddate, -12) ELSE LAST_DAY(ADD_MONTHS(period_to_enddate, -12)) END
  FROM params
)
-- 3. GTGD và KLGD từng ngày: đọc từ ngày đầu năm trước đến cuối kỳ này (phủ cả kỳ trước và YTD năm trước)
, trade_daily AS (
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS tradingdate,
    SUM(h.trade_quantity) AS klgd,
    SUM(h.trade_quantity * h.trade_price) AS gtgd,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price END) AS ndtnn_mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price END) AS ndtnn_ban_gt,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END)
      - SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ndtnn_rong_gt
  FROM uat_hnx_stg.trade_book h
  CROSS JOIN params p
  WHERE h.market_id = 'HCX'
    AND h.trade_date BETWEEN DATE_FORMAT(p.period_py_ytd_start, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') -- Từ 01/01 năm trước đến cuối kỳ này
  GROUP BY h.trade_date
)
-- 4. Đếm số mã trái phiếu theo ngày
, stock_daily AS (
    SELECT
    s.tradingdate,
    COUNT(DISTINCT s.symbol) AS sl_ma_niemyet
  FROM uat_mdds_stg.jad_stockinfor s
  CROSS JOIN params p
  WHERE s.stocktype = '1' -- Trái phiếu
      AND s.tradingdate BETWEEN CAST(DATE_TRUNC('YEAR', p.period_prev_startdate) AS DATE) AND p.period_to_enddate
  GROUP BY s.tradingdate
)
-- 5. Chỉ tiêu theo kỳ (kỳ này, đúng kỳ trước): KLGD, GTGD, GTGD NĐTNN mua/bán/ròng
, trade_period AS (
  SELECT
    p.period_key,
    COALESCE(SUM(t.klgd), 0) AS klgd,
    COALESCE(SUM(t.gtgd), 0) AS gtgd,
    COALESCE(SUM(t.ndtnn_mua_gt), 0) AS ndtnn_mua_gt,
    COALESCE(SUM(t.ndtnn_ban_gt), 0) AS ndtnn_ban_gt,
    COALESCE(SUM(t.ndtnn_mua_gt), 0) - COALESCE(SUM(t.ndtnn_ban_gt), 0) AS ndtnn_rong_gt
  FROM periods p
  LEFT JOIN trade_daily t ON t.tradingdate BETWEEN p.startdate AND p.enddate
  GROUP BY p.period_key
)
-- 5b. Chỉ tiêu YTD (kỳ này và năm trước): GTGD YTD, số phiên có giao dịch, GTGD bình quân/phiên YTD
, ytd_period AS (
  SELECT
    y.ytd_key,
    SUM(COALESCE(t.gtgd, 0)) AS gtgd_ytd,
    COUNT(t.tradingdate) AS so_phien_ytd,
    SUM(COALESCE(t.gtgd, 0)) / NULLIF(COUNT(t.tradingdate), 0) AS gtgd_bq_ytd
  FROM ytd_periods y
  LEFT JOIN trade_daily t ON t.tradingdate BETWEEN y.ytd_startdate AND y.ytd_enddate
  GROUP BY y.ytd_key
)
, stock_period AS (
  SELECT
    p.period_key,
    -- Số mã tại ngày dữ liệu cuối cùng trong kỳ
    MAX_BY(CASE WHEN s.tradingdate >= p.startdate THEN s.sl_ma_niemyet END, s.tradingdate) AS sl_ma_niemyet
  FROM periods p
  LEFT JOIN stock_daily s ON s.tradingdate BETWEEN CAST(DATE_TRUNC('YEAR', p.enddate) AS DATE) AND p.enddate
  GROUP BY p.period_key
)
-- 6. Chuyển chỉ tiêu thành hàng. Với chỉ tiêu YTD: PREVIOUS = cả năm trước
, metric_list AS (
  SELECT
    period_key,
    metric,
    value
  FROM (
    SELECT period_key, klgd, gtgd, NULL gtgd_ytd, NULL gtgd_bq_ytd, ndtnn_mua_gt, ndtnn_ban_gt, ndtnn_rong_gt, NULL sl_ma_niemyet
    FROM trade_period
    UNION ALL
    SELECT CASE ytd_key WHEN 'CURRENT' THEN 'CURRENT' ELSE 'PREVIOUS' END AS period_key, NULL klgd, NULL gtgd, gtgd_ytd, gtgd_bq_ytd, NULL ndtnn_mua_gt, NULL ndtnn_ban_gt, NULL ndtnn_rong_gt, NULL sl_ma_niemyet
    FROM ytd_period
    UNION ALL
    SELECT period_key, NULL klgd, NULL gtgd, NULL gtgd_ytd, NULL gtgd_bq_ytd, NULL ndtnn_mua_gt, NULL ndtnn_ban_gt, NULL ndtnn_rong_gt, sl_ma_niemyet
    FROM stock_period
  )
  UNPIVOT (
    value FOR metric IN (klgd, gtgd, gtgd_ytd, gtgd_bq_ytd, ndtnn_mua_gt, ndtnn_ban_gt, ndtnn_rong_gt, sl_ma_niemyet)
  )
)
SELECT
  p.period_type,
  p.period_to,
  d.metric,
  CASE WHEN d.metric IN ('gtgd_ytd', 'gtgd_bq_ytd') THEN 'So sánh năm trước' ELSE 'So sánh kỳ trước' END AS compare_basis, -- Cơ sở so sánh của prev_value
  d.curr_value,
  d.prev_value,
  d.curr_value - d.prev_value AS change_value,
  (d.curr_value - d.prev_value) / NULLIF(d.prev_value, 0) * 100 AS change_percent
FROM params p
CROSS JOIN (
  SELECT
    metric,
    MAX(CASE WHEN period_key = 'CURRENT' THEN value END) AS curr_value,
    MAX(CASE WHEN period_key = 'PREVIOUS' THEN value END) AS prev_value
  FROM metric_list
  GROUP BY metric
) d
;