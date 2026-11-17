-- HOẠT ĐỘNG NĐTNN >> MUA BÁN RÒNG >> GTGD TRÁI PHIẾU THEO THỜI GIAN (TỪ KỲ - ĐẾN KỲ)
/* Tham số tra cứu:
 * :period_type  Loại kỳ: D/M/Q/Y
 * :period_from  Từ kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * :period_to    Đến kỳ: định dạng như :period_from
 * Nhận diện Giao dịch của NĐTNN: Ký tự thứ 4 trong số tài khoản giao dịch IN ('E','F')
 * Kết quả: GT NĐTNN mua, bán, ròng theo từng kỳ cho TPCP, TPDN niêm yết, TPDN riêng lẻ và Tổng 3 loại trái phiếu
 */
WITH
-- 1. Tham số tra cứu: Loại kỳ, Từ kỳ, Đến kỳ >> Lấy ra [ngày bắt đầu - ngày kết thúc]
params AS (
  SELECT
    period_type,
    -- Ngày đầu của "Từ kỳ"
    CAST(CASE period_type
      WHEN 'D' THEN period_from
      WHEN 'M' THEN CONCAT(period_from, '-01')
      WHEN 'Q' THEN CONCAT(SUBSTR(period_from, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(period_from, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
      WHEN 'Y' THEN CONCAT(period_from, '-01-01')
    END AS DATE) AS period_from_startdate,
    -- Ngày cuối của "Đến kỳ"
    CAST(CASE period_type
      WHEN 'D' THEN period_to
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(period_to, '-01'), 'yyyy-MM-dd'))
      WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(period_to, 1, 4), '-01-01'), 'yyyy-MM-dd'), CAST(SUBSTR(period_to, 7, 1) AS INT) * 3), 1)
      WHEN 'Y' THEN CONCAT(period_to, '-12-31')
    END AS DATE) AS period_to_enddate
  FROM (
    SELECT -- Danh sách tham số tra cứu
      :period_type AS period_type, -- Loại kỳ
      :period_from AS period_from, -- Từ kỳ
      :period_to   AS period_to    -- Đến kỳ
  )
)
-- 2. Danh sách TPDN niêm yết: lấy bản ghi cuối ngày trong jad_stockinfor, stocktype = '1'
, stock_daily_eod AS (
  SELECT tradingdate, symbol, symbolisin
  FROM (
    SELECT
      s.tradingdate,
      s.symbol,
      s.symbolisin,
      s.stocktype,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN params p
    WHERE s.tradingdate BETWEEN p.period_from_startdate AND p.period_to_enddate
    AND stocktype = '1' -- TPDN niêm yết
  )
  WHERE rn = 1 -- Bản ghi cuối mỗi ngày
)
-- 3. GT NĐTNN mua/bán theo ngày x loại trái phiếu - Dữ liệu từ ngày đầu của "Từ kỳ" đến ngày cuối của "Đến kỳ"
, trade_daily AS (
  -- 3.1. TPDN niêm yết (HNX - HCX): join với jad_stockinfor theo mã ISIN
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    'TPDNNY' AS loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ndtnn_mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ndtnn_ban_gt
  FROM uat_hnx_stg.trade_book h
  JOIN stock_daily_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id = 'HCX'
    AND h.trade_date BETWEEN DATE_FORMAT(p.period_from_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') -- Lọc trade_date kiểu string dạng yyyyMMdd
  GROUP BY h.trade_date
  UNION ALL
  -- 3.2. TPCP: Sổ lệnh outright/repo đã thực hiện (ĐTH)
  SELECT
    trade_date,
    'TPCP' AS loai_ck,
    SUM(ndtnn_mua_gt) AS ndtnn_mua_gt,
    SUM(ndtnn_ban_gt) AS ndtnn_ban_gt
  FROM (
    SELECT
      o.trading_date AS trade_date,
      SUM(CASE WHEN SUBSTR(o.buying_account_no, 4, 1) IN ('E', 'F') THEN o.trading_value ELSE 0 END) AS ndtnn_mua_gt,
      SUM(CASE WHEN SUBSTR(o.selling_account_no, 4, 1) IN ('E', 'F') THEN o.trading_value ELSE 0 END) AS ndtnn_ban_gt
    FROM uat_hnx_stg.outright_order_book o
    CROSS JOIN params p
    WHERE o.order_status = 'ĐTH'
      AND o.trading_date BETWEEN p.period_from_startdate AND p.period_to_enddate
    GROUP BY o.trading_date
    UNION ALL
    SELECT
      r.trading_date AS trade_date,
      SUM(CASE WHEN SUBSTR(r.buying_account_no, 4, 1) IN ('E', 'F') THEN r.first_settlement_value ELSE 0 END) AS ndtnn_mua_gt,
      SUM(CASE WHEN SUBSTR(r.selling_account_no, 4, 1) IN ('E', 'F') THEN r.first_settlement_value ELSE 0 END) AS ndtnn_ban_gt
    FROM uat_hnx_stg.repo_order_book r
    CROSS JOIN params p
    WHERE r.order_status = 'ĐTH'
      AND r.trading_date BETWEEN p.period_from_startdate AND p.period_to_enddate
    GROUP BY r.trading_date
  )
  GROUP BY trade_date
  UNION ALL
  -- 3.3. TPDN riêng lẻ: Báo cáo HNX09 (chỉ lấy nguồn từ Sở - ICP; không lấy CDW/KDL)
  SELECT
    tk.report_date AS trade_date,
    'TPDNRL' AS loai_ck,
    SUM(CASE WHEN tk.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA' THEN tk.value ELSE 0 END) AS ndtnn_mua_gt,
    SUM(CASE WHEN tk.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN' THEN tk.value ELSE 0 END) AS ndtnn_ban_gt
  FROM (
    SELECT
      MAKE_DATE(f.report_year, f.report_month, f.report_day) AS report_date,
      f.row_path,
      CASE WHEN f.data_type IN ('CURRENCY', 'PERCENTAGE', 'NUMBER') THEN TRY_CAST(f.field_value AS DECIMAL(38,15)) END AS value
    FROM uat_iss_ods.flat_report f
    CROSS JOIN params p
    WHERE f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
      AND f.submit_source = 'ICP'
      AND f.report_code = 'HNX09'
      AND f.sheet_name = 'sheet 1'
      AND f.column_path = 'GIÁ TRỊ'
      AND f.row_path IN ('GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA', 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN')
      AND f.date_type = 'DAILY'
      AND MAKE_DATE(f.report_year, f.report_month, f.report_day) BETWEEN p.period_from_startdate AND p.period_to_enddate
      AND f.ds_snpst_dt = '2026-10-22' -- Snapshot date
  ) tk
  GROUP BY tk.report_date
)
-- 4. Gộp theo kỳ x loại trái phiếu
, trade_period AS (
  SELECT
    :period_type AS loaiky,
    CASE :period_type
      WHEN 'D' THEN date_format(trade_date, 'yyyy-MM-dd')
      WHEN 'M' THEN date_format(trade_date, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(CAST(year(trade_date) AS STRING), '-Q', CAST(CAST(FLOOR((month(trade_date) - 1) / 3) + 1 AS INT) AS STRING))
      WHEN 'Y' THEN CAST(YEAR(trade_date) AS STRING)
    END AS ky,
    loai_ck,
    SUM(ndtnn_mua_gt) AS ndtnn_mua_gt,
    SUM(ndtnn_ban_gt) AS ndtnn_ban_gt
  FROM trade_daily
  GROUP BY 1, 2, loai_ck
)
-- 5. Dữ liệu lên dashboard: từng loại trái phiếu + Tổng 3 loại
SELECT
  loaiky,
  ky,
  loai_ck,
  loai,
  ndtnn_mua_gt,
  ndtnn_ban_gt,
  ndtnn_mua_gt - ndtnn_ban_gt AS ndtnn_rong_gt
FROM (
  SELECT
    loaiky, ky, loai_ck, 
    MAP('TPCP','TPCP','TPDNNY','TPDN niêm yết','TPDNRL','TPDN riêng lẻ')[loai_ck] AS ten_loai_ck,
    ndtnn_mua_gt, ndtnn_ban_gt
  FROM trade_period
  UNION ALL
  SELECT
    loaiky, ky, 'TONG', 'Tổng' ten_loai_ck,
    SUM(ndtnn_mua_gt), SUM(ndtnn_ban_gt)
  FROM trade_period
  GROUP BY loaiky, ky
)
ORDER BY ky, thu_tu
;
