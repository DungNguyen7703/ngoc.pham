-- [9] THỐNG KÊ THỊ TRƯỜNG >> TPDN NIÊM YẾT >> BIỂU ĐỒ THỐNG KÊ GTGD TPDN NIÊM YẾT VÀ TPDN RIÊNG LẺ
/* Tham số tra cứu:
 * Loại kỳ: D/M/Q/Y
 * Từ kỳ - Đến kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH 
-- Tham số tra cứu: Sàn, Loại kỳ, Từ kỳ, Đến kỳ >> Lấy ra [ngày bắt đầu - ngày kết thúc]
params AS (
    SELECT
      period_type, 
    MAP('D','DAY','M','MONTH','Q','QUARTER','Y','YEAR')[period_type] AS period_unit, -- Đơn vị kỳ
    -- Ngày đầu của "Từ kỳ"
    CAST(CASE :period_type
      WHEN 'D' THEN :period_from
      WHEN 'M' THEN CONCAT(:period_from, '-01')
      WHEN 'Q' THEN CONCAT(SUBSTR(:period_from, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_from, 7, 1) AS int) * 3 - 2 AS string), 2, '0'), '-01')
      WHEN 'Y' THEN CONCAT(:period_from, '-01-01')
    END AS date) AS period_from_startdate,
    --Ngày cuối của "Đến kỳ"
    CAST(CASE :period_type
      WHEN 'D' THEN :period_to
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01'), 'yyyy-MM-dd'))
      WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01'), 'yyyy-MM-dd'), CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3),1)
      WHEN 'Y' THEN CONCAT(:period_to, '-12-31')
    END AS date) AS period_to_enddate
    FROM ( 
    SELECT -- Danh sách tham số tra cứu
      :period_type AS period_type, -- Loại kỳ
      :period_from AS period_from, -- Từ kỳ
      :period_to    AS period_to     -- Đến kỳ
  )
)
-- Tổng GTGD TPDN niêm yết theo kỳ
, listedcorpbond_trade_period AS (
  SELECT 
    CAST(DATE_TRUNC(period_unit, trade_date) AS DATE) AS period_fromdate, -- Ngày đầu mỗi kỳ
    SUM(gtgd) AS gtgd
  FROM (
    -- Tổng GTGD theo ngày - Dữ liệu từ ngày đầu của "Từ kỳ" đến ngày cuối của "Đến kỳ"
    SELECT
      p.period_unit,
        TO_DATE(h.trade_date, 'yyyyMMdd') trade_date,
        SUM(h.trade_quantity * h.trade_price) AS gtgd
    FROM uat_hnx_stg.trade_book h 
    CROSS JOIN params p
    WHERE h.market_id IN ('HCX') -- TPDN niêm yết
      AND h.trade_date BETWEEN DATE_FORMAT(p.period_from_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') -- Lọc trade_date kiểu string dạng yyyyMMdd
    GROUP BY p.period_unit, h.trade_date
  ) GROUP BY CAST(DATE_TRUNC(period_unit, trade_date) AS DATE)
)
, privatecorpbond_trade_period AS (
  SELECT 
    CAST(DATE_TRUNC(period_unit, report_date) AS DATE) AS period_fromdate, -- Ngày đầu mỗi kỳ 
    SUM(gtgd) AS gtgd
  FROM (
    SELECT 
      p.period_unit,
      f.origin_date_value, 
      MAKE_DATE(f.report_year, f.report_month, f.report_day) report_date,
      CASE WHEN f.data_type IN ('CURRENCY', 'PERCENTAGE', 'NUMBER') THEN TRY_CAST(f.field_value AS DECIMAL(38,15)) END gtgd
    FROM uat_iss_ods.flat_report f 
    CROSS JOIN params p 
    WHERE f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
      AND f.report_code = 'HNX09' AND f.sheet_name = 'sheet 1'
      AND f.column_path = 'GIÁ TRỊ' AND f.row_path = 'GIÁ TRỊ GIAO DỊCH'
      AND f.date_type = 'DAILY'
      AND MAKE_DATE(f.report_year, f.report_month, f.report_day) BETWEEN p.period_from_startdate AND p.period_to_enddate
      AND f.submit_source = 'ICP' -- Chỉ lấy nguồn từ Sở, không lấy CDW (CSDLTT), KDL (Kho dữ liệu)
      AND f.ds_snpst_dt = '2026-09-22'
  ) GROUP BY CAST(DATE_TRUNC(period_unit, report_date) AS DATE)
)
-- Tổng hợp dữ liệu biểu đồ
---- Gộp 2 loại trái phiếu
, trade_period AS (
  SELECT 
    :period_type loaiky,
    CASE :period_type
      WHEN 'D' THEN date_format(period_fromdate, 'yyyy-MM-dd')
      WHEN 'M' THEN date_format(period_fromdate, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(CAST(year(period_fromdate) AS string), '-Q', CAST(CAST(FLOOR((month(period_fromdate) - 1) / 3) + 1 AS int) AS string))
        WHEN 'Y' THEN CAST(YEAR(period_fromdate) AS string)
    END ky, 
    loaitraiphieu,
    gtgd
  FROM (
    SELECT 'TPDNNY' loaitraiphieu, period_fromdate, gtgd
    FROM listedcorpbond_trade_period
    UNION ALL
    SELECT 'TPDNRL' loaitraiphieu, period_fromdate, gtgd
    FROM privatecorpbond_trade_period
  )
)
SELECT loaiky, ky, loaitraiphieu, gtgd
FROM trade_period
UNION ALL
SELECT loaiky, ky, 'TPDN' loaitraiphieu, SUM(gtgd) AS gtgd
FROM trade_period
GROUP BY loaiky, ky
ORDER BY ky, loaitraiphieu
;