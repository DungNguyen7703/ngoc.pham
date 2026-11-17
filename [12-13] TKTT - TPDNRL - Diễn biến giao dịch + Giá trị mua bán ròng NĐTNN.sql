-- THỐNG KÊ THỊ TRƯỜNG >> TPDN RIÊNG LẺ 
-->> BIỂU ĐỒ DIỄN BIẾN GIAO DỊCH THỊ TRƯỜNG TPDN RIÊNG LẺ; GIÁ TRỊ MUA/BÁN RÒNG NĐTNN TRÊN THỊ TRƯỜNG TPDN RIÊNG LẺ
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
-- GTGD TPDN riêng lẻ
----- Báo cáo nguồn đầu vào trong khoảng [Từ kỳ - Đến kỳ]
, report_data AS (
  SELECT 
    --r.origin_date_value, r.report_year, r.report_quarter, r.report_month, r.report_day, 
    p.period_type,
    CASE p.period_type
      WHEN 'D' THEN FORMAT_STRING('%04d-%02d-%02d', r.report_year, r.report_month, r.report_day)
      WHEN 'M' THEN FORMAT_STRING('%04d-%02d', r.report_year, r.report_month)
      WHEN 'Q' THEN FORMAT_STRING('%04d-Q%d', r.report_year, r.report_quarter)
      WHEN 'Y' THEN CAST(r.report_year AS STRING)
    END AS period_code,
    MAKE_DATE(r.report_year, r.report_month, r.report_day) report_date,
    r.column_path, 
    r.row_path,
    CASE WHEN r.data_type IN ('CURRENCY', 'PERCENTAGE', 'NUMBER') THEN TRY_CAST(r.field_value AS DECIMAL(38,15)) END value
  FROM uat_iss_ods.flat_report r 
  CROSS JOIN params p 
  WHERE r.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
    AND r.report_code = 'HNX09' AND r.sheet_name = 'sheet 1'
    AND r.column_path = 'GIÁ TRỊ'
    AND r.row_path IN (
        'GIÁ TRỊ GIAO DỊCH', 
        'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA', 
        'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN'
    )
    AND r.date_type = 'DAILY'
    AND MAKE_DATE(r.report_year, r.report_month, r.report_day) BETWEEN p.period_from_startdate AND p.period_to_enddate
    AND r.submit_source = 'ICP' -- Chỉ lấy nguồn từ Sở, không lấy CDW (CSDLTT), KDL (Kho dữ liệu)
    AND r.ds_snpst_dt = '2026-09-04'
)
----- Tổng theo kỳ
SELECT 
  d.loaiky, 
  d.ky,
  d.gtgd,
  d.gtgd_ndtnn_mua,
  d.gtgd_ndtnn_ban,
  COALESCE(d.gtgd_ndtnn_mua, 0) - COALESCE(d.gtgd_ndtnn_ban, 0) AS gtgd_ndtnn_rong
FROM ( 
  SELECT 
  period_type AS loaiky,
    period_code AS ky,
    SUM(CASE WHEN row_path = 'GIÁ TRỊ GIAO DỊCH' THEN value END) gtgd,
    SUM(CASE WHEN row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA' THEN value END) gtgd_ndtnn_mua,
    SUM(CASE WHEN row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN' THEN value END) gtgd_ndtnn_ban
  FROM report_data 
  GROUP BY loaiky, ky
) d
ORDER BY ky
;