-- [05-06] THỐNG KÊ THỊ TRƯỜNG >> PHÁI SINH >> DIỄN BIẾN GIAO DỊCH / KHỐI LƯỢNG GIAO DỊCH NĐTNN
/* Tham số tra cứu: 
 * Sản phẩm phái sinh: HĐTL VN30, HĐTL VN100, HĐTL TPCP, Toàn thị trường
 * Loại kỳ: D/M/Q/Y
 * Từ kỳ - Đến kỳ: Ngày yyyy-MM-dd, Tháng yyyy-MM, Quý yyyy-Q[1-4], Năm yyyy
 * Chỉ tiêu: Khối lượng mở, KLGD, KLGD NĐTNN mua/bán/ròng, Giá HĐTL kỳ hạn gần nhất (giá đóng cửa ngày cuối kỳ)
 * Chi tiết: theo derivative_product_detail (VD: HĐTL TPCP -> HĐTL TPCP GB05, HĐTL TPCP GB10); 'Toàn thị trường' -> gộp 1 dòng/kỳ
 */
WITH 
-- Tham số tra cứu: Sàn, Loại kỳ, Từ kỳ, Đến kỳ
params AS (
SELECT
  derivative_product, 
  period_type, 
  MAP('D','DAY','M','MONTH','Q','QUARTER','Y','YEAR')[period_type] AS period_unit,
    -- Ngày đầu của "Từ kỳ"
    cast(CASE period_type
      WHEN 'D' THEN period_from
      WHEN 'M' THEN CONCAT(period_from, '-01')
      WHEN 'Q' THEN CONCAT(SUBSTR(period_from, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(period_from, 7, 1) AS int) * 3 - 2 AS string), 2, '0'), '-01')
      WHEN 'Y' THEN CONCAT(period_from, '-01-01')
    END AS date) AS period_from_startdate,
    --Ngày cuối của "Đến kỳ"
    CAST(CASE period_type
      WHEN 'D' THEN period_to
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(period_to, '-01'), 'yyyy-MM-dd'))
      WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(period_to, 1, 4), '-01-01'), 'yyyy-MM-dd'), CAST(SUBSTR(period_to, 7, 1) AS INT) * 3),1)
      WHEN 'Y' THEN CONCAT(period_to, '-12-31')
    END AS date) AS period_to_enddate
  FROM ( 
    SELECT -- Danh sách tham số tra cứu
      :derivative_product AS derivative_product, -- Sản phẩm phái sinh
      :period_type AS period_type, -- Loại kỳ
      :period_from AS period_from, -- Từ kỳ
      :period_to    AS period_to     -- Đến kỳ
  )
)
-- Danh sách mã chứng khoán phái sinh: Lấy bản ghi cuối ngày 
, stock_daily_eod AS (
  SELECT tradingdate, symbol, symbolisin, stocktype, underlyingsymbol, productid, productgrpid, contractmultiplier, derivative_product, derivative_product_detail,
    maturitydate, maturitymonthyear, closeprice
  FROM (
    SELECT 
      s.tradingdate, 
      s.symbol, 
      s.symbolisin, 
      s.stocktype, 
      s.underlyingsymbol, 
      s.productid, 
      s.productgrpid, 
      CAST(s.contractmultiplier AS DOUBLE) AS contractmultiplier,
      s.maturitydate, 
      s.maturitymonthyear, 
      CAST(s.closeprice AS DOUBLE) AS closeprice,
      -- Loại sản phẩm phái sinh: HĐTL VN30, HĐTL VN100, HĐTL TPCP, ...
      CONCAT((CASE stocktype WHEN '4' THEN 'HĐTL' WHEN '5' THEN 'HĐ quyền chọn' END), ' ', (CASE WHEN productgrpid = 'FBX' THEN 'TPCP' ELSE underlyingsymbol END)) AS derivative_product,
      -- Chi tiết sản phẩm: HĐTL VN30, HĐTL TPCP GB05, HĐTL TPCP GB10, ...
      CONCAT((CASE stocktype WHEN '4' THEN 'HĐTL' WHEN '5' THEN 'HĐ quyền chọn' END), (CASE WHEN productgrpid = 'FBX' THEN ' TPCP' ELSE '' END), ' ', underlyingsymbol) AS derivative_product_detail,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn 
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN params p
    WHERE s.tradingdate BETWEEN p.period_from_startdate AND p.period_to_enddate
      AND s.floorcode = '03' -- Phái sinh
  ) 
  WHERE rn = 1
)
-- Giao dịch phái sinh: Tổng theo ngày và loại sản phẩm phái sinh
, trade_daily AS (
  SELECT 
    market_id, 
    trade_date, 
    derivative_product, 
    derivative_product_detail, 
    klgd, 
    ndtnn_mua_kl, 
    ndtnn_ban_kl, 
    NVL(ndtnn_mua_kl, 0) - NVL(ndtnn_ban_kl,0) AS ndtnn_rong_kl
  FROM (
    SELECT
      h.market_id,
      TO_DATE(h.trade_date, 'yyyyMMdd') trade_date,
      s.derivative_product,
      s.derivative_product_detail,
      SUM(h.trade_quantity) AS klgd,
      SUM(CASE WHEN SUBSTR(h.buy_account_number,4,1) IN ('E','F') THEN h.trade_quantity END) AS ndtnn_mua_kl,
      SUM(CASE WHEN SUBSTR(h.sell_account_number,4,1) IN ('E','F') THEN h.trade_quantity END) AS ndtnn_ban_kl
    FROM uat_hnx_stg.trade_book h  
    LEFT JOIN stock_daily_eod s ON TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate AND h.issue_code = s.symbolisin 
    CROSS JOIN params p
    WHERE h.market_id IN ('DVX')
          AND h.trade_date BETWEEN DATE_FORMAT(p.period_from_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') -- Lọc trade_date kiểu string dạng yyyyMMdd
    GROUP BY h.market_id, h.trade_date, h.issue_code, s.derivative_product, s.derivative_product_detail
  )
)
, trade_period AS (
  SELECT
    CAST(DATE_TRUNC(p.period_unit, td.trade_date) AS DATE) AS period_fromdate,
    td.derivative_product,
    td.derivative_product_detail,
    SUM(td.klgd) AS klgd, 
    SUM(td.ndtnn_mua_kl) AS ndtnn_mua_kl, 
    SUM(td.ndtnn_ban_kl) AS ndtnn_ban_kl, 
    SUM(td.ndtnn_rong_kl) AS ndtnn_rong_kl
  FROM trade_daily td 
  CROSS JOIN params p  
  GROUP BY CAST(DATE_TRUNC(p.period_unit, td.trade_date) AS DATE), td.derivative_product, td.derivative_product_detail
)
-- Khối lượng mở: Tổng theo ngày và loại sản phẩm phái sinh
, oi_daily AS (
  SELECT 
    o.report_date,
    s.derivative_product,
    s.derivative_product_detail,
    SUM(o.open_interest_volume) AS open_interest_volume
  FROM uat_vsdc_stg.end_of_day_open_interest o
  LEFT JOIN stock_daily_eod s ON o.report_date = s.tradingdate AND o.contract_code = s.symbol
  CROSS JOIN params p 
  WHERE o.report_date BETWEEN p.period_from_startdate AND p.period_to_enddate
  GROUP BY o.report_date, s.derivative_product, s.derivative_product_detail
)
-- Khối lượng mở: Lấy giá trị tại ngày cuối mỗi kỳ
, oi_period AS (
  SELECT period_fromdate, report_date, derivative_product, derivative_product_detail, open_interest_volume
  FROM (
    SELECT 
      CAST(DATE_TRUNC(p.period_unit, i.report_date) AS DATE) AS period_fromdate, -- Ngày đầu mỗi kỳ
      i.report_date,
      i.derivative_product,
      i.derivative_product_detail,
      i.open_interest_volume,
      ROW_NUMBER() over(PARTITION BY i.derivative_product, i.derivative_product_detail, CAST(DATE_TRUNC(p.period_unit, i.report_date) AS DATE) ORDER BY i.report_date DESC) AS rn_eop 
    FROM oi_daily i
    CROSS JOIN params p
  ) 
  WHERE rn_eop = 1
)
-- Giá HĐTL kỳ hạn gần nhất theo ngày: mỗi ngày, mỗi sản phẩm (tài sản cơ sở) lấy hợp đồng có tháng đáo hạn gần nhất
, fut_nearest_daily AS (
  SELECT 
    tradingdate, symbol, derivative_product, derivative_product_detail, underlyingsymbol, maturitydate, maturitymonthyear, closeprice
  FROM (
    SELECT 
      s.tradingdate, s.symbol, s.derivative_product, s.derivative_product_detail, s.underlyingsymbol, s.maturitydate, s.maturitymonthyear, s.closeprice,
      ROW_NUMBER() OVER(PARTITION BY s.tradingdate, s.derivative_product, s.underlyingsymbol ORDER BY s.maturitymonthyear) AS maturity_rn
    FROM stock_daily_eod s -- Đã lọc phái sinh (floorcode = '03'), bản ghi cuối ngày
    WHERE s.stocktype = '4' -- Chỉ lấy HĐTL (không lấy HĐ quyền chọn)
  )
  WHERE maturity_rn = 1 -- Kỳ hạn gần nhất tại mỗi ngày
)
-- Giá HĐTL kỳ hạn gần nhất theo kỳ: lấy giá đóng cửa tại ngày giao dịch cuối mỗi kỳ
---- Tính theo derivative_product_detail: HĐTL TPCP có nhiều tài sản cơ sở (GB05, GB10) -> mỗi loại 1 giá
, fut_price_period AS (
  SELECT period_fromdate, derivative_product, derivative_product_detail, symbol AS hdtl_gannhat_symbol, closeprice AS gia_hdtl_gannhat
  FROM (
    SELECT 
      CAST(DATE_TRUNC(p.period_unit, f.tradingdate) AS DATE) AS period_fromdate, -- Ngày đầu mỗi kỳ
      f.derivative_product, f.derivative_product_detail, f.symbol, f.closeprice,
      ROW_NUMBER() OVER(PARTITION BY f.derivative_product_detail, CAST(DATE_TRUNC(p.period_unit, f.tradingdate) AS DATE) ORDER BY f.tradingdate DESC) AS rn_eop
    FROM fut_nearest_daily f
    CROSS JOIN params p
  )
  WHERE rn_eop = 1
)
-- Tổng hợp khối lượng mở, khối lượng giao dịch, giá HĐTL kỳ hạn gần nhất theo kỳ
, oi_trade_period AS (
  SELECT 
    p.period_type,
    CASE p.period_type
      WHEN 'D' THEN date_format(t.period_fromdate, 'yyyy-MM-dd')
      WHEN 'M' THEN date_format(t.period_fromdate, 'yyyy-MM')
      WHEN 'Q' THEN concat(CAST(year(t.period_fromdate) AS string), '-Q', CAST(CAST(floor((month(t.period_fromdate) - 1) / 3) + 1 AS int) AS string))
      WHEN 'Y' THEN CAST(year(t.period_fromdate) AS string)
    END AS period_code,
    t.period_fromdate,
    t.derivative_product,
    t.derivative_product_detail,
    SUM(t.klgd) AS klgd, 
    SUM(t.ndtnn_mua_kl) AS ndtnn_mua_kl, 
    SUM(t.ndtnn_ban_kl) AS ndtnn_ban_kl, 
    SUM(t.ndtnn_rong_kl) AS ndtnn_rong_kl, 
    SUM(t.open_interest_volume) AS khoiluongmo,
    MAX(t.hdtl_gannhat_symbol) AS hdtl_gannhat_symbol,
    MAX(t.gia_hdtl_gannhat) AS gia_hdtl_gannhat
  FROM (
    SELECT period_fromdate, derivative_product, derivative_product_detail, open_interest_volume, 0 klgd, 0 ndtnn_mua_kl, 0 ndtnn_ban_kl, 0 ndtnn_rong_kl, CAST(NULL AS STRING) hdtl_gannhat_symbol, CAST(NULL AS DOUBLE) gia_hdtl_gannhat
    FROM oi_period 
    UNION ALL 
    SELECT period_fromdate, derivative_product, derivative_product_detail, 0 open_interest_volume, klgd, ndtnn_mua_kl, ndtnn_ban_kl, ndtnn_rong_kl, CAST(NULL AS STRING) hdtl_gannhat_symbol, CAST(NULL AS DOUBLE) gia_hdtl_gannhat
    FROM trade_period 
    UNION ALL 
    SELECT period_fromdate, derivative_product, derivative_product_detail, 0 open_interest_volume, 0 klgd, 0 ndtnn_mua_kl, 0 ndtnn_ban_kl, 0 ndtnn_rong_kl, hdtl_gannhat_symbol, gia_hdtl_gannhat
    FROM fut_price_period 
  ) t
  CROSS JOIN params p 
  GROUP BY p.period_type, t.period_fromdate, t.derivative_product, t.derivative_product_detail
)
-- Dữ liệu trên dashboard
SELECT 
  p.derivative_product,
  -- Chi tiết sản phẩm: chọn 1 sản phẩm -> tách theo detail (HĐTL TPCP -> GB05, GB10); 'Toàn thị trường' -> gộp 1 dòng
  CASE WHEN p.derivative_product = 'Toàn thị trường' THEN 'Toàn thị trường' ELSE d.derivative_product_detail END AS derivative_product_detail,
  d.period_type, 
  d.period_code, 
  d.period_fromdate, 
  SUM(d.khoiluongmo) AS khoiluongmo,
  SUM(d.klgd) AS klgd,
  SUM(d.ndtnn_mua_kl) AS klgd_ndtnn_mua, 
  SUM(d.ndtnn_ban_kl) AS klgd_ndtnn_ban, 
  SUM(d.ndtnn_rong_kl) AS klgd_ndtnn_rong,
  -- Giá HĐTL kỳ hạn gần nhất: chỉ hiển thị khi chọn 1 sản phẩm (không cộng giá giữa các sản phẩm khi chọn 'Toàn thị trường')
  CASE WHEN p.derivative_product <> 'Toàn thị trường' THEN MAX(d.hdtl_gannhat_symbol) END AS hdtl_gannhat_symbol,
  CASE WHEN p.derivative_product <> 'Toàn thị trường' THEN MAX(d.gia_hdtl_gannhat) END AS gia_hdtl_gannhat
FROM oi_trade_period d
CROSS JOIN params p
WHERE d.derivative_product = p.derivative_product OR p.derivative_product = 'Toàn thị trường'
GROUP BY p.derivative_product, CASE WHEN p.derivative_product = 'Toàn thị trường' THEN 'Toàn thị trường' ELSE d.derivative_product_detail END, d.period_type, d.period_code, d.period_fromdate
ORDER BY 6, 2 -- period_fromdate, derivative_product_detail
;