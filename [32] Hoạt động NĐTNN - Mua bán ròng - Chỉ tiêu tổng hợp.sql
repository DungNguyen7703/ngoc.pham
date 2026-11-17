-- HOẠT ĐỘNG NĐTNN >> MUA/BÁN RÒNG >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ
/* Tham số tra cứu:
 * :period_type  Loại kỳ: D/M/Q/Y
 * :period_to    Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * Nhận diện Giao dịch của NĐTNN: Ký tự thứ 4 trong số tài khoản giao dịch IN ('E','F')
 */
-- ======================================================================================
-- CHỈ TIÊU TỔNG HỢP
--   * GT mua/bán ròng (kỳ), GT NĐTNN mua, GT NĐTNN bán : so sánh với KỲ TRƯỚC
--   * GT mua/bán ròng YTD                              : so sánh với CÙNG KỲ NĂM TRƯỚC (YTD năm trước)
--   Phạm vi tổng: CP + CCQ + CW + TPCP + TPDNNY + TPDNRL.
--   Phái sinh (GT danh nghĩa) KHÔNG cộng vào tổng giá trị mua, bán, ròng
-- ======================================================================================
WITH
-- 1. Tham số tra cứu: Loại kỳ (D/M/Q/Y) + Kỳ báo cáo -> ngày đầu/cuối kỳ này, kỳ trước, YTD, YTD cùng kỳ năm trước
params AS (
  SELECT
    x.*,
    CAST(DATE_TRUNC('YEAR', x.period_to_startdate) AS DATE) AS ytd_startdate, -- Ngày đầu năm của kỳ này
    ADD_MONTHS(CAST(DATE_TRUNC('YEAR', x.period_to_startdate) AS DATE), -12) AS ytd_py_startdate, -- Ngày đầu năm trước
    CASE 
      WHEN x.period_type = 'D' THEN ADD_MONTHS(x.period_to_enddate, -12)
      ELSE LAST_DAY(ADD_MONTHS(x.period_to_enddate, -12)) 
    END AS ytd_py_enddate -- Ngày cuối kỳ cùng kỳ năm trước
  FROM (
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
  ) x
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
    WHERE s.tradingdate BETWEEN p.ytd_py_startdate AND p.period_to_enddate
  )
  WHERE rn = 1 -- Bản ghi cuối mỗi ngày
)
-- 3. GT NĐTNN mua/bán theo ngày x loại chứng khoán -> Tính từ ngày đầu năm trước đến ngày cuối kỳ
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
    AND h.trade_date BETWEEN p.ytd_py_startdate AND p.period_to_enddate
    --AND s.loai_ck IN ('CP', 'CCQ', 'CW')
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
    AND h.trade_date BETWEEN DATE_FORMAT(p.ytd_py_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
    --AND s.loai_ck IN ('TPDNNY', 'CP', 'CCQ', 'CW', 'PS')
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
      AND o.trading_date BETWEEN p.ytd_py_startdate AND p.period_to_enddate
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
      AND r.trading_date BETWEEN p.ytd_py_startdate AND p.period_to_enddate
    GROUP BY r.trading_date
  )
  GROUP BY trade_date, loai_ck
  UNION ALL
  -- 3.4. TPDN riêng lẻ: Báo cáo HNX09 (chỉ lấy nguồn từ Sở - ICP; không lấy CDW/KDL)
  SELECT
    tk.report_date AS trade_date,
    'TPDNRL' AS loai_ck,
    SUM(CASE WHEN tk.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA' THEN tk.value ELSE 0 END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN tk.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN' THEN tk.value ELSE 0 END) AS gtgd_ndtnn_ban
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
      AND f.ds_snpst_dt = '2026-10-22' -- Snapshot date
      AND MAKE_DATE(f.report_year, f.report_month, f.report_day) BETWEEN p.ytd_py_startdate AND p.period_to_enddate
  ) tk
  GROUP BY tk.report_date
)
-- 4. Tổng hợp số liệu kỳ này, kỳ trước, YTD kỳ này, YTD cùng kỳ năm trước
, kpi AS (
  SELECT
    SUM(CASE WHEN d.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate THEN d.gtgd_ndtnn_mua ELSE 0 END) AS gtgd_ndtnn_mua_kynay,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate THEN d.gtgd_ndtnn_ban ELSE 0 END) AS gtgd_ndtnn_ban_kynay,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_prev_startdate AND p.period_prev_enddate THEN d.gtgd_ndtnn_mua ELSE 0 END) AS gtgd_ndtnn_mua_kytruoc,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_prev_startdate AND p.period_prev_enddate THEN d.gtgd_ndtnn_ban ELSE 0 END) AS gtgd_ndtnn_ban_kytruoc,
    SUM(CASE WHEN d.trade_date BETWEEN p.ytd_startdate AND p.period_to_enddate THEN d.gtgd_ndtnn_mua ELSE 0 END) AS gtgd_ndtnn_mua_ytd,
    SUM(CASE WHEN d.trade_date BETWEEN p.ytd_startdate AND p.period_to_enddate THEN d.gtgd_ndtnn_ban ELSE 0 END) AS gtgd_ndtnn_ban_ytd,
    SUM(CASE WHEN d.trade_date BETWEEN p.ytd_py_startdate AND p.ytd_py_enddate THEN d.gtgd_ndtnn_mua ELSE 0 END) AS gtgd_ndtnn_mua_ytd_py,
    SUM(CASE WHEN d.trade_date BETWEEN p.ytd_py_startdate AND p.ytd_py_enddate THEN d.gtgd_ndtnn_ban ELSE 0 END) AS gtgd_ndtnn_ban_ytd_py
  FROM trade_daily d
  CROSS JOIN params p
  WHERE d.loai_ck <> 'PS' -- Không tính giá trị danh nghĩa của giao dịch phái sinh vào tổng
)
-- 5. Dữ liệu lên dashboard
SELECT 
  p.period_type AS loaiky, 
  p.period_code AS ky, 
  m.metric_code, 
  m.metric_name, 
  m.gia_tri, 
  m.gia_tri_so_sanh,
  m.gia_tri - m.gia_tri_so_sanh AS chenh_lech,
  (m.gia_tri - m.gia_tri_so_sanh) / NULLIF(ABS(m.gia_tri_so_sanh), 0) * 100 AS ty_le_thay_doi_pt,
  m.co_so_so_sanh
FROM params p
CROSS JOIN (
  SELECT 
    1 AS thu_tu, 
    'gtgd_ndtnn_rong_kynay' AS metric_code, 
    'GT mua/bán ròng NĐTNN (kỳ)' AS metric_name,
    gtgd_ndtnn_mua_kynay - gtgd_ndtnn_ban_kynay AS gia_tri, 
    gtgd_ndtnn_mua_kytruoc - gtgd_ndtnn_ban_kytruoc AS gia_tri_so_sanh, 
    'Kỳ trước' AS co_so_so_sanh 
  FROM kpi
  UNION ALL
  SELECT
    2, 'gtgd_ndtnn_rong_ytd', 'GT mua/bán ròng NĐTNN (YTD)', 
    gtgd_ndtnn_mua_ytd - gtgd_ndtnn_ban_ytd, 
    gtgd_ndtnn_mua_ytd_py - gtgd_ndtnn_ban_ytd_py, 
    'Cùng kỳ năm trước' 
  FROM kpi
  UNION ALL
  SELECT 3, 'gtgd_ndtnn_mua', 'GT giao dịch NĐTNN mua', gtgd_ndtnn_mua_kynay, gtgd_ndtnn_mua_kytruoc, 'Kỳ trước' FROM kpi
  UNION ALL
  SELECT 4, 'gtgd_ndtnn_ban', 'GT giao dịch NĐTNN bán', gtgd_ndtnn_ban_kynay, gtgd_ndtnn_ban_kytruoc, 'Kỳ trước' FROM kpi
) m
ORDER BY m.thu_tu
;