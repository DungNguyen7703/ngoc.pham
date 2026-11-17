-- [19c] VỐN HÓA THỊ TRƯỜNG >> VỐN HÓA CỔ PHIẾU THEO NGÀNH + TỶ TRỌNG TỪNG NGÀNH
/* ==================================================================================
 * THAM SỐ TRA CỨU:
 *   :period_type  Loại kỳ: D (Ngày) | M (Tháng) | Q (Quý) | Y (Năm)
 *   :period_to    Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * QUY TẮC:
 *   - Vốn hóa tính tại ngày giao dịch gần nhất <= ngày cuối kỳ (cổ phiếu stocktype = '2', HOSE + HNX + UPCoM).
 *   - HOSE (10), HNX (02): giá đóng cửa. UPCoM (04): VWAP ngày T lấy từ ngày T+1 (VWAP = 0 -> giá tham chiếu ngày T).
 *     Nếu chưa có ngày T+1 (phiên mới nhất): vốn hóa UPCoM = NULL, các ngành/tổng chỉ gồm HOSE + HNX
 *   - Ngành: IDS (company_profiles/categories); CTCK (SC_FIRM_INFO), CTQLQ (fms.securities) là CTĐC -> 07000 (Tài chính ngân hàng).
 *     Mã chưa có ngành -> 'NA' / 'Chưa phân ngành'.
 *   - Tỷ trọng (%) = Vốn hóa ngành / Tổng vốn hóa tất cả ngành x 100.
 * ================================================================================== */
WITH
-- 1. THAM SỐ -> NGÀY ĐẦU/CUỐI KỲ
params AS (
  SELECT
    period_type, period_code, period_startdate,
    CASE period_type
      WHEN 'D' THEN period_startdate
      WHEN 'M' THEN LAST_DAY(period_startdate)
      WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(period_startdate, 3), 1)
      WHEN 'Y' THEN DATE_SUB(ADD_MONTHS(period_startdate, 12), 1)
    END AS period_enddate
  FROM (
    SELECT
      :period_type AS period_type,
      :period_to AS period_code,
      CAST(CASE :period_type
        WHEN 'D' THEN :period_to
        WHEN 'M' THEN CONCAT(:period_to, '-01')
        WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
        WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
      END AS DATE) AS period_startdate
  )
)
-- 2. LỊCH NGÀY GIAO DỊCH (HNX trade_book + MDDS)
, cal AS (
  SELECT DISTINCT TO_DATE(h.trade_date, 'yyyyMMdd') AS tradingdate
  FROM uat_hnx_stg.trade_book h
  CROSS JOIN params p
  WHERE h.trade_date >= DATE_FORMAT(ADD_MONTHS(p.period_startdate, -1), 'yyyyMMdd')
    AND h.trade_date <= DATE_FORMAT(ADD_MONTHS(p.period_enddate, 1), 'yyyyMMdd')
  UNION
  SELECT DISTINCT m.tradingdate
  FROM uat_mdds_stg.jad_marketinfor m
  CROSS JOIN params p
  WHERE m.tradingdate >= ADD_MONTHS(p.period_startdate, -1)
    AND m.tradingdate <= ADD_MONTHS(p.period_enddate, 1)
)
-- 3. NGÀY GIAO DỊCH CUỐI KỲ VÀ NGÀY LIỀN SAU (T+1: chứa VWAP tính vốn hóa UPCoM)
, key_dates AS (
  SELECT
    p.period_type, p.period_code,
    MAX(CASE WHEN c.tradingdate <= p.period_enddate THEN c.tradingdate END) AS tradedate,
    MIN(CASE WHEN c.tradingdate >  p.period_enddate THEN c.tradingdate END) AS t1_tradedate
  FROM params p
  CROSS JOIN cal c
  GROUP BY p.period_type, p.period_code
)
-- 4. CỔ PHIẾU CUỐI NGÀY TẠI NGÀY CHỐT VÀ NGÀY T+1
, stock_eod AS (
  SELECT tradingdate, symbol, floorcode, closeprice, vwap, reference
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.floorcode, s.closeprice, s.vwap, s.reference,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN key_dates k
    WHERE s.tradingdate IN (k.tradedate, k.t1_tradedate)
      AND s.stocktype = '2' -- Chỉ lấy cổ phiếu
  ) WHERE rn = 1
)
-- 5. VỐN HÓA THEO CỔ PHIẾU
, equity_data AS (
  SELECT
    x.*,
    os.outstanding_shares,
    x.price * os.outstanding_shares AS marketcap
  FROM (
    SELECT
      k.period_type, k.period_code, k.tradedate, k.t1_tradedate,
      s.symbol, s.floorcode,
      CASE
        WHEN s.floorcode = '04' THEN
          (CASE 
            WHEN n.vwap IS NULL THEN NULL --> vwap chưa có thì không tính vốn hóa UPCOM
            ELSE COALESCE(NULLIF(n.vwap, 0), s.reference) --> Mã trắng thanh khoản có VWAP = 0 thì lấy giá tham chiếu ngày T
          END)
        ELSE s.closeprice -- HNX/HOSE: Lấy giá đóng cửa
      END AS price
    FROM key_dates k
    JOIN stock_eod s ON s.tradingdate = k.tradedate
    LEFT JOIN stock_eod n ON n.symbol = s.symbol AND n.tradingdate = k.t1_tradedate
  ) x
  LEFT JOIN uat_vsdc_stg.outstanding_shares os ON os.transaction_date = x.tradedate AND os.ticker_symbol = x.symbol
)
-- 6. NGÀNH CỦA MÃ CỔ PHIẾU (IDS/SCMS/FMS) - theo [35]
, industry_map AS (
  SELECT
    t.symbol,
    -- Phân ngành: Nếu là CTCK/CTQLQ đã đại chúng thì fix là Tài chính ngân hàng, còn lại lấy từ IDS (Hồ sơ CTĐC)
    CASE WHEN sc.securities_code IS NOT NULL OR f.stock_code IS NOT NULL THEN '07000' ELSE c.industry_cd END AS industry_cd,
    CASE WHEN sc.securities_code IS NOT NULL OR f.stock_code IS NOT NULL THEN i.industry_name ELSE c.industry_name END AS industry_name
  FROM (SELECT DISTINCT symbol FROM equity_data) t
  LEFT JOIN (
    -- Thông tin Công ty đại chúng
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
    -- Thông tin phân ngành cấp 1
    SELECT id, industry_cd, industry_name
    FROM uat_ids_stg.categories
    WHERE ds_snpst_dt = '2026-10-17'
  ) c ON p.category_l1_id = c.id
  LEFT JOIN (
    -- Thông tin hồ sơ CTCK
    SELECT DISTINCT securities_code
    FROM uat_scms_stg.SC_FIRM_INFO
    WHERE deleted = '0' AND securities_code IS NOT NULL AND ds_snpst_dt = '2026-08-22'
  ) sc ON t.symbol = sc.securities_code
  LEFT JOIN (
    -- Thông tin hồ sơ CT CLQ
    SELECT DISTINCT stock_code
    FROM uat_fms_stg.securities
    WHERE deleted = 0 AND stock_code IS NOT NULL AND ds_snpst_dt = '2026-10-21'
  ) f ON t.symbol = f.stock_code
  CROSS JOIN (
    -- Thông tin tên ngành Tài chính ngân hàng
    SELECT DISTINCT industry_name AS industry_name
    FROM uat_ids_stg.categories
    WHERE industry_cd = '07000' AND active_flg = '1' AND ds_snpst_dt = '2026-10-17'
  ) i
)
-- 7. VỐN HÓA THEO NGÀNH
, industry_agg AS (
  SELECT
    e.period_type, e.period_code, e.tradedate,
    COALESCE(m.industry_cd, 'NA') AS industry_cd,
    COALESCE(m.industry_name, 'Chưa phân ngành') AS industry_name,
    COUNT(e.symbol) AS so_ma_cp,
    SUM(e.marketcap) AS marketcap
  FROM equity_data e
  LEFT JOIN industry_map m ON e.symbol = m.symbol
  GROUP BY e.period_type, e.period_code, e.tradedate, COALESCE(m.industry_cd, 'NA'), COALESCE(m.industry_name, 'Chưa phân ngành')
)
-- 8. KẾT QUẢ: TỪNG NGÀNH + DÒNG TỔNG TẤT CẢ NGÀNH + TỶ TRỌNG
SELECT
  period_type AS loaiky,
  period_code AS ky,
  tradedate, -- Ngày giao dịch chốt vốn hóa
  industry_cd,
  industry_name,
  so_ma_cp, -- Số mã cổ phiếu
  marketcap, -- Vốn hóa (VND)
  marketcap / 1e9 AS marketcap_ty_dong,
  marketcap / NULLIF(SUM(marketcap) OVER(PARTITION BY period_code), 0) * 100.0 AS ty_trong_pct -- Tỷ trọng (%) trong tổng vốn hóa
FROM (
  SELECT period_type, period_code, tradedate, industry_cd, industry_name, so_ma_cp, marketcap, thieu_von_hoa_upcom, 0 AS is_total
  FROM industry_agg
) x
UNION ALL
SELECT
  period_type, period_code, tradedate,
  'TOTAL', 'Tổng tất cả ngành',
  SUM(so_ma_cp) so_ma_cp, SUM(marketcap) marketcap, SUM(marketcap) / 1e9 marketcap_ty_dong,
  CASE WHEN SUM(marketcap) > 0 THEN 100.0 END ty_trong_pct
FROM industry_agg
GROUP BY period_type, period_code, tradedate
ORDER BY CASE WHEN industry_cd = 'TOTAL' THEN 0 ELSE 1 END, marketcap DESC
;