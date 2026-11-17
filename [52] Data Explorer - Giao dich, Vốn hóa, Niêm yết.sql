-- DATA EXPLORER - GIAO DỊCH: KLGD, GTGD, NĐTNN, TỰ DOANH, GTGD BÌNH QUÂN/PHIÊN, KỲ HẠN CÒN LẠI & YTM BÌNH QUÂN TPDNNY
/* Tham số:
 *  :period_type  D | M | Q | Y
 *  :period_from, :period_to  Từ kỳ - Đến kỳ: D = yyyy-MM-dd | M = yyyy-MM | Q = yyyy-Q[1-4] | Y = yyyy
 * Độ chi tiết: Kỳ x Chiều x Mã chứng khoán (TPCP, TPDN riêng lẻ: Kỳ x Loại CK, không chi tiết mã)
 * Chiều: Kỳ (period_code) | Sàn (san) | Chỉ số Index (index_codes - mảng) | Ngành (industry_cd, industry_name) | Loại chứng khoán (loai_ck)
 *        | Sản phẩm phái sinh (derivative_product, derivative_product_detail) | Kỳ hạn phái sinh (derivative_term) | Mã chứng khoán (symbol)
 * Loại chứng khoán (loai_ck): CP | CCQ | ETF | CQ | TPDNNY | PS | TPCP | TPDNRL
 */
WITH
-- =========================
-- 0. THAM SỐ: ngày đầu của Từ kỳ, ngày cuối của Đến kỳ
params_base AS (
  SELECT
    UPPER(:period_type) AS period_type,
    CASE UPPER(:period_type)
      WHEN 'D' THEN TO_DATE(:period_from)
      WHEN 'M' THEN TO_DATE(CONCAT(:period_from, '-01'))
      WHEN 'Q' THEN MAKE_DATE(CAST(SUBSTR(:period_from, 1, 4) AS INT), (CAST(SUBSTR(:period_from, 7, 1) AS INT) - 1) * 3 + 1, 1)
      WHEN 'Y' THEN MAKE_DATE(CAST(:period_from AS INT), 1, 1)
    END AS from_date,
    CASE UPPER(:period_type)
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(MAKE_DATE(CAST(SUBSTR(:period_to, 1, 4) AS INT), CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3, 1))
      WHEN 'Y' THEN MAKE_DATE(CAST(:period_to AS INT), 12, 31)
    END AS to_date
)
, params AS (
  SELECT period_type, from_date, to_date, 
    CAST(DATE_TRUNC('YEAR', from_date) AS DATE) AS ytd_from -- Ngày đầu năm của "Từ kỳ": đọc dữ liệu từ ngày này để tính lũy kế YTD
  FROM params_base
)
-- Ngành mặc định cho CTCK, CTQLQ là CTĐC: Tài chính ngân hàng
, industry_fix_ctck_ctqlq AS (
  SELECT DISTINCT industry_cd, industry_name
  FROM uat_ids_stg.categories
  WHERE industry_cd = '07000' AND active_flg = '1' AND ds_snpst_dt = '2026-11-11'
  LIMIT 1
)
-- =========================
-- 1. Thông tin chứng khoán (bản ghi cuối ngày trong jad_stockinfor) + Map ngành nghề cho từng mã CP/TPDNNY/CQ
, stock_eod AS (
  SELECT 
    st.*,
    -- Ngành nghề với TPDN niêm yết, Cổ phiếu, Chứng quyền + CTCK/CTQLQ mặc định ngành = Tài chính ngân hàng
    CASE WHEN loai_ck IN ('TPDNNY', 'CP', 'CQ') THEN COALESCE(p.industry_cd, sc.industry_cd, f.industry_cd, 'NA') END AS industry_cd,
    CASE WHEN loai_ck IN ('TPDNNY', 'CP', 'CQ') THEN COALESCE(p.industry_name, sc.industry_name, f.industry_name, 'Chưa phân ngành') END AS industry_name
  FROM (
    SELECT 
      tradingdate, symbol, symbolisin, issue_code, stocktype, floorcode, loai_ck, 
      derivative_product, derivative_product_detail, maturitymonthyear, maturitydate, yield, closeprice,
      -- PHÂN LOẠI KỲ HẠN PHÁI SINH
      CASE 
        WHEN maturity_month IS NULL OR derivative_product_detail IS NULL THEN NULL -- Chỉ HĐ phái sinh
        -- 1) HĐ TPCP: 03 tháng cuối 03 Quý gần nhất.
        WHEN productgrpid = 'FBX' THEN 
          CASE DENSE_RANK() OVER(PARTITION BY tradingdate, derivative_product_detail ORDER BY maturity_month)
            WHEN 1 THEN 'Tháng cuối quý gần nhất'
            WHEN 2 THEN 'Tháng cuối quý tiếp theo 1'
            WHEN 3 THEN 'Tháng cuối quý tiếp theo 2'
          END
        -- 2) HĐ chỉ số: Tháng hiện tại, tháng kế tiếp, hai tháng cuối 02 quý tiếp theo.
        WHEN maturity_month = m1 THEN 'Tháng gần nhất'
        WHEN maturity_month = ADD_MONTHS(m1, 1) THEN 'Tháng tiếp theo'
        WHEN MONTH(maturity_month) % 3 = 0 THEN 
          CASE DENSE_RANK() OVER(
              PARTITION BY tradingdate, derivative_product_detail, (maturity_month = m1 OR maturity_month = ADD_MONTHS(m1, 1) OR MONTH(maturity_month) % 3 <> 0) 
              ORDER BY maturity_month) -- Tách nhóm tháng cuối quý còn lại
            WHEN 1 THEN 'Tháng cuối quý gần nhất'
            WHEN 2 THEN 'Tháng cuối quý tiếp theo 1'
          END
      END AS derivative_term, -- Kỳ hạn phái sinh
      contractmultiplier, listedshare, par_value,
      listedshare * par_value AS listedvalue,
      -- TPDNNY: Dư nợ = KL niêm yết x Mệnh giá; Kỳ hạn còn lại (năm) = (Ngày đáo hạn - Ngày) / 12 tháng; YTM = yield
      ---- Mã thiếu ngày đáo hạn hoặc YTM: không tính vào cả tử số và mẫu số
      CASE WHEN loai_ck = 'TPDNNY' AND maturitydate IS NOT NULL AND yield IS NOT NULL 
           THEN listedshare * par_value END AS duno,
      CASE WHEN loai_ck = 'TPDNNY' AND maturitydate IS NOT NULL AND yield IS NOT NULL 
           THEN listedshare * par_value * MONTHS_BETWEEN(maturitydate, tradingdate) / 12 END AS duno_x_kyhan,
      CASE WHEN loai_ck = 'TPDNNY' AND maturitydate IS NOT NULL AND yield IS NOT NULL 
           THEN listedshare * par_value * yield END AS duno_x_ytm
    FROM ( 
      -- 1.1. Bản ghi cuối ngày của từng mã + tháng đáo hạn gần nhất (m1) của sản phẩm phái sinh trong ngày
      SELECT
        x.*,
        MIN(x.maturity_month) OVER(PARTITION BY x.tradingdate, x.derivative_product_detail) AS m1 -- Tháng đáo hạn gần nhất của sản phẩm trong ngày
      FROM (
        SELECT
          s.tradingdate,
          s.symbol,
          s.symbolisin,
          s.stocktype,
          s.floorcode,
          s.productgrpid,
          CASE 
            WHEN s.stocktype = '1' AND s.floorcode <> '03' THEN SUBSTR(s.symbol,3)
            WHEN s.stocktype = '2' THEN s.symbol
            WHEN s.stocktype = '4' AND SUBSTR(s.productid, 6, 2) = 'EW' THEN s.underlyingsymbol
          END issue_code, -- Mã TCPH của Cổ phiếu, TPDN niêm yết, Chứng quyền (mã CK cơ sở)
          CASE
            WHEN s.floorcode = '03' AND s.stocktype IN ('4', '5') THEN 'PS' -- Phái sinh (HĐTL, HĐ quyền chọn)
            WHEN s.stocktype = '1' THEN 'TPDNNY'                            -- TPDN niêm yết
            WHEN s.stocktype = '2' THEN 'CP'                                -- Cổ phiếu
            WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'M' THEN 'CCQ'  -- Chứng chỉ quỹ (Không gồm ETF)
            WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'E' THEN 'ETF'  -- Chứng chỉ quỹ ETF
            WHEN SUBSTR(s.productid, 6, 2) = 'EW' THEN 'CQ'                 -- Chứng quyền
          END AS loai_ck,
          -- Sản phẩm phái sinh: HĐTL VN30, HĐTL VN100, HĐTL TPCP, HĐ quyền chọn VN30, ...
          IF(s.floorcode = '03', CONCAT(MAP('4','HĐTL','5','HĐ quyền chọn')[s.stocktype], ' ', IF(s.productgrpid = 'FBX', 'TPCP', s.underlyingsymbol)), NULL) AS derivative_product,
          -- Sản phẩm phái sinh chi tiết: HĐTL VN30, HĐTL TPCP VGB05, HĐTL TPCP VGB10, ...
          IF(s.floorcode = '03', CONCAT(MAP('4','HĐTL','5','HĐ quyền chọn')[s.stocktype], IF(s.productgrpid = 'FBX', ' TPCP', ''), ' ', s.underlyingsymbol), NULL) AS derivative_product_detail,
          TO_DATE(s.maturitydate, 'dd/MM/yyyy') AS maturitydate, -- Ngày đáo hạn (string dd/MM/yyyy -> date)
          s.maturitymonthyear, 
          IF(s.floorcode = '03', TO_DATE(s.maturitymonthyear, 'yyyyMM'), NULL) AS maturity_month, -- Tháng đáo hạn (ngày 01)
          CAST(s.contractmultiplier AS DOUBLE) AS contractmultiplier,
          CAST(s.listedshare AS DECIMAL(38,10)) AS listedshare,
          CASE 
            WHEN s.stocktype = '1' THEN 100000 * POWER(10, ROUND(LN(NULLIF(s.reference, 0) / 100000) / LN(10))) -- TPDNNY: Mệnh giá suy ngược từ giá tham chiếu (bội số 100000, bước nhảy x10)
            WHEN s.stocktype IN ('2','3','6') THEN 10000 -- CP, CCQ, ETF: 10000đ
            -- CQ: Không có thông tin Mệnh giá
          END AS par_value, -- Mệnh giá
          IF(s.yield IN ('-9999','-9999.0000'), NULL, CAST(s.yield AS DOUBLE)) AS yield, -- YTM trái phiếu
          s.closeprice,
          ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn
        FROM uat_mdds_stg.jad_stockinfor s
        JOIN params p ON s.tradingdate BETWEEN p.ytd_from AND p.to_date
      ) x
      WHERE x.rn = 1 -- Bản ghi cuối mỗi ngày
    )
  ) st 
  -- Thông tin hồ sơ Công ty đại chúng + phân ngành
  LEFT JOIN (
    SELECT cp.equity_ticker, cp.category_l1_id, c.industry_cd, c.industry_name
    FROM (
      SELECT equity_ticker, category_l1_id,
        ROW_NUMBER() OVER(PARTITION BY equity_ticker ORDER BY id) rn -- Lấy bản ghi cũ hơn (lọc dữ liệu test trùng)
      FROM uat_ids_stg.company_profiles
      WHERE delete_flg <> '1' AND (approval_status_cd <> 'REJECTED' OR approval_status_cd IS NULL)
        AND ds_snpst_dt = '2026-11-11'
    ) cp
    LEFT JOIN uat_ids_stg.categories c ON cp.category_l1_id = c.id AND ds_snpst_dt = '2026-11-11' -- Thông tin ngành nghề kinh tế 
    WHERE cp.rn = 1
  ) p ON st.issue_code = p.equity_ticker 
  -- CTCK là CTĐC đã niêm yết/ĐKGD 
  LEFT JOIN (
    SELECT DISTINCT sc.securities_code, i.industry_cd, i.industry_name 
    FROM uat_scms_stg.SC_FIRM_INFO sc
    CROSS JOIN industry_fix_ctck_ctqlq i --> Fix ngành nghề là Tài chính ngân hàng với CTCK, CTQLQ là CTĐC
    WHERE sc.deleted = '0' AND sc.securities_code IS NOT NULL AND sc.ds_snpst_dt = '2026-08-22'
  ) sc ON st.issue_code = sc.securities_code
  -- CTQLQ là CTĐC đã niêm yết/ĐKGD 
  LEFT JOIN (
    SELECT DISTINCT f.stock_code, i.industry_cd, i.industry_name 
    FROM uat_fms_stg.securities f
    CROSS JOIN industry_fix_ctck_ctqlq i --> Fix ngành nghề là Tài chính ngân hàng với CTCK, CTQLQ là CTĐC
    WHERE f.deleted = 0 AND f.stock_code IS NOT NULL AND f.ds_snpst_dt = '2026-10-21'
  ) f ON st.issue_code = f.stock_code
)
-- Khối lượng mở CK phái sinh
, oi_eod AS (
  SELECT oi.contract_code, oi.open_interest_volume, oi.report_date
  FROM uat_vsdc_stg.end_of_day_open_interest oi
  JOIN params p ON oi.report_date BETWEEN p.from_date AND p.to_date
) 
-- 1.3. Rổ chỉ số Index của mã chứng khoán theo ngày 
, stock_index AS (
  SELECT 
    cs.tradingdate, 
    cs.symbol, 
    SORT_ARRAY(COLLECT_SET(cs.indexcode)) AS index_codes -- Danh sách chỉ số
  FROM uat_mdds_stg.jad_csidxinfor cs
  JOIN params p ON cs.tradingdate BETWEEN p.ytd_from AND p.to_date
  GROUP BY cs.tradingdate, cs.symbol
)
-- =========================
-- 2. KLGD, GTGD, KL/GT NĐTNN, Tự doanh mua/bán theo ngày x sàn x mã chứng khoán
-- 2.1. HNX (STX, UPX, HCX, DVX): CP, CCQ, ETF, TPDNNY, Phái sinh; HOSE (STK): CP, CCQ, ETF, CQ
, stock_trade_daily AS (
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    h.market_id, -- Sàn
    s.symbol, 
    SUM(h.trade_quantity) AS klgd,
    SUM(h.trade_quantity * h.trade_price * NVL(s.contractmultiplier,1)) AS gtgd, -- contractmultiplier để tính GT danh nghĩa giao dịch phái sinh
    SUM(CASE WHEN h.board_id IN ('G1','G2','G3','G4','G7','G8') THEN h.trade_quantity END) AS klgd_khoplenh,
    SUM(CASE WHEN h.board_id IN ('G1','G2','G3','G4','G7','G8') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier,1) END) AS gtgd_khoplenh,
    SUM(CASE WHEN h.board_id IN ('T1','T2','T3','T4','T6','R1') THEN h.trade_quantity END) AS klgd_thoathuan,
    SUM(CASE WHEN h.board_id IN ('T1','T2','T3','T4','T6','R1') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier,1) END) AS gtgd_thoathuan,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E','F') THEN h.trade_quantity END) AS klgd_ndtnn_mua,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E','F') THEN h.trade_quantity END) AS klgd_ndtnn_ban,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E','F') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier,1) END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E','F') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier,1) END) AS gtgd_ndtnn_ban,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('P','E','A') THEN h.trade_quantity END) AS klgd_tudoanh_mua,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('P','E','A') THEN h.trade_quantity END) AS klgd_tudoanh_ban,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('P','E','A') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier,1) END) AS gtgd_tudoanh_mua,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('P','E','A') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier,1) END) AS gtgd_tudoanh_ban
  FROM uat_hnx_stg.trade_book h
  CROSS JOIN params p
  LEFT JOIN stock_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
  WHERE h.market_id IN ('HCX','DVX','STX','UPX')
    AND h.trade_date BETWEEN DATE_FORMAT(p.ytd_from, 'yyyyMMdd') AND DATE_FORMAT(p.to_date, 'yyyyMMdd')
  GROUP BY h.trade_date, h.market_id, s.symbol
  UNION ALL
  SELECT
    h.trade_date,
    h.market_id, -- Sàn
    h.symbol,
    SUM(h.execution_volume) AS klgd,
    SUM(h.execution_value) AS gtgd,
    SUM(CASE WHEN h.board_type IN ('G1','G2','G3','G4','G7','G8') THEN h.execution_volume END) AS klgd_khoplenh,
    SUM(CASE WHEN h.board_type IN ('G1','G2','G3','G4','G7','G8') THEN h.execution_value END) AS gtgd_khoplenh,
    SUM(CASE WHEN h.board_type IN ('T1','T2','T3','T4','T6','R1') THEN h.execution_volume END) AS klgd_thoathuan,
    SUM(CASE WHEN h.board_type IN ('T1','T2','T3','T4','T6','R1') THEN h.execution_value END) AS gtgd_thoathuan,
    SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E','F') THEN h.execution_volume END) AS klgd_ndtnn_mua,
    SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E','F') THEN h.execution_volume END) AS klgd_ndtnn_ban,
    SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E','F') THEN h.execution_value END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E','F') THEN h.execution_value END) AS gtgd_ndtnn_ban,
    SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('P','E','A') THEN h.execution_volume END) AS klgd_tudoanh_mua,
    SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('P','E','A') THEN h.execution_volume END) AS klgd_tudoanh_ban,
    SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('P','E','A') THEN h.execution_value END) AS gtgd_tudoanh_mua,
    SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('P','E','A') THEN h.execution_value END) AS gtgd_tudoanh_ban
  FROM uat_hose_stg.trade_book h
  CROSS JOIN params p
  WHERE h.market_id IN ('STK') 
    AND h.trade_date BETWEEN p.ytd_from AND p.to_date 
  GROUP BY h.trade_date, h.market_id, h.symbol
)
-- 2.2. TPCP: sổ lệnh outright + repo đã thực hiện (ĐTH)
---- Không chi tiết đến mã trái phiếu (bond_code) -> symbol = NULL, gom theo ngày
, govbond_trade_daily AS (
  SELECT
    trade_date,
    'TPCP' AS market_id,
    symbol,
    SUM(klgd) AS klgd,
    SUM(gtgd) AS gtgd,
    SUM(klgd_ndtnn_mua) AS klgd_ndtnn_mua, 
    SUM(klgd_ndtnn_ban) AS klgd_ndtnn_ban,
    SUM(gtgd_ndtnn_mua) AS gtgd_ndtnn_mua,
    SUM(gtgd_ndtnn_ban) AS gtgd_ndtnn_ban,
    SUM(klgd_tudoanh_mua) AS klgd_tudoanh_mua,
    SUM(klgd_tudoanh_ban) AS klgd_tudoanh_ban,
    SUM(gtgd_tudoanh_mua) AS gtgd_tudoanh_mua,
    SUM(gtgd_tudoanh_ban) AS gtgd_tudoanh_ban
  FROM (
    SELECT
      o.trading_date AS trade_date,
      CAST(NULL AS STRING) AS symbol, -- Không chi tiết theo mã trái phiếu
      SUM(o.volume) AS klgd,
      SUM(o.trading_value) AS gtgd,
      SUM(CASE WHEN SUBSTR(o.buying_account_no, 4, 1) IN ('E','F') THEN o.volume ELSE 0 END) AS klgd_ndtnn_mua,
      SUM(CASE WHEN SUBSTR(o.selling_account_no, 4, 1) IN ('E','F') THEN o.volume ELSE 0 END) AS klgd_ndtnn_ban,
      SUM(CASE WHEN SUBSTR(o.buying_account_no, 4, 1) IN ('E','F') THEN o.trading_value ELSE 0 END) AS gtgd_ndtnn_mua,
      SUM(CASE WHEN SUBSTR(o.selling_account_no, 4, 1) IN ('E','F') THEN o.trading_value ELSE 0 END) AS gtgd_ndtnn_ban,
      SUM(CASE WHEN SUBSTR(o.buying_account_no, 4, 1) IN ('P','E','A') THEN o.volume ELSE 0 END) AS klgd_tudoanh_mua,
      SUM(CASE WHEN SUBSTR(o.selling_account_no, 4, 1) IN ('P','E','A') THEN o.volume ELSE 0 END) AS klgd_tudoanh_ban,
      SUM(CASE WHEN SUBSTR(o.buying_account_no, 4, 1) IN ('P','E','A') THEN o.trading_value ELSE 0 END) AS gtgd_tudoanh_mua,
      SUM(CASE WHEN SUBSTR(o.selling_account_no, 4, 1) IN ('P','E','A') THEN o.trading_value ELSE 0 END) AS gtgd_tudoanh_ban
    FROM uat_hnx_stg.outright_order_book o
    CROSS JOIN params p
    WHERE o.order_status = 'ĐTH'
      AND o.trading_date BETWEEN p.ytd_from AND p.to_date
    GROUP BY o.trading_date
    UNION ALL
    SELECT
      r.trading_date AS trade_date,
      CAST(NULL AS STRING) AS symbol, -- Không chi tiết theo mã trái phiếu
      SUM(r.volume) AS klgd,
      SUM(r.first_settlement_value) AS gtgd,
      SUM(CASE WHEN SUBSTR(r.buying_account_no, 4, 1) IN ('E', 'F') THEN r.volume ELSE 0 END) AS klgd_ndtnn_mua,
      SUM(CASE WHEN SUBSTR(r.selling_account_no, 4, 1) IN ('E', 'F') THEN r.volume ELSE 0 END) AS klgd_ndtnn_ban,
      SUM(CASE WHEN SUBSTR(r.buying_account_no, 4, 1) IN ('E', 'F') THEN r.first_settlement_value ELSE 0 END) AS gtgd_ndtnn_mua,
      SUM(CASE WHEN SUBSTR(r.selling_account_no, 4, 1) IN ('E', 'F') THEN r.first_settlement_value ELSE 0 END) AS gtgd_ndtnn_ban,
      SUM(CASE WHEN SUBSTR(r.buying_account_no, 4, 1) IN ('P','E','A') THEN r.volume ELSE 0 END) AS klgd_tudoanh_mua,
      SUM(CASE WHEN SUBSTR(r.selling_account_no, 4, 1) IN ('P','E','A') THEN r.volume ELSE 0 END) AS klgd_tudoanh_ban,
      SUM(CASE WHEN SUBSTR(r.buying_account_no, 4, 1) IN ('P','E','A') THEN r.first_settlement_value ELSE 0 END) AS gtgd_tudoanh_mua,
      SUM(CASE WHEN SUBSTR(r.selling_account_no, 4, 1) IN ('P','E','A') THEN r.first_settlement_value ELSE 0 END) AS gtgd_tudoanh_ban
    FROM uat_hnx_stg.repo_order_book r
    CROSS JOIN params p
    WHERE r.order_status = 'ĐTH'
      AND r.trading_date BETWEEN p.ytd_from AND p.to_date
    GROUP BY r.trading_date
  )
  GROUP BY trade_date, symbol
)
-- 2.3. TPDN riêng lẻ: báo cáo HNX09 (chỉ lấy nguồn từ Sở - ICP; không lấy CDW/KDL) - Số liệu tổng theo ngày, không có chi tiết mã
, corpbond_trade_daily AS (
  SELECT
    f.report_date AS trade_date,
    'TPDNRL' AS market_id,
    CAST(NULL AS STRING) AS symbol,
    SUM(CASE WHEN f.row_path = 'GIÁ TRỊ GIAO DỊCH' THEN f.value END) AS gtgd,
    SUM(CASE WHEN f.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA' THEN f.value END) AS gtgd_ndtnn_mua,
    SUM(CASE WHEN f.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN' THEN f.value END) AS gtgd_ndtnn_ban,
    SUM(CASE WHEN f.row_path = 'GIÁ TRỊ GIAO DỊCH CỦA KHỐI TỰ DOANH - GIÁ TRỊ MUA' THEN f.value END) AS gtgd_tudoanh_mua,
    SUM(CASE WHEN f.row_path = 'GIÁ TRỊ GIAO DỊCH CỦA KHỐI TỰ DOANH - GIÁ TRỊ BÁN' THEN f.value END) AS gtgd_tudoanh_ban
  FROM (
    SELECT
      MAKE_DATE(r.report_year, r.report_month, r.report_day) AS report_date,
      r.row_path,
      CASE WHEN r.data_type IN ('CURRENCY', 'PERCENTAGE', 'NUMBER') THEN TRY_CAST(r.field_value AS DECIMAL(38,15)) END AS value
    FROM uat_iss_ods.flat_report r
    CROSS JOIN params p
    WHERE r.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
      AND r.submit_source = 'ICP'
      AND r.report_code = 'HNX09'
      AND r.sheet_name = 'sheet 1'
      AND r.column_path = 'GIÁ TRỊ'
      AND r.row_path IN ('GIÁ TRỊ GIAO DỊCH',
                         'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA', 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN',
                         'GIÁ TRỊ GIAO DỊCH CỦA KHỐI TỰ DOANH - GIÁ TRỊ MUA', 'GIÁ TRỊ GIAO DỊCH CỦA KHỐI TỰ DOANH - GIÁ TRỊ BÁN')
      AND r.date_type = 'DAILY'
      AND MAKE_DATE(r.report_year, r.report_month, r.report_day) BETWEEN p.ytd_from AND p.to_date
      AND r.ds_snpst_dt = '2026-10-22'
  ) f
  GROUP BY f.report_date
)
-- =========================
-- 3. GỘP 3 NGUỒN GIAO DỊCH (Ngày x Mã; TPCP, TPDNRL: Ngày)
, trade_daily AS (
  SELECT 
    trade_date, market_id, symbol,
    klgd, gtgd, klgd_khoplenh, gtgd_khoplenh, klgd_thoathuan, gtgd_thoathuan,
    klgd_ndtnn_mua, klgd_ndtnn_ban, gtgd_ndtnn_mua, gtgd_ndtnn_ban,
    klgd_tudoanh_mua, klgd_tudoanh_ban, gtgd_tudoanh_mua, gtgd_tudoanh_ban
  FROM stock_trade_daily
  UNION ALL
  SELECT 
    trade_date, market_id, symbol,
    klgd, gtgd, NULL klgd_khoplenh, NULL gtgd_khoplenh, NULL klgd_thoathuan, NULL gtgd_thoathuan,
    klgd_ndtnn_mua, klgd_ndtnn_ban, gtgd_ndtnn_mua, gtgd_ndtnn_ban,
    klgd_tudoanh_mua, klgd_tudoanh_ban, gtgd_tudoanh_mua, gtgd_tudoanh_ban
  FROM govbond_trade_daily
  UNION ALL
  SELECT 
    trade_date, market_id, symbol,
    NULL klgd, gtgd, NULL klgd_khoplenh, NULL gtgd_khoplenh, NULL klgd_thoathuan, NULL gtgd_thoathuan,
    NULL klgd_ndtnn_mua, NULL klgd_ndtnn_ban, gtgd_ndtnn_mua, gtgd_ndtnn_ban,
    NULL klgd_tudoanh_mua, NULL klgd_tudoanh_ban, gtgd_tudoanh_mua, gtgd_tudoanh_ban
  FROM corpbond_trade_daily
)
-- 3.1. Phiên giao dịch của thị trường, theo từng ngày:
----   so_phien_ky  = số phiên từ đầu kỳ đến ngày; so_phien_ytd = số phiên từ đầu năm đến ngày; is_period_end = Xác định phiên cuối kỳ
, sessions AS (
  SELECT 
    trade_date,
    period_code,
    ROW_NUMBER() OVER(PARTITION BY period_code ORDER BY trade_date) AS so_phien_ky,
    ROW_NUMBER() OVER(PARTITION BY YEAR(trade_date) ORDER BY trade_date) AS so_phien_ytd,
    IF(trade_date = MAX(trade_date) OVER(PARTITION BY period_code), 'Y', 'N') AS is_period_end -- Kỳ hiện tại: phiên có dữ liệu gần nhất
  FROM (
    SELECT 
      d.trade_date,
      CASE p.period_type
        WHEN 'D' THEN DATE_FORMAT(d.trade_date, 'yyyy-MM-dd')
        WHEN 'M' THEN DATE_FORMAT(d.trade_date, 'yyyy-MM')
        WHEN 'Q' THEN CONCAT(YEAR(d.trade_date), '-Q', QUARTER(d.trade_date))
        WHEN 'Y' THEN CAST(YEAR(d.trade_date) AS STRING)
      END AS period_code
    FROM (SELECT DISTINCT trade_date FROM stock_trade_daily) d
    CROSS JOIN params p
  )
)
-- =========================
-- 4. GIAO DỊCH THEO KỲ x CHIỀU x MÃ
, trade_period AS (
  SELECT
    ss.period_code,
    -- Sàn: theo floorcode jad_stockinfor, không có thì lấy theo market_id của giao dịch
    COALESCE(MAP('10','HOSE', '02','HNX', '04','UPCOM', '03','PHÁI SINH')[s.floorcode],
             MAP('STK','HOSE', 'STO','HOSE', 'STX','HNX', 'HCX','HNX', 'DVX','PHÁI SINH', 'UPX','UPCOM', 'TPCP','HNX', 'TPDNRL','HNX')[t.market_id]) AS san,
    i.index_codes,
    CASE WHEN t.market_id IN ('TPCP', 'TPDNRL') THEN t.market_id ELSE s.loai_ck END AS loai_ck,
    s.derivative_product, s.derivative_product_detail, s.derivative_term,
    s.industry_cd, s.industry_name,
    t.symbol,
    SUM(t.klgd) AS klgd,
    SUM(t.gtgd) AS gtgd,
    SUM(t.klgd_khoplenh) AS klgd_khoplenh,
    SUM(t.gtgd_khoplenh) AS gtgd_khoplenh,
    SUM(t.klgd_thoathuan) AS klgd_thoathuan,
    SUM(t.gtgd_thoathuan) AS gtgd_thoathuan,
    SUM(t.klgd_ndtnn_mua) AS klgd_ndtnn_mua,
    SUM(t.klgd_ndtnn_ban) AS klgd_ndtnn_ban,
    SUM(t.gtgd_ndtnn_mua) AS gtgd_ndtnn_mua,
    SUM(t.gtgd_ndtnn_ban) AS gtgd_ndtnn_ban,
    SUM(t.klgd_tudoanh_mua) AS klgd_tudoanh_mua,
    SUM(t.klgd_tudoanh_ban) AS klgd_tudoanh_ban,
    SUM(t.gtgd_tudoanh_mua) AS gtgd_tudoanh_mua,
    SUM(t.gtgd_tudoanh_ban) AS gtgd_tudoanh_ban
  FROM trade_daily t
  JOIN sessions ss ON ss.trade_date = t.trade_date
  LEFT JOIN stock_eod s ON s.symbol = t.symbol AND s.tradingdate = t.trade_date
  LEFT JOIN stock_index i ON i.symbol = t.symbol AND i.tradingdate = t.trade_date
  GROUP BY ALL -- Gom theo toàn bộ cột không tổng hợp trong SELECT (Spark 3.4+), không phụ thuộc thứ tự cột
)
-- =========================
-- 5. KẾT QUẢ: Kỳ x Chiều x Mã (giao dịch + TPDNNY tại phiên cuối kỳ)
, result AS (
  SELECT 
    period_code, san, index_codes, industry_cd, industry_name, loai_ck, 
    derivative_product, derivative_product_detail, derivative_term, symbol,
    SUM(klgd) AS klgd, SUM(gtgd) AS gtgd,
    SUM(klgd_khoplenh) AS klgd_khoplenh, SUM(gtgd_khoplenh) AS gtgd_khoplenh,
    SUM(klgd_thoathuan) AS klgd_thoathuan, SUM(gtgd_thoathuan) AS gtgd_thoathuan,
    SUM(klgd_ndtnn_mua) AS klgd_ndtnn_mua, SUM(klgd_ndtnn_ban) AS klgd_ndtnn_ban,
    SUM(gtgd_ndtnn_mua) AS gtgd_ndtnn_mua, SUM(gtgd_ndtnn_ban) AS gtgd_ndtnn_ban,
    SUM(klgd_tudoanh_mua) AS klgd_tudoanh_mua, SUM(klgd_tudoanh_ban) AS klgd_tudoanh_ban,
    SUM(gtgd_tudoanh_mua) AS gtgd_tudoanh_mua, SUM(gtgd_tudoanh_ban) AS gtgd_tudoanh_ban,
    SUM(duno) AS duno, SUM(duno_x_kyhan) AS duno_x_kyhan, SUM(duno_x_ytm) AS duno_x_ytm,
    ANY_VALUE(closeprice, TRUE) AS closeprice, ANY_VALUE(open_interest_volume, TRUE) AS oi,
  FROM (
    SELECT 
      period_code, san, index_codes, industry_cd, industry_name, loai_ck, 
      derivative_product, derivative_product_detail, derivative_term, symbol,
      klgd, gtgd, klgd_khoplenh, gtgd_khoplenh, klgd_thoathuan, gtgd_thoathuan,
      klgd_ndtnn_mua, klgd_ndtnn_ban, gtgd_ndtnn_mua, gtgd_ndtnn_ban,
      klgd_tudoanh_mua, klgd_tudoanh_ban, gtgd_tudoanh_mua, gtgd_tudoanh_ban,
      NULL AS duno, NULL AS duno_x_kyhan, NULL AS duno_x_ytm, 
      NULL AS closeprice, NULL AS open_interest_volume
    FROM trade_period
    UNION ALL
    -- TPDNNY tại phiên cuối kỳ: toàn bộ mã có bản ghi jad_stockinfor ngày đó (kể cả mã không GD)
    SELECT 
      ss.period_code, 
      MAP('10','HOSE', '02','HNX', '03','HNX', '04','UPCOM')[s.floorcode] AS san, 
      i.index_codes, s.industry_cd, s.industry_name, s.loai_ck, 
      NULL, NULL, NULL, s.symbol,
      NULL, NULL, NULL, NULL, NULL, NULL,
      NULL, NULL, NULL, NULL,
      NULL, NULL, NULL, NULL,
      s.duno, s.duno_x_kyhan, s.duno_x_ytm,
      s.closeprice, s.open_interest_volume
    FROM stock_eod s
    LEFT JOIN oi_eod oi ON oi.report_code = s.trading_date AND oi.contract_code = s.symbol 
    JOIN sessions ss ON ss.trade_date = s.tradingdate AND ss.is_period_end = 'Y'
    LEFT JOIN stock_index i ON i.symbol = s.symbol AND i.tradingdate = s.tradingdate
    WHERE s.duno > 0
  )
  GROUP BY 
    period_code, san, index_codes, industry_cd, industry_name, loai_ck, 
    derivative_product, derivative_product_detail, derivative_term, symbol
)
SELECT
  p.period_type,
  r.period_code, -- Kỳ
  pi.trade_date AS period_enddate, -- Phiên cuối kỳ
  pi.trade_date >= p.from_date AS in_range, -- Kỳ trong khoảng Từ kỳ - Đến kỳ (kỳ trước đó chỉ dùng tính YTD)
  r.san, -- Sàn
  r.index_codes, -- Chỉ số Index (mảng) - lọc bằng array_contains(index_codes, '<indexcode>')
  r.industry_cd, r.industry_name, -- Ngành
  r.loai_ck, -- Loại chứng khoán
  r.derivative_product, r.derivative_product_detail, -- Sản phẩm phái sinh
  r.derivative_term, -- Kỳ hạn phái sinh
  r.symbol, -- Mã chứng khoán
  -- Giao dịch trong kỳ
  r.klgd, r.gtgd,
  r.klgd_khoplenh, r.gtgd_khoplenh, r.klgd_thoathuan, r.gtgd_thoathuan,
  r.klgd_ndtnn_mua, r.klgd_ndtnn_ban, r.klgd_ndtnn_mua - r.klgd_ndtnn_ban AS klgd_ndtnn_rong,
  r.gtgd_ndtnn_mua, r.gtgd_ndtnn_ban, r.gtgd_ndtnn_mua - r.gtgd_ndtnn_ban AS gtgd_ndtnn_rong,
  r.klgd_tudoanh_mua, r.klgd_tudoanh_ban, r.klgd_tudoanh_mua - r.klgd_tudoanh_ban AS klgd_tudoanh_rong,
  r.gtgd_tudoanh_mua, r.gtgd_tudoanh_ban, r.gtgd_tudoanh_mua - r.gtgd_tudoanh_ban AS gtgd_tudoanh_rong,
  -- GTGD bình quân/phiên: của kỳ = SUM(gtgd) / so_phien_ky (kỳ D: không tính); YTD = SUM(gtgd từ đầu năm) / so_phien_ytd (cộng dồn sau khi gom nhóm)
  pi.so_phien_ky,  -- Số phiên của kỳ (tại phiên cuối kỳ)
  pi.so_phien_ytd, -- Số phiên từ đầu năm đến phiên cuối kỳ
  IF(p.period_type = 'D', NULL, r.gtgd / pi.so_phien_ky) AS gtgd_bq_phien_ky,
  -- TPDNNY tại phiên cuối kỳ: Kỳ hạn còn lại BQ = SUM(duno_x_kyhan) / SUM(duno); YTM BQ = SUM(duno_x_ytm) / SUM(duno)
  r.duno, r.duno_x_kyhan, r.duno_x_ytm, 
  r.duno_x_kyhan / NULLIF(r.duno, 0) AS tp_kyhan_bq,
  r.duno_x_ytm / NULLIF(r.duno, 0) AS tp_ytm_bq
FROM result r
JOIN sessions pi ON pi.period_code = r.period_code AND pi.is_period_end = 'Y'
CROSS JOIN params p
ORDER BY r.period_code, r.san, r.loai_ck, r.symbol
;