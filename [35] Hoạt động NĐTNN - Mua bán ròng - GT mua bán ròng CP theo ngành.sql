-- [35] HOẠT ĐỘNG NĐTNN >> MUA/BÁN RÒNG >> GT MUA/BÁN RÒNG CỔ PHIẾU THEO NHÓM NGÀNH
/* Tham số tra cứu:
 * :period_type  Loại kỳ: D/M/Q/Y
 * :period_to    Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * Nhận diện Giao dịch của NĐTNN: Ký tự thứ 4 trong số tài khoản giao dịch IN ('E','F')
 */
-- ======================================================================================
--   Cổ phiếu: stocktype = '2' (HOSE + HNX + UPCoM).
--   CTCK/CTQLQ là CTĐC -> mặc định ngành 07000 (Tài chính ngân hàng).
-- ======================================================================================
WITH
-- 1. Tham số tra cứu: Loại kỳ (D/M/Q/Y) + Kỳ báo cáo -> ngày đầu/cuối kỳ
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
    END AS period_to_enddate -- Ngày cuối kỳ
  FROM (
    SELECT
      :period_type AS period_type, -- Loại kỳ: D/M/Q/Y
      :period_to AS period_code, -- Kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
      CAST(CASE :period_type
        WHEN 'D' THEN :period_to
        WHEN 'M' THEN CONCAT(:period_to, '-01')
        WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
        WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
      END AS DATE) AS period_to_startdate -- Ngày đầu kỳ
  )
)
-- 2. Cổ phiếu: bản ghi cuối ngày trong jad_stockinfor
, stock_daily_eod AS (
  SELECT tradingdate, symbol, symbolisin
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.symbolisin,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN params p
    WHERE s.stocktype = '2' -- Cổ phiếu
      AND s.tradingdate BETWEEN p.period_to_startdate AND p.period_to_enddate
  )
  WHERE rn = 1 -- Bản ghi cuối mỗi ngày
)
-- 3. GT NĐTNN mua/bán trong kỳ theo mã cổ phiếu
, stock_trade AS (
  SELECT symbol, SUM(ndtnn_mua_gt) AS ndtnn_mua_gt, SUM(ndtnn_ban_gt) AS ndtnn_ban_gt
  FROM (
    SELECT -- HOSE
      s.symbol,
      SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS ndtnn_mua_gt,
      SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS ndtnn_ban_gt
    FROM uat_hose_stg.trade_book h
    JOIN stock_daily_eod s ON h.symbol = s.symbol AND h.trade_date = s.tradingdate
    CROSS JOIN params p
    WHERE h.market_id = 'STK'
      AND h.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate
    GROUP BY s.symbol
    UNION ALL
    SELECT -- HNX + UPCoM (join với jad_stockinfor theo mã ISIN)
      s.symbol,
      SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ndtnn_mua_gt,
      SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ndtnn_ban_gt
    FROM uat_hnx_stg.trade_book h
    JOIN stock_daily_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
    CROSS JOIN params p
    WHERE h.market_id IN ('STX', 'UPX')
      AND h.trade_date BETWEEN DATE_FORMAT(p.period_to_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
    GROUP BY s.symbol
  )
  GROUP BY symbol
)
-- 4. Ngành của mã cổ phiếu (IDS/SCMS/FMS)
, industry_map AS (
  SELECT
    t.symbol,
    CASE WHEN sc.securities_code IS NOT NULL OR f.stock_code IS NOT NULL THEN '07000' ELSE c.industry_cd END AS industry_cd, --CTCK/CTQLQ mặc định ngành = Tài chính ngân hàng
    CASE WHEN sc.securities_code IS NOT NULL OR f.stock_code IS NOT NULL THEN i.industry_name ELSE c.industry_name END AS industry_name
  FROM stock_daily_eod t
  LEFT JOIN (
    SELECT equity_ticker, category_l1_id
    FROM (
      SELECT equity_ticker, category_l1_id,
        ROW_NUMBER() OVER(PARTITION BY equity_ticker ORDER BY id) rn -- Lấy bản ghi cũ hơn (lọc dữ liệu test trùng)
      FROM uat_ids_stg.company_profiles
      WHERE delete_flg <> '1'
        AND (approval_status_cd <> 'REJECTED' OR approval_status_cd IS NULL)
        AND ds_snpst_dt = '2026-10-17'
    ) WHERE rn = 1
  ) p ON t.symbol = p.equity_ticker
  LEFT JOIN (
    SELECT id, industry_cd, industry_name
    FROM uat_ids_stg.categories
    WHERE ds_snpst_dt = '2026-10-17'
  ) c ON p.category_l1_id = c.id
  -- CTCK là CTĐC đã niêm yết/ĐKGD -> Tài chính ngân hàng
  LEFT JOIN (
    SELECT DISTINCT securities_code
    FROM uat_scms_stg.SC_FIRM_INFO
    WHERE deleted = '0' AND securities_code IS NOT NULL AND ds_snpst_dt = '2026-08-22'
  ) sc ON t.symbol = sc.securities_code
  -- CTQLQ là CTĐC đã niêm yết/ĐKGD -> Tài chính ngân hàng
  LEFT JOIN (
    SELECT DISTINCT stock_code
    FROM uat_fms_stg.securities
    WHERE deleted = 0 AND stock_code IS NOT NULL AND ds_snpst_dt = '2026-10-21'
  ) f ON t.symbol = f.stock_code
  CROSS JOIN (
    SELECT DISTINCT industry_name AS industry_name
    FROM uat_ids_stg.categories
    WHERE industry_cd = '07000' AND active_flg = '1' AND ds_snpst_dt = '2026-10-17'
  ) i
)
-- 5. Dữ liệu biểu đồ: Mua/Bán ròng theo ngành
SELECT
  p.period_type AS loaiky,
  p.period_code AS ky,
  COALESCE(m.industry_cd, 'NA') AS industry_cd,
  COALESCE(m.industry_name, 'Chưa phân ngành') AS industry_name,
  SUM(t.ndtnn_mua_gt) AS ndtnn_mua_gt,
  SUM(t.ndtnn_ban_gt) AS ndtnn_ban_gt,
  SUM(t.ndtnn_mua_gt - t.ndtnn_ban_gt) AS ndtnn_rong_gt
FROM stock_trade t
LEFT JOIN industry_map m ON t.symbol = m.symbol
CROSS JOIN params p
GROUP BY p.period_type, p.period_code, COALESCE(m.industry_cd, 'NA'), COALESCE(m.industry_name, 'Chưa phân ngành')
ORDER BY ABS(ndtnn_rong_gt) DESC
;