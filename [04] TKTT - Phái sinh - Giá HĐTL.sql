-- THỐNG KÊ THỊ TRƯỜNG >> PHÁI SINH >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ
/* Tham số tra cứu: 
 * Sản phẩm phái sinh: HĐTL VN30, HĐTL VN100, HĐTL TPCP (5 năm, 10 năm), Toàn thị trường
 * Loại kỳ: D/M/Q/Y
 * Kỳ: Ngày yyyy-MM-dd, Tháng yyyy-MM, Quý yyyy-Q[1-4], Năm yyyy
 */
WITH 
-- Tham số báo cáo
params_period AS (
  SELECT
    p.*,
    CASE :periodtype
      WHEN 'D' THEN period_to_startdate
      WHEN 'M' THEN last_day(period_to_startdate)
      WHEN 'Q' THEN date_sub(add_months(period_to_startdate, 3), 1)
      WHEN 'Y' THEN date_sub(add_months(period_to_startdate, 12), 1)
    END AS period_to_todate
  FROM (
    SELECT
      :derivative_product AS derivative_product, -- Sản phẩm phái sinh
      :period_type AS period_type, -- Loại kỳ
      :period_to AS period_to, -- Kỳ
      CASE :periodtype
        WHEN 'D' THEN to_date(:period_to)
        WHEN 'M' THEN to_date(concat(:period_to, '-01'))
        WHEN 'Q' THEN add_months(to_date(concat(substr(:period_to, 1, 4), '-01-01')), (cast(substr(:period_to, 7, 1) AS int) - 1) * 3)
        WHEN 'Y' THEN to_date(concat(:period_to, '-01-01'))
      END AS period_to_startdate
  ) p
)
-- Lấy ngày cuối cùng có dữ liệu trong kỳ báo cáo
, sotkcinfor_eop AS (
  SELECT
    max(s.tradingdate) AS tradingdate
  FROM uat_mdds_stg.jad_stockinfor s
  CROSS JOIN params_period p
  WHERE s.floorcode = '03'
    AND s.tradingdate >= p.period_to_startdate
    AND s.tradingdate <= p.period_to_todate
)
-- Thông tin giá đóng cửa của sản phẩm phái sinh tại ngày cuối cùng có dữ liệu trong kỳ
SELECT 
  i.tradingdate,
  i.derivative_product,
  i.derivative_product_detail,
  i.maturitymonthyear,
  i.closeprice
FROM (
  SELECT 
    s.tradingdate,
    s.tradingtime, 
    s.`sequence`, 
    IF(s.floorcode = '03', CONCAT(MAP('4','HĐTL','5','HĐ quyền chọn')[stocktype], ' ', IF(productgrpid = 'FBX', 'TPCP', s.underlyingsymbol)), '') AS derivative_product,
    IF(s.floorcode = '03', CONCAT(MAP('4','HĐTL','5','HĐ quyền chọn')[stocktype], IF(productgrpid = 'FBX', ' TPCP', ''), ' ', s.underlyingsymbol), '') AS derivative_product_detail,
    s.stocktype, 
    s.underlyingsymbol,
    s.symbol,
    s.maturitymonthyear,
    s.closeprice,
    row_number() OVER (PARTITION BY s.derivative_product, s.maturitymonthyear ORDER BY s.tradingdate DESC, s.tradingtime DESC, s.`sequence` DESC) AS rn -- Lấy dữ liệu cuối ngày
  FROM uat_mdds_stg.jad_stockinfor s
  JOIN eop p ON p.tradingdate = s.tradingdate -- Ngày cuối cùng có dữ liệu trong kỳ
  WHERE s.floorcode = '03'
) i WHERE i.rn = 1
;