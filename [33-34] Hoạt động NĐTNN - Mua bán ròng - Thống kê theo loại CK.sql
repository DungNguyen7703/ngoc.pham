-- HOẠT ĐỘNG NĐTNN >> MUA/BÁN RÒNG >> THỐNG KÊ THEO LOẠI CHỨNG KHOÁN: TÍNH TẠI 1 KỲ
/* Tham số tra cứu:
 * :period_type  Loại kỳ: D/M/Q/Y
 * :period_to    Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * Nhận diện Giao dịch của NĐTNN: Ký tự thứ 4 trong số tài khoản giao dịch IN ('E','F')
 */
-- ======================================================================================
-- CHI TIẾT GIAO DỊCH NĐTNN THEO LOẠI CHỨNG KHOÁN
--   * Mỗi chỉ tiêu (GT mua, GT bán, GT mua/bán ròng) có % thay đổi so với KỲ TRƯỚC
--   * Nhóm hiển thị: Thị trường cơ sở (CP, CCQ, CW) | Phái sinh | Trái phiếu (TPCP, TPDNNY, TPDNRL)
--   * Phái sinh: GT danh nghĩa = KL x Giá x Hệ số nhân hợp đồng (contractmultiplier)
-- ======================================================================================
WITH
-- 1. Tham số tra cứu: Loại kỳ (D/M/Q/Y) + Kỳ báo cáo -> ngày đầu/cuối kỳ này, kỳ trước
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
    END AS period_to_enddate, -- Ngày cuối kỳ này
    CASE period_type
      WHEN 'D' THEN DATE_SUB(period_to_startdate, 1)
      WHEN 'M' THEN ADD_MONTHS(period_to_startdate, -1)
      WHEN 'Q' THEN ADD_MONTHS(period_to_startdate, -3)
      WHEN 'Y' THEN ADD_MONTHS(period_to_startdate, -12)
    END AS period_prev_startdate, -- Ngày đầu kỳ trước
    DATE_SUB(period_to_startdate, 1) AS period_prev_enddate, -- Ngày cuối kỳ trước
    CASE period_type
      WHEN 'D' THEN date_format(DATE_SUB(period_to_startdate, 1), 'yyyy-MM-dd')
      WHEN 'M' THEN date_format(ADD_MONTHS(period_to_startdate, -1), 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(CAST(year(ADD_MONTHS(period_to_startdate, -3)) AS STRING), '-Q', CAST(CAST(FLOOR((month(ADD_MONTHS(period_to_startdate, -3)) - 1) / 3) + 1 AS INT) AS STRING))
      WHEN 'Y' THEN CAST(year(ADD_MONTHS(period_to_startdate, -12)) AS STRING)
    END AS period_prev_code -- Mã kỳ trước
  FROM (
    SELECT
      :period_type AS period_type, -- Loại kỳ: D/M/Q/Y
      :period_to AS period_code, -- Kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
      CAST(CASE :period_type
        WHEN 'D' THEN :period_to
        WHEN 'M' THEN CONCAT(:period_to, '-01')
        WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
        WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
      END AS DATE) AS period_to_startdate -- Ngày đầu kỳ này
  )
)
-- 2. Danh sách mã chứng khoán: lấy bản ghi cuối ngày trong jad_stockinfor -> phân loại theo floorcode, stocktype
, stock_daily_eod AS (
  SELECT tradingdate, symbol, symbolisin, contractmultiplier,
    CASE
      WHEN stocktype = '1' THEN 'TPDNNY' -- TPDN niêm yết
      WHEN stocktype = '2' THEN 'CP' -- Cổ phiếu
      WHEN stocktype IN ('3', '6') THEN 'CCQ' -- Chứng chỉ quỹ (gồm ETF)
      WHEN floorcode = '10' AND stocktype = '4' THEN 'CW' -- Chứng quyền
      WHEN floorcode = '03' AND stocktype IN ('4', '5') THEN 'PS' -- Phái sinh: HĐTL (4), HĐ quyền chọn (5)
    END AS loai_ck
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.symbolisin, s.floorcode, s.stocktype,
      CAST(s.contractmultiplier AS DOUBLE) AS contractmultiplier, -- Hệ số nhân HĐ phái sinh
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN params p
    WHERE s.tradingdate BETWEEN p.period_prev_startdate AND p.period_to_enddate
  )
  WHERE rn = 1 -- Bản ghi cuối mỗi ngày
)
-- 3. GT NĐTNN mua/bán theo ngày x loại chứng khoán -> Tính từ ngày đầu kỳ trước đến ngày cuối kỳ này
---- NĐTNN: ký tự thứ 4 của số tài khoản IN ('E','F')
, trade_daily AS (
  -- 3.1. HOSE: Cổ phiếu, CCQ, Chứng quyền
  SELECT
    h.trade_date AS trade_date,
    s.loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS gtgd_ndtnn_ban
  FROM uat_hose_stg.trade_book h
  JOIN stock_daily_eod s ON h.symbol = s.symbol AND h.trade_date = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id = 'STK'
    AND h.trade_date BETWEEN p.period_prev_startdate AND p.period_to_enddate
  GROUP BY h.trade_date, s.loai_ck
  UNION ALL
  -- 3.2. HNX + UPCoM: TPDNNY, Cổ phiếu, CCQ (CCQ hiện không còn giao dịch nên số null), Phái sinh
  ---- trade_date kiểu string yyyyMMdd; join với jad_stockinfor theo mã ISIN
  ---- Phái sinh (HNX - DVX): GT = KL x Giá x Hệ số nhân hợp đồng (contractmultiplier trong jad_stockinfor)
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    s.loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F')
      THEN h.trade_quantity * h.trade_price * (CASE WHEN h.market_id = 'DVX' THEN s.contractmultiplier ELSE 1 END)
    END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F')
      THEN h.trade_quantity * h.trade_price * (CASE WHEN h.market_id = 'DVX' THEN s.contractmultiplier ELSE 1 END)
    END) AS gtgd_ndtnn_ban
  FROM uat_hnx_stg.trade_book h
  JOIN stock_daily_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id IN ('STX', 'UPX', 'HCX', 'DVX')
    AND h.trade_date BETWEEN DATE_FORMAT(p.period_prev_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
  GROUP BY h.trade_date, s.loai_ck
  UNION ALL
  -- 3.3. TPCP: Sổ lệnh outright/repo đã thực hiện (ĐTH)
  SELECT
    trade_date,
    loai_ck,
    SUM(gtgd_ndtnn_mua) AS gtgd_ndtnn_mua,
    SUM(gtgd_ndtnn_ban) AS gtgd_ndtnn_ban
  FROM (
    SELECT
      o.trading_date AS trade_date,
      'TPCP' AS loai_ck,
      SUM(CASE WHEN SUBSTR(o.buying_account_no, 4, 1) IN ('E', 'F') THEN o.trading_value ELSE 0 END) AS gtgd_ndtnn_mua,
      SUM(CASE WHEN SUBSTR(o.selling_account_no, 4, 1) IN ('E', 'F') THEN o.trading_value ELSE 0 END) AS gtgd_ndtnn_ban
    FROM uat_hnx_stg.outright_order_book o
    CROSS JOIN params p
    WHERE o.order_status = 'ĐTH'
      AND o.trading_date BETWEEN p.period_prev_startdate AND p.period_to_enddate
    GROUP BY o.trading_date
    UNION ALL
    SELECT
      r.trading_date AS trade_date,
      'TPCP' AS loai_ck,
      SUM(CASE WHEN SUBSTR(r.buying_account_no, 4, 1) IN ('E', 'F') THEN r.first_settlement_value ELSE 0 END) AS gtgd_ndtnn_mua,
      SUM(CASE WHEN SUBSTR(r.selling_account_no, 4, 1) IN ('E', 'F') THEN r.first_settlement_value ELSE 0 END) AS gtgd_ndtnn_ban
    FROM uat_hnx_stg.repo_order_book r
    CROSS JOIN params p
    WHERE r.order_status = 'ĐTH'
      AND r.trading_date BETWEEN p.period_prev_startdate AND p.period_to_enddate
    GROUP BY r.trading_date
  )
  GROUP BY trade_date, loai_ck
  UNION ALL
  -- 3.4. TPDN riêng lẻ: Báo cáo HNX09 (chỉ lấy nguồn từ Sở - ICP; không lấy CDW/KDL)
  SELECT
    r.report_date AS trade_date,
    'TPDNRL' AS loai_ck,
    SUM(CASE WHEN r.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA' THEN r.value ELSE 0 END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN r.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN' THEN r.value ELSE 0 END) AS gtgd_ndtnn_ban
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
      AND MAKE_DATE(f.report_year, f.report_month, f.report_day) BETWEEN p.period_prev_startdate AND p.period_to_enddate
      AND f.ds_snpst_dt = '2026-10-22' -- Snapshot date
  ) r
  GROUP BY r.report_date
)
-- 4. Danh mục loại chứng khoán hiển thị (đảm bảo luôn đủ dòng kể cả khi không có giao dịch)
, loai_dm AS (
  SELECT * FROM VALUES
    (1, 'Thị trường cơ sở',    1, 'CP',     'Cổ phiếu'),
    (1, 'Thị trường cơ sở',    2, 'CCQ',    'Chứng chỉ quỹ'),
    (1, 'Thị trường cơ sở',    3, 'CW',     'Chứng quyền'),
    (2, 'Trái phiếu',          1, 'TPCP',   'TPCP'),
    (2, 'Trái phiếu',          2, 'TPDNNY', 'TPDN niêm yết'),
    (2, 'Trái phiếu',          3, 'TPDNRL', 'TPDN riêng lẻ'),
    (3, 'Giao dịch Phái sinh', 1, 'PS',     'Phái sinh')
  AS t(nhom_stt, nhom, loai_stt, loai_ck, loai)
)
-- 5. Tổng hợp GT mua/bán theo loại chứng khoán: kỳ này, kỳ trước
, trade_period AS (
  SELECT
    d.loai_ck,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate THEN d.gtgd_ndtnn_mua ELSE 0 END) AS gtgd_ndtnn_mua_kynay,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate THEN d.gtgd_ndtnn_ban ELSE 0 END) AS gtgd_ndtnn_ban_kynay,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_prev_startdate AND p.period_prev_enddate THEN d.gtgd_ndtnn_mua ELSE 0 END) AS gtgd_ndtnn_mua_kytruoc,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_prev_startdate AND p.period_prev_enddate THEN d.gtgd_ndtnn_ban ELSE 0 END) AS gtgd_ndtnn_ban_kytruoc
  FROM trade_daily d
  CROSS JOIN params p
  GROUP BY d.loai_ck
)
-- 6. Dữ liệu lên dashboard
SELECT
  p.period_type AS loaiky,
  p.period_code AS ky,
  p.period_prev_code AS ky_truoc,
  x.nhom,
  x.loai_ck,
  x.loai,
  -- GT mua
  x.gtgd_ndtnn_mua,
  x.gtgd_ndtnn_mua_kytruoc,
  (x.gtgd_ndtnn_mua - x.gtgd_ndtnn_mua_kytruoc) / NULLIF(ABS(x.gtgd_ndtnn_mua_kytruoc), 0) * 100 AS gtgd_ndtnn_mua_thay_doi_pt,
  -- GT bán
  x.gtgd_ndtnn_ban,
  x.gtgd_ndtnn_ban_kytruoc,
  (x.gtgd_ndtnn_ban - x.gtgd_ndtnn_ban_kytruoc) / NULLIF(ABS(x.gtgd_ndtnn_ban_kytruoc), 0) * 100 AS gtgd_ndtnn_ban_thay_doi_pt,
  -- GT mua/bán ròng
  x.gtgd_ndtnn_mua - x.gtgd_ndtnn_ban AS rong_gt,
  x.gtgd_ndtnn_mua_kytruoc - x.gtgd_ndtnn_ban_kytruoc AS gtgd_ndtnn_rong_kytruoc,
  ((x.gtgd_ndtnn_mua - x.gtgd_ndtnn_ban) - (x.gtgd_ndtnn_mua_kytruoc - x.gtgd_ndtnn_ban_kytruoc)) / NULLIF(ABS(x.gtgd_ndtnn_mua_kytruoc - x.gtgd_ndtnn_ban_kytruoc), 0) * 100 AS gtgd_ndtnn_rong_thay_doi_pt
FROM params p
CROSS JOIN (
  SELECT
    m.nhom_stt, m.loai_stt, m.nhom, m.loai_ck, m.loai,
    COALESCE(lp.gtgd_ndtnn_mua_kynay, 0) AS gtgd_ndtnn_mua,
    COALESCE(lp.gtgd_ndtnn_mua_kytruoc, 0) AS gtgd_ndtnn_mua_kytruoc,
    COALESCE(lp.gtgd_ndtnn_ban_kynay, 0) AS gtgd_ndtnn_ban,
    COALESCE(lp.gtgd_ndtnn_ban_kytruoc, 0) AS gtgd_ndtnn_ban_kytruoc
  FROM loai_dm m
  LEFT JOIN trade_period lp ON lp.loai_ck = m.loai_ck
) x
ORDER BY x.nhom_stt, x.loai_stt
;