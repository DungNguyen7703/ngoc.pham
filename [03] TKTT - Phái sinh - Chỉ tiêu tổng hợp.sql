-- THỐNG KÊ THỊ TRƯỜNG >> PHÁI SINH >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ
/* Tham số tra cứu: 
 * Sản phẩm phái sinh: HĐTL VN30, HĐTL VN100, HĐTL TPCP, Toàn thị trường
 * Loại kỳ: D/M/Q/Y
 * Kỳ: Ngày yyyy-MM-dd, Tháng yyyy-MM, Quý yyyy-Q[1-4], Năm yyyy
 */
WITH
-- 1. Tham số tra cứu -> Ngày đầu kỳ 
params AS (
  SELECT 
    derivative_product,
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
    END AS period_prev_startdate
  FROM (
  SELECT
    :derivative_product AS derivative_product, -- Sản phẩm phái sinh
    :period_type AS period_type, -- Loại kỳ
    :period_to AS period_to, -- Kỳ
    CAST(CASE :period_type
      WHEN 'D' THEN :period_to
      WHEN 'M' THEN CONCAT(:period_to, '-01')
      WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-',LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
      WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
      END AS DATE) AS period_to_startdate -- Ngày đầu kỳ này
  )
)
-- 2. Tham số tra cứu -> Điều kiện lọc kỳ này, kỳ trước
, periods AS (
  SELECT -- Kỳ này
    'CURRENT' AS period_key, period_to_startdate AS startdate, period_to_enddate AS enddate
  FROM params
  UNION ALL
  SELECT -- Kỳ trước
    'PREVIOUS' AS period_key, 
    period_prev_startdate AS startdate, 
    DATE_SUB(period_to_startdate, 1) AS enddate
  FROM params
)
-- 3. Danh sách mã chứng khoán phái sinh: Lấy bản ghi cuối ngày -> Dùng để phân loại sản phẩm phái sinh
, stock_daily_eod AS (
  SELECT tradingdate, symbol, symbolisin, underlyingsymbol, productid, productgrpid, contractmultiplier, derivative_product
  FROM (
    SELECT 
      s.tradingdate, 
      s.symbol, 
      s.symbolisin, 
      s.stocktype, 
      s.underlyingsymbol, 
      s.productid, -- 
      s.productgrpid, 
      CAST(s.contractmultiplier AS DOUBLE) AS contractmultiplier,
      -- Loại sản phẩm phái sinh: HĐTL VN30, HĐTL VN100, HĐTL TPCP, ...
      CONCAT((CASE stocktype WHEN '4' THEN 'HĐTL' WHEN '5' THEN 'HĐ quyền chọn' END), ' ', (CASE WHEN productgrpid = 'FBX' THEN 'TPCP' ELSE underlyingsymbol END)) AS derivative_product,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn 
    FROM uat_mdds_stg.jad_stockinfor s 
    CROSS JOIN params p
    WHERE s.tradingdate BETWEEN p.period_prev_startdate AND p.period_to_enddate -- Tính từ ngày đầu kỳ trước đến ngày cuối kỳ này
      AND s.floorcode = '03' -- Phái sinh
  ) 
  WHERE rn = 1
)
-- 4. Giao dịch phái sinh: Tổng theo ngày và loại sản phẩm phái sinh
, trade_daily AS (
  SELECT
    h.market_id,
    TO_DATE(h.trade_date, 'yyyyMMdd') trade_date,
    s.derivative_product,
    SUM(h.trade_quantity) AS klgd,
    SUM(CASE WHEN SUBSTR(h.buy_account_number,4,1) IN ('E','F') THEN h.trade_quantity END) AS ndtnn_mua_kl,
    SUM(CASE WHEN SUBSTR(h.sell_account_number,4,1) IN ('E','F') THEN h.trade_quantity END) AS ndtnn_ban_kl,
    SUM(CASE WHEN SUBSTR(h.buy_account_number,4,1) IN ('E','F') THEN h.trade_quantity ELSE 0 END)
      - SUM(CASE WHEN SUBSTR(h.sell_account_number,4,1) IN ('E','F') THEN h.trade_quantity ELSE 0 END) AS ndtnn_rong_kl
  FROM uat_hnx_stg.trade_book h  
  LEFT JOIN stock_daily_eod s ON TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate AND h.issue_code = s.symbolisin 
  CROSS JOIN params p
  WHERE h.market_id IN ('DVX')
  -- Lọc trade_date kiểu string dạng yyyyMMdd -> Dữ liệu từ ngày đầu kỳ trước đến ngày cuối kỳ báo cáo
    AND h.trade_date BETWEEN DATE_FORMAT(p.period_prev_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') 
  GROUP BY h.market_id, h.trade_date, h.issue_code, s.derivative_product
)
-- 5. Giao dịch phái sinh: Tổng hợp kỳ này và kỳ trước
, trade_period AS (
  SELECT
    p.period_key,
    t.derivative_product,
    SUM(t.klgd) AS klgd,
      SUM(t.ndtnn_mua_kl) AS ndtnn_mua_kl,
      SUM(t.ndtnn_ban_kl) AS ndtnn_ban_kl,
      SUM(t.ndtnn_rong_kl) AS ndtnn_rong_kl
  FROM periods p
  LEFT JOIN trade_daily t ON t.trade_date BETWEEN p.startdate AND p.enddate
  GROUP BY p.period_key, t.derivative_product 
)
-- Khối lượng mở: Tổng theo ngày và loại sản phẩm phái sinh
, oi_daily AS (
  SELECT 
    o.report_date,
    s.derivative_product, -- Loại sản phẩm phái sinh
    SUM(o.open_interest_volume) AS open_interest_volume
  FROM uat_vsdc_stg.end_of_day_open_interest o
  LEFT JOIN stock_daily_eod s ON o.report_date = s.tradingdate AND o.contract_code = s.symbol
  CROSS JOIN params p 
  WHERE o.report_date BETWEEN p.period_prev_startdate AND p.period_to_enddate
  GROUP BY o.report_date, s.derivative_product
)
-- Khối lượng mở: Lấy giá trị tại ngày cuối mỗi kỳ
, oi_period AS (
  SELECT period_key, report_date, derivative_product, khoiluongmo
  FROM (
    SELECT 
      p.period_key,
      i.report_date,
      i.derivative_product,
      i.open_interest_volume AS khoiluongmo,
      ROW_NUMBER() over(PARTITION BY i.derivative_product, p.period_key ORDER BY i.report_date DESC) AS rn_eop 
    FROM periods p
    LEFT JOIN oi_daily i ON i.report_date BETWEEN p.startdate AND p.enddate
  ) 
  WHERE rn_eop = 1
)
-- 6. Chuyển chỉ tiêu thành hàng
, metric_list AS (
  SELECT 
    period_key, 
    :derivative_product AS derivative_product,
    metric,
    SUM(value) AS value
  FROM (
    SELECT period_key, derivative_product, klgd, ndtnn_mua_kl, ndtnn_ban_kl, ndtnn_rong_kl, NULL khoiluongmo
    FROM trade_period
    UNION ALL 
    SELECT period_key, derivative_product, NULL klgd, NULL ndtnn_mua_kl, NULL ndtnn_ban_kl, NULL ndtnn_rong_kl, khoiluongmo
    FROM oi_period
  )
  UNPIVOT (
    value FOR metric IN (klgd, ndtnn_mua_kl, ndtnn_ban_kl, ndtnn_rong_kl, khoiluongmo)
  )
  WHERE derivative_product = :derivative_product OR :derivative_product = 'Toàn thị trường'
  GROUP BY period_key, :derivative_product, metric
) 
SELECT 
  p.period_type,
  p.period_to,
  p.derivative_product,
  d.metric,
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