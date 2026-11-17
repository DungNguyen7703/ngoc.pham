-- THỐNG KÊ THỊ TRƯỜNG >> TPDN RIÊNG LẺ >> CHỈ TIÊU TỔNG HỢP
/* Tham số tra cứu:
 * Loại kỳ: D/M/Q/Y
 * Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH
-- Từ tham số loại kỳ, kỳ báo cáo lấy ra Ngày đầu kỳ trước và ngày cuối kỳ này
params_period_bounds AS (
  SELECT
    *,
    CASE period_type
      WHEN 'D' THEN DATE_SUB(period_to_startdate, 1)
      WHEN 'M' THEN ADD_MONTHS(period_to_startdate, -1)
      WHEN 'Q' THEN ADD_MONTHS(period_to_startdate, -3)
      WHEN 'Y' THEN ADD_MONTHS(period_to_startdate, -12)
    END AS period_prev_startdate, -- Ngày đầu kỳ trước
    CASE period_type
      WHEN 'D' THEN period_to_startdate
      WHEN 'M' THEN LAST_DAY(period_to_startdate)
      WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 3), 1)
      WHEN 'Y' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 12), 1)
    END AS period_to_enddate -- Ngày cuối kỳ này
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
-- Lấy ra ngày đầu năm của kỳ trước, ngày đầu năm và ngày cuối cùng của kỳ này
, params_period AS (
  SELECT
    p.*,
    DATE_SUB(period_to_startdate, 1) AS period_prev_end,
    CAST(DATE_TRUNC('YEAR', period_to_startdate) AS DATE) AS period_to_ytd_start,
    CAST(DATE_TRUNC('YEAR', period_prev_startdate) AS DATE) AS period_prev_ytd_start
  FROM params_period_bounds p
)
-- Thời gian Kỳ này, kỳ trước
, periods AS (
  SELECT 'CURRENT' AS period_key, period_to_startdate AS period_startdate, period_to_enddate AS period_enddate, period_to_ytd_start AS ytd_startdate
  FROM params_period
  UNION ALL
  SELECT 'PREVIOUS' AS period_key, period_prev_startdate AS period_startdate, period_prev_end AS period_enddate, period_prev_ytd_start AS ytd_startdate
  FROM params_period
)
-- Lọc dữ liệu báo cáo đầu vào theo điều kiện thời gian tính từ ngày đầu năm của kỳ trước đến ngày cuối của kỳ này
, report_data AS (
  SELECT
    MAKE_DATE(f.report_year, f.report_month, f.report_day) report_date,
    f.row_path,
    CASE WHEN f.data_type IN ('CURRENCY', 'PERCENTAGE', 'NUMBER') THEN TRY_CAST(f.field_value AS DECIMAL(38,15)) END AS value
  FROM uat_iss_ods.flat_report r
  CROSS JOIN params_period p
  WHERE f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
    AND f.submit_source = 'ICP' -- Báo cáo này chỉ lấy nguồn từ Sở, không lấy CDW (CSDLTT), KDL (Kho dữ liệu)
    AND f.report_code = 'HNX09'
    AND f.sheet_name = 'sheet 1'
    AND f.column_path = 'GIÁ TRỊ'
    AND f.row_path IN (
        'GIÁ TRỊ GIAO DỊCH',
        'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA',
        'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN'
    )
    AND f.date_type = 'DAILY'
    AND MAKE_DATE(f.report_year, f.report_month, f.report_day) BETWEEN p.period_prev_ytd_start AND p.period_to_enddate
    AND f.ds_snpst_dt = '2026-10-22' 
)
-- Tính tổng giao dịch theo ngày
, daily_trade_data AS (
  SELECT
    report_date,
    SUM(CASE WHEN row_path = 'GIÁ TRỊ GIAO DỊCH' THEN value END) AS gtgd,
    SUM(CASE WHEN row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA' THEN value END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN' THEN value END) AS gtgd_ndtnn_ban
  FROM report_data
  GROUP BY report_date
)
-- Đếm số ngày giao dịch trong năm của kỳ trước và kỳ này (Chỉ tính đến ngày cuối cùng kỳ này) -> Dùng sổ lệnh hnx do đủ ngày, không dùng ngày báo cáo HNX09 do không đủ ngày
, period_tradedate AS (
  SELECT 
    p.period_key, COUNT(h.trade_date) count_tradedate
  FROM (
    SELECT DISTINCT TO_DATE(trade_date,'yyyyMMdd') AS trade_date
    FROM uat_hnx_stg.trade_book
  ) h 
  JOIN periods p ON h.trade_date BETWEEN p.ytd_startdate AND p.period_enddate
  GROUP BY p.period_key
)
-- Chỉ tiêu giao dịch trên dashboard
, period_metrics AS (
  SELECT 
    m.period_key,
    m.gtgd,
    m.gtgd_ytd,
    m.gtgd_ytd / NULLIF(pt.count_tradedate, 0) AS gtgd_bq_ytd,
    m.gtgd_ndtnn_mua,
    m.gtgd_ndtnn_ban,
    COALESCE(gtgd_ndtnn_mua, 0) - COALESCE(gtgd_ndtnn_ban, 0) AS gtgd_ndtnn_rong
  FROM (
    SELECT
      c.period_key,
      SUM(CASE WHEN d.report_date BETWEEN c.period_startdate AND c.period_enddate THEN d.gtgd END) AS gtgd,
      SUM(d.gtgd) AS gtgd_ytd,
      -- AVG trên dữ liệu đã gom theo ngày = tổng GTGD / số ngày có GTGD khác NULL --> Không dùng công thức này do báo cáo không đủ report_date
      -- AVG(d.gtgd) AS gtgd_bq_ytd,
      SUM(CASE WHEN d.report_date BETWEEN c.period_startdate AND c.period_enddate THEN d.gtgd_ndtnn_mua END) AS gtgd_ndtnn_mua,
      SUM(CASE WHEN d.report_date BETWEEN c.period_startdate AND c.period_enddate THEN d.gtgd_ndtnn_ban END) AS gtgd_ndtnn_ban
    FROM periods c
    LEFT JOIN daily_trade_data d ON d.report_date BETWEEN c.ytd_startdate AND c.period_enddate
    GROUP BY c.period_key
  ) m
  LEFT JOIN period_tradedate pt ON m.period_key = pt.period_key
)
-- Số mã TPDN riêng lẻ đăng ký giao dịch (ĐKGD): tính tại ngày cuối kỳ báo cáo, gồm số kỳ này và kỳ trước
----- Nguồn: uat_hnx_stg.private_corp_bond_registration; report_month, report_year chuẩn hoá về chuỗi yyyyMM (dùng được cho date / yyyy-MM / yyyyMM / int)
, registration_src AS (
  SELECT
    bond_code,
    maturity_date,
    CONCAT(report_year, report_month) AS report_ym
  FROM uat_hnx_stg.private_corp_bond_registration
)
-- Xác định lấy dữ liệu Tháng báo cáo (yyyyMM) nào theo loại kỳ tra cứu, áp dụng cho cả kỳ này và kỳ trước:
----- Tháng      : tháng báo cáo = chính tháng đó
----- Quý / Năm  : tháng báo cáo mới nhất có dữ liệu trong quý/năm (quý/năm đang diễn ra chưa đủ tháng -> lấy tháng gần nhất đã có)
----- Ngày       : ngày cuối tháng -> tháng của ngày đó; ngày < cuối tháng -> tháng liền trước (báo cáo tháng chưa hoàn chỉnh)
, registration_latest AS (
  SELECT
    c.period_key,
    c.period_enddate,
    CASE WHEN p.period_type = 'D'
      THEN DATE_FORMAT(CASE WHEN c.period_enddate = LAST_DAY(c.period_enddate) THEN c.period_enddate ELSE ADD_MONTHS(c.period_enddate, -1) END, 'yyyyMM')
      ELSE MAX(r.report_ym)
    END AS report_ym
  FROM periods c
  CROSS JOIN params_period p
  LEFT JOIN registration_src r
    ON r.report_ym BETWEEN DATE_FORMAT(c.period_startdate, 'yyyyMM') AND DATE_FORMAT(c.period_enddate, 'yyyyMM')
  GROUP BY c.period_key, c.period_enddate, p.period_type
)
----- Số mã ĐKGD = COUNT(bond_code) của tháng báo cáo gần nhất, chỉ lấy trái phiếu chưa đáo hạn tại ngày cuối kỳ
, registration_metrics AS (
  SELECT l.period_key, COUNT(DISTINCT r.bond_code) AS so_ma_dkgd
  FROM registration_latest l
  JOIN registration_src r
    ON r.report_ym = l.report_ym
   AND r.maturity_date > l.period_enddate -- Chỉ tính TP chưa đáo hạn
  GROUP BY l.period_key
)
SELECT
  p.period_type AS loaiky,
  p.period_code AS ky,
  c.gtgd,
  (c.gtgd - b.gtgd) AS gtgd_pct_thaydoi,
  (c.gtgd - b.gtgd) / NULLIF(b.gtgd, 0) * 100 AS gtgd_pct_thaydoi_pt,
  c.gtgd_bq_ytd,
  (c.gtgd_bq_ytd - b.gtgd_bq_ytd) AS gtgd_bq_ytd_thaydoi,
  (c.gtgd_bq_ytd - b.gtgd_bq_ytd) / NULLIF(b.gtgd_bq_ytd, 0) * 100 AS gtgd_bq_ytd_thaydoi_pt,
  c.gtgd_ndtnn_mua,
  (NVL(c.gtgd_ndtnn_mua,0) - NVL(b.gtgd_ndtnn_mua,0)) AS gtgd_ndtnn_mua_thaydoi,
  (NVL(c.gtgd_ndtnn_mua,0) - NVL(b.gtgd_ndtnn_mua,0)) / NULLIF(b.gtgd_ndtnn_mua, 0) * 100 AS gtgd_ndtnn_mua_thaydoi_pt,
  c.gtgd_ndtnn_ban,
  (NVL(c.gtgd_ndtnn_ban,0) - NVL(b.gtgd_ndtnn_ban,0)) AS gtgd_ndtnn_ban_thaydoi,
  (NVL(c.gtgd_ndtnn_ban,0) - NVL(b.gtgd_ndtnn_ban,0)) / NULLIF(b.gtgd_ndtnn_ban, 0) * 100 AS gtgd_ndtnn_ban_thaydoi_pt,
  c.gtgd_ndtnn_rong,
  (NVL(c.gtgd_ndtnn_rong,0) - NVL(b.gtgd_ndtnn_rong,0)) AS gtgd_ndtnn_rong_thaydoi,
  (NVL(c.gtgd_ndtnn_rong,0) - NVL(b.gtgd_ndtnn_rong,0)) / NULLIF(ABS(b.gtgd_ndtnn_rong), 0) * 100 AS gtgd_ndtnn_rong_thaydoi_pt,
  rc.so_ma_dkgd,
  (rc.so_ma_dkgd - rb.so_ma_dkgd) AS so_ma_dkgd_thaydoi,
  (rc.so_ma_dkgd - rb.so_ma_dkgd) / NULLIF(ABS(rb.so_ma_dkgd), 0) * 100 AS so_ma_dkgd_thaydoi_pt
FROM params_period p
CROSS JOIN period_metrics c
CROSS JOIN period_metrics b
LEFT JOIN registration_metrics rc ON rc.period_key = 'CURRENT'
LEFT JOIN registration_metrics rb ON rb.period_key = 'PREVIOUS'
WHERE c.period_key = 'CURRENT'
  AND b.period_key = 'PREVIOUS'
;