-- VP02 - BÁO CÁO TÌNH HÌNH THỊ TRƯỜNG CHỨNG KHOÁN: TÍNH TẠI 1 NGÀY BÁO CÁO
/* Tham số tra cứu:
 * :report_date  Ngày báo cáo (yyyy-MM-dd)
 * Nhóm: 1. Thị trường cổ phiếu | 2. Thị trường trái phiếu | 3.1. Phái sinh (HĐTL VN30) | 3.2. Chứng quyền | 4. NĐTNN
 * Quy tắc tính:
 *  - Ngày dữ liệu (d_cur) = ngày giao dịch gần nhất <= ngày báo cáo; cuối tháng trước (d_pm), cuối năm trước (d_py) = ngày giao dịch cuối cùng <= 31 của tháng/năm trước.
 *  - Lịch ngày giao dịch lấy từ sổ lệnh HNX trade_book + mdds
 *  - Bình quân tháng/năm = Tổng giá trị (khối lượng) / số phiên giao dịch của thị trường trong kỳ.
 *      + Tháng báo cáo: từ ngày 01 của tháng đến ngày báo cáo; so sánh với CẢ THÁNG TRƯỚC và CẢ THÁNG CÙNG KỲ NĂM TRƯỚC (01 đến cuối tháng).
 *      + Năm báo cáo: từ 01/01 đến ngày báo cáo; so sánh với CẢ NĂM TRƯỚC (01/01 - 31/12).
 *  - Phân loại CK: bản ghi cuối ngày của jad_stockinfor (stocktype 1 = TPDNNY, 2 = CP, 3/6 = CCQ, floorcode 10 + stocktype 4 = CW, floorcode 03 + stocktype 4 + underlyingsymbol VN30 = HĐTL VN30).
 *  - NĐTNN: SUBSTR(số tài khoản, 4, 1) IN ('E','F').
 *  - Giá trị tiền tệ tính bằng VND (chia 1e9 ở frontend để hiển thị tỷ đồng).
 */
WITH
-- 1. Tham số -> Lấy ra các mốc thời gian
-- 1.1. Ngày báo cáo -> các mốc tháng, năm
params AS (
  SELECT
    report_date,
    month_start,
    ADD_MONTHS(month_start, -1) AS pm_start, -- Ngày đầu tháng trước
    DATE_SUB(month_start, 1) AS pm_end, -- Ngày cuối tháng trước
    year_start,
    ADD_MONTHS(year_start, -12) AS py_start, -- Ngày đầu năm trước
    DATE_SUB(year_start, 1) AS py_end, -- Ngày cuối năm trước
    ADD_MONTHS(month_start, -12) AS lym_start, -- Ngày đầu tháng cùng kỳ năm trước (cùng tháng của năm trước)
    LAST_DAY(ADD_MONTHS(month_start, -12)) AS lym_end, -- Ngày cuối tháng cùng kỳ năm trước
    YEAR(report_date) - 1 AS gdp_year -- Năm lấy GDP
  FROM (
    SELECT
      CAST(:report_date AS DATE) AS report_date,
      CAST(DATE_TRUNC('MONTH', :report_date) AS DATE) AS month_start, -- Ngày đầu tháng
      CAST(DATE_TRUNC('YEAR', :report_date) AS DATE) AS year_start -- Ngày đầu năm
  )
)
-- 1.2. Lịch ngày giao dịch
----  Cần lấy thêm ngày giao dịch liền sau ngày BC (dùng để lấy VWAP tính vốn hóa UPCOM)
, cal AS (
  SELECT DISTINCT TO_DATE(h.trade_date, 'yyyyMMdd') AS tradingdate
  FROM uat_hnx_stg.trade_book h
  CROSS JOIN params p
  WHERE h.trade_date >= DATE_FORMAT(p.py_start, 'yyyyMMdd')
    AND h.trade_date <= DATE_FORMAT(ADD_MONTHS(p.report_date, 1), 'yyyyMMdd')
  UNION  
  SELECT DISTINCT m.tradingdate
  FROM uat_mdds_stg.jad_marketinfor m
  CROSS JOIN params p
  WHERE m.tradingdate >= p.py_start AND m.tradingdate <= ADD_MONTHS(p.report_date, 1)
)
-- 1.3. Các ngày dữ liệu cần lấy + số phiên giao dịch từng kỳ
----> Ngày tính niêm yết, vốn hóa: lấy ngày giao dịch từ lịch cal (d_cur, d_py) và ngày liền sau (d_next, d_py_next)
, key_dates AS (
  SELECT
    p.report_date,
    MAX(CASE WHEN c.tradingdate <= p.report_date THEN c.tradingdate END) AS d_cur, -- Ngày dữ liệu gần nhất <= ngày báo cáo
    MIN(CASE WHEN c.tradingdate > p.report_date THEN c.tradingdate END) AS d_next, -- Ngày giao dịch liền sau ngày báo cáo (NULL nếu ngày báo cáo là ngày giao dịch mới nhất)
    MAX(CASE WHEN c.tradingdate <= p.pm_end THEN c.tradingdate END) AS d_pm, -- Ngày giao dịch cuối tháng trước
    MAX(CASE WHEN c.tradingdate <= p.py_end THEN c.tradingdate END) AS d_py, -- Ngày giao dịch cuối năm trước
    MIN(CASE WHEN c.tradingdate > p.py_end THEN c.tradingdate END) AS d_py_next, -- Ngày giao dịch liền sau cuối năm trước (chứa VWAP của d_py)
    SUM(CASE WHEN c.tradingdate BETWEEN p.month_start AND p.report_date THEN 1 ELSE 0 END) AS n_m, -- Số phiên tháng báo cáo
    SUM(CASE WHEN c.tradingdate BETWEEN p.pm_start AND p.pm_end THEN 1 ELSE 0 END) AS n_pm, -- Số phiên tháng trước
    SUM(CASE WHEN c.tradingdate BETWEEN p.lym_start AND p.lym_end THEN 1 ELSE 0 END) AS n_lym, -- Số phiên tháng cùng kỳ năm trước
    SUM(CASE WHEN c.tradingdate BETWEEN p.year_start AND p.report_date THEN 1 ELSE 0 END) AS n_y, -- Số phiên năm báo cáo (YTD)
    SUM(CASE WHEN c.tradingdate BETWEEN p.py_start AND p.py_end THEN 1 ELSE 0 END) AS n_py -- Số phiên năm trước
  FROM cal c
  CROSS JOIN params p
  GROUP BY p.report_date
)
-- 2.1. Chỉ số VN-Index, HNX-Index: Lấy bản ghi cuối ngày tại ngày báo cáo, cuối tháng trước, cuối năm trước
, index_eod AS (
  SELECT marketcode, tradingdate, marketindex
  FROM (
    SELECT
      m.marketcode, m.tradingdate, m.marketindex,
      ROW_NUMBER() OVER(PARTITION BY m.marketcode, m.tradingdate ORDER BY m.indextime DESC, m.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_marketinfor m
    CROSS JOIN key_dates k
    WHERE m.marketcode IN ('HOSE', 'HNX') -- HOSE = VN-Index, HNX = HNX-Index
      AND m.tradingdate IN (k.d_cur, k.d_pm, k.d_py)
  )
  WHERE rn = 1
)
----> Xoay dữ liệu chỉ số từ hàng thành cột
, idx AS (
  SELECT
    MAX(CASE WHEN i.marketcode = 'HOSE' AND i.tradingdate = k.d_cur THEN i.marketindex END) AS vnindex_cur,
    MAX(CASE WHEN i.marketcode = 'HOSE' AND i.tradingdate = k.d_pm THEN i.marketindex END) AS vnindex_pm,
    MAX(CASE WHEN i.marketcode = 'HOSE' AND i.tradingdate = k.d_py THEN i.marketindex END) AS vnindex_py,
    MAX(CASE WHEN i.marketcode = 'HNX' AND i.tradingdate = k.d_cur THEN i.marketindex END) AS hnxindex_cur,
    MAX(CASE WHEN i.marketcode = 'HNX' AND i.tradingdate = k.d_pm THEN i.marketindex END) AS hnxindex_pm,
    MAX(CASE WHEN i.marketcode = 'HNX' AND i.tradingdate = k.d_py THEN i.marketindex END) AS hnxindex_py
  FROM index_eod i
  CROSS JOIN key_dates k
)
-- 2.2. Danh sách mã chứng khoán: lấy bản ghi cuối ngày trong jad_stockinfor, thời gian từ đầu năm trước đến ngày giao dịch liền sau ngày báo cáo
, stock_eod AS (
  SELECT
    tradingdate, symbol, symbolisin, floorcode, stocktype, closeprice, vwap, reference, contractmultiplier,
    CASE
      WHEN stocktype = '1' THEN 'TPDNNY' -- TPDN niêm yết
      WHEN stocktype = '2' THEN 'CP' -- Cổ phiếu
      WHEN stocktype IN ('3', '6') THEN 'CCQ' -- Chứng chỉ quỹ (gồm ETF)
      WHEN floorcode = '10' AND stocktype = '4' THEN 'CW' -- Chứng quyền
      WHEN floorcode = '03' AND stocktype = '4' AND underlyingsymbol = 'VN30' THEN 'HDTL_VN30' -- Phái sinh - HĐTL VN30
      WHEN floorcode = '03' AND stocktype = '4' AND underlyingsymbol = 'VN100' THEN 'HDTL_VN100' -- Phái sinh - HĐTL VN100
      WHEN floorcode = '03' AND stocktype = '4' AND productgrpid = 'FBX' THEN 'HDTL_TPCP' -- Phái sinh - HĐTL TPCP
    END AS loai_ck -- Phân loại chứng khoán
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.symbolisin, s.floorcode, s.stocktype, s.underlyingsymbol, s.productgrpid, CAST(s.contractmultiplier AS DOUBLE) contractmultiplier,
      s.closeprice, s.vwap, s.reference,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN params p
    CROSS JOIN key_dates kd
    WHERE s.tradingdate BETWEEN p.py_start AND COALESCE(kd.d_next, p.report_date) -- Đến ngày giao dịch liền sau ngày báo cáo (nếu chưa có thì đến ngày báo cáo)
  )
  WHERE rn = 1 -- Bản ghi cuối mỗi ngày
)
----> Lấy danh sách chứng khoán với thông tin master data
, stock_list AS (
  SELECT symbol, symbolisin, loai_ck, contractmultiplier
  FROM (
    SELECT
      symbol, symbolisin, loai_ck, contractmultiplier,
      ROW_NUMBER() OVER (PARTITION BY symbol ORDER BY tradingdate DESC) rn
    FROM stock_eod
  ) 
  WHERE rn = 1
)
-- 2.3. Chỉ tiêu Giao dịch
---- Tổng giao dịch theo loại CK x kỳ: tháng báo cáo (m), tháng trước (pm), tháng cùng kỳ năm trước (lym), năm báo cáo đến ngày báo cáo (y), năm trước (py)
---- gt = GTGD, kl = KLGD, ndtnn_rong = GT NĐTNN mua - bán (chỉ tính của tháng, năm báo cáo)
, trade_period AS (
  -- 2.3.1. HOSE: Cổ phiếu, CCQ, Chứng quyền
  SELECT /*+ BROADCAST(s) */
    s.loai_ck,
    SUM(CASE WHEN h.trade_date BETWEEN p.month_start AND p.report_date THEN h.execution_value ELSE 0 END) AS gt_m,
    SUM(CASE WHEN h.trade_date BETWEEN p.pm_start AND p.pm_end THEN h.execution_value ELSE 0 END) AS gt_pm,
    SUM(CASE WHEN h.trade_date BETWEEN p.lym_start AND p.lym_end THEN h.execution_value ELSE 0 END) AS gt_lym,
    SUM(CASE WHEN h.trade_date BETWEEN p.year_start AND p.report_date THEN h.execution_value ELSE 0 END) AS gt_y,
    SUM(CASE WHEN h.trade_date BETWEEN p.py_start AND p.py_end THEN h.execution_value ELSE 0 END) AS gt_py,
    SUM(CASE WHEN h.trade_date BETWEEN p.month_start AND p.report_date THEN h.execution_volume ELSE 0 END) AS kl_m,
    SUM(CASE WHEN h.trade_date BETWEEN p.pm_start AND p.pm_end THEN h.execution_volume ELSE 0 END) AS kl_pm,
    SUM(CASE WHEN h.trade_date BETWEEN p.lym_start AND p.lym_end THEN h.execution_volume ELSE 0 END) AS kl_lym,
    SUM(CASE WHEN h.trade_date BETWEEN p.year_start AND p.report_date THEN h.execution_volume ELSE 0 END) AS kl_y,
    SUM(CASE WHEN h.trade_date BETWEEN p.py_start AND p.py_end THEN h.execution_volume ELSE 0 END) AS kl_py,
    SUM(CASE WHEN h.trade_date BETWEEN p.month_start AND p.report_date 
      THEN (CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) 
            - (CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) 
      ELSE 0 
    END) AS ndtnn_rong_m,
    SUM(CASE WHEN h.trade_date BETWEEN p.year_start AND p.report_date 
      THEN (CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) 
            - (CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) 
      ELSE 0 
    END) AS ndtnn_rong_y
  FROM uat_hose_stg.trade_book h
  JOIN stock_list s ON h.symbol = s.symbol
  CROSS JOIN params p
  WHERE h.market_id = 'STK'
    AND h.trade_date BETWEEN p.py_start AND p.report_date
    --AND s.loai_ck IN ('CP', 'CCQ', 'CW')
  GROUP BY s.loai_ck
  UNION ALL
  -- 2.3.2. HNX + UPCoM: Cổ phiếu, CCQ, TPDN niêm yết (HCX), HĐTL VN30 (DVX); join với stock_list theo mã ISIN
  ---- Nếu là Phái sinh (DVX) có hệ số nhân contractmultiplier <> 1, loại khác = 1 (lấy nvl để tránh trường hợp bị lỗi giá trị s.contractmultiplier null)
  SELECT /*+ BROADCAST(s) */
    s.loai_ck,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.month_start, 'yyyyMMdd') AND DATE_FORMAT(p.report_date, 'yyyyMMdd') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier, 1) ELSE 0 END) AS gt_m,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.pm_start, 'yyyyMMdd') AND DATE_FORMAT(p.pm_end, 'yyyyMMdd') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier, 1) ELSE 0 END) AS gt_pm,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.lym_start, 'yyyyMMdd') AND DATE_FORMAT(p.lym_end, 'yyyyMMdd') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier, 1) ELSE 0 END) AS gt_lym,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.year_start, 'yyyyMMdd') AND DATE_FORMAT(p.report_date, 'yyyyMMdd') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier, 1) ELSE 0 END) AS gt_y,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.py_start, 'yyyyMMdd') AND DATE_FORMAT(p.py_end, 'yyyyMMdd') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier, 1) ELSE 0 END) AS gt_py,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.month_start, 'yyyyMMdd') AND DATE_FORMAT(p.report_date, 'yyyyMMdd') THEN h.trade_quantity ELSE 0 END) AS kl_m,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.pm_start, 'yyyyMMdd') AND DATE_FORMAT(p.pm_end, 'yyyyMMdd') THEN h.trade_quantity ELSE 0 END) AS kl_pm,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.lym_start, 'yyyyMMdd') AND DATE_FORMAT(p.lym_end, 'yyyyMMdd') THEN h.trade_quantity ELSE 0 END) AS kl_lym,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.year_start, 'yyyyMMdd') AND DATE_FORMAT(p.report_date, 'yyyyMMdd') THEN h.trade_quantity ELSE 0 END) AS kl_y,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.py_start, 'yyyyMMdd') AND DATE_FORMAT(p.py_end, 'yyyyMMdd') THEN h.trade_quantity ELSE 0 END) AS kl_py,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.month_start, 'yyyyMMdd') AND DATE_FORMAT(p.report_date, 'yyyyMMdd') 
      THEN (CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier, 1) ELSE 0 END) 
            - (CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier, 1) ELSE 0 END) 
      ELSE 0 
    END) AS ndtnn_rong_m,
    SUM(CASE WHEN h.trade_date BETWEEN DATE_FORMAT(p.year_start, 'yyyyMMdd') AND DATE_FORMAT(p.report_date, 'yyyyMMdd') 
      THEN (CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier, 1) ELSE 0 END) 
            - (CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price * NVL(s.contractmultiplier, 1) ELSE 0 END) 
      ELSE 0 
    END) AS ndtnn_rong_y
  FROM uat_hnx_stg.trade_book h
  JOIN stock_list s ON h.issue_code = s.symbolisin
  CROSS JOIN params p
  WHERE h.market_id IN ('STX', 'UPX', 'HCX', 'DVX')
    AND h.trade_date BETWEEN DATE_FORMAT(p.py_start, 'yyyyMMdd') AND DATE_FORMAT(p.report_date, 'yyyyMMdd')
    --AND s.loai_ck IN ('CP', 'CCQ', 'TPDNNY', 'HDTL_VN30')
  GROUP BY s.loai_ck
)
-- Chuyển loại CK thành cột
, trade_agg AS (
  SELECT
    SUM(CASE WHEN d.loai_ck = 'CP' THEN d.gt_m ELSE 0 END) AS cp_gt_m,
    SUM(CASE WHEN d.loai_ck = 'CP' THEN d.gt_pm ELSE 0 END) AS cp_gt_pm,
    SUM(CASE WHEN d.loai_ck = 'CP' THEN d.gt_lym ELSE 0 END) AS cp_gt_lym,
    SUM(CASE WHEN d.loai_ck = 'CP' THEN d.gt_y ELSE 0 END) AS cp_gt_y,
    SUM(CASE WHEN d.loai_ck = 'CP' THEN d.gt_py ELSE 0 END) AS cp_gt_py,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' THEN d.gt_m ELSE 0 END) AS tp_gt_m,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' THEN d.gt_pm ELSE 0 END) AS tp_gt_pm,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' THEN d.gt_lym ELSE 0 END) AS tp_gt_lym,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' THEN d.gt_y ELSE 0 END) AS tp_gt_y,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' THEN d.gt_py ELSE 0 END) AS tp_gt_py,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_m ELSE 0 END) AS cw_gt_m,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_m ELSE 0 END) AS cw_kl_m,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_pm ELSE 0 END) AS cw_gt_pm,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_pm ELSE 0 END) AS cw_kl_pm,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_lym ELSE 0 END) AS cw_gt_lym,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_lym ELSE 0 END) AS cw_kl_lym,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_y ELSE 0 END) AS cw_gt_y,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_y ELSE 0 END) AS cw_kl_y,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_py ELSE 0 END) AS cw_gt_py,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_py ELSE 0 END) AS cw_kl_py,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_m ELSE 0 END) AS ps_kl_m,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_pm ELSE 0 END) AS ps_kl_pm,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_lym ELSE 0 END) AS ps_kl_lym,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_y ELSE 0 END) AS ps_kl_y,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_py ELSE 0 END) AS ps_kl_py,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') THEN d.ndtnn_rong_m ELSE 0 END) AS ndtnn_rong_cq_ccq_m,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' THEN d.ndtnn_rong_m ELSE 0 END) AS ndtnn_rong_tpdnny_m,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') THEN d.ndtnn_rong_y ELSE 0 END) AS ndtnn_rong_cp_ccq_y,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' THEN d.ndtnn_rong_y ELSE 0 END) AS ndtnn_rong_tpdnny_y
  FROM trade_period d
)
-- 2.4. Chỉ tiêu vốn hóa, số mã niêm yết/ĐKGD
---- Cổ phiếu, CCQ niêm yết/ĐKGD tại ngày dữ liệu d_cur (CUR) và cuối năm trước (PY): KL lưu hành, Số mã NY/ĐKGD
---- HOSE, HNX (floorcode 02, 10): Giá đóng cửa
---- UPCoM (floorcode 04): Giá trung bình (VWAP) ngày T được Sở gửi trong tín hiệu MDDS (d - security definition) ngày T+1; nếu VWAP = 0 (mã trắng thanh khoản) thì lấy giá tham chiếu ngày T
---- Nếu ngày BC là ngày giao dịch mới nhất thì CHƯA có số liệu vốn hóa UPCoM (NULL)
, equity_data AS (
  SELECT
    x.pt, x.tradingdate, x.symbol, x.floorcode, x.stocktype, x.loai_ck, x.price, x.closeprice, x.reference, x.d_next, x.vwap,
    os.outstanding_shares AS kllh_cp,
    ls.outstanding_shares AS kllh_tpdnny,
    CASE WHEN x.stocktype = '2' THEN x.price * os.outstanding_shares END AS von_hoa_cophieu, -- Vốn hóa (cổ phiếu)
    -- GT niêm yết = KL lưu hành x Mệnh giá (CP/CCQ 10000vnd, TPDN niêm yết tính ngược từ giá tham chiếu (bội số của 100.000, nhảy bậc x10))
    CASE 
      WHEN x.stocktype IN ('2','3','6') THEN os.outstanding_shares * 10000 
      WHEN x.stocktype = '1' THEN ls.outstanding_shares * ( 100000 * POWER(10, ROUND(LN(NULLIF(CAST(x.reference AS DOUBLE), 0) / 100000) / LN(10))) )
    END AS gt_niemyet
  FROM (
    SELECT -- Kỳ báo cáo
      'CUR' AS pt, s.tradingdate, s.symbol, s.floorcode, s.stocktype, s.loai_ck,
      CASE 
        WHEN s.floorcode = '04' THEN 
          (CASE 
            WHEN n.vwap IS NULL THEN NULL -- VWAP mã trên UPCoM chưa có dữ liệu T+1 → không tính vốn hóa UPCoM
            ELSE COALESCE(NULLIF(n.vwap, 0), s.reference) -- VWAP = 0 (mã trắng thanh khoản) --> lấy tham chiếu ngày T
          END)
        ELSE s.closeprice 
      END AS price,
      s.closeprice, s.reference,
      k.d_next, n.vwap
    FROM stock_eod s
    CROSS JOIN key_dates k
    LEFT JOIN stock_eod n ON n.symbol = s.symbol AND n.tradingdate = k.d_next -- Lấy giá VWAP ngày T Sở gửi ngày T+1 để tính vốn hóa upcom
    WHERE s.tradingdate = k.d_cur
      AND s.floorcode IN ('02','04','10') AND s.stocktype IN ('1', '2', '3', '6') -- TPDNNY, CP, CCQ
    UNION ALL
    SELECT -- Năm trước
      'PY' AS pt, s.tradingdate, s.symbol, s.floorcode, s.stocktype, s.loai_ck,
      CASE 
        WHEN s.floorcode = '04' THEN 
          (CASE 
            WHEN n.vwap IS NULL THEN NULL -- VWAP mã trên UPCoM chưa có dữ liệu T+1 → không tính vốn hóa UPCoM
            ELSE COALESCE(NULLIF(n.vwap, 0), s.reference) -- VWAP = 0 (mã trắng thanh khoản) --> lấy tham chiếu ngày T
          END)
        ELSE s.closeprice END AS price,
      s.closeprice, s.reference,
      k.d_py_next, n.vwap
    FROM stock_eod s
    CROSS JOIN key_dates k
    LEFT JOIN stock_eod n ON n.symbol = s.symbol AND n.tradingdate = k.d_py_next -- Lấy giá VWAP ngày T Sở gửi ngày T+1 để tính vốn hóa upcom
    WHERE s.tradingdate = k.d_py
      AND s.floorcode IN ('02','04','10') AND s.stocktype IN ('1', '2', '3', '6') -- TPDNNY, CP, CCQ
  ) x
  LEFT JOIN uat_vsdc_stg.outstanding_shares os ON os.transaction_date = x.tradingdate AND os.ticker_symbol = x.symbol -- Khối lượng lưu hành CP/CCQ cuối ngày để tính vốn hóa
  LEFT JOIN uat_hnx_stg.listed_securities_list ls ON ls.report_date = x.tradingdate AND ls.ticker_symbol = x.symbol -- Khối lượng lưu hành TPDNNY
)
-- Tính vốn hóa, GT niêm yết, Số mã NY/ĐKGD
, equity_agg AS (
  SELECT
    pt,
    SUM(von_hoa_cophieu) AS von_hoa_cophieu, 
    SUM(CASE WHEN stocktype IN ('2', '3', '6') THEN gt_niemyet ELSE 0 END) AS gt_niemyet_cp_ccq,
    COUNT(CASE WHEN floorcode IN ('02', '10') AND stocktype IN ('2', '3', '6') THEN symbol END) AS so_ma_cp_ccq_hnx_hose, -- CP, CCQ niêm yết HNX, HOSE
    COUNT(CASE WHEN floorcode = '04' AND stocktype = '2' THEN symbol END) AS so_ma_cp_upcom, -- CP ĐKGD UPCoM
    SUM(CASE WHEN stocktype = '1' THEN gt_niemyet ELSE 0 END) AS gt_niemyet_tpdnny,
    COUNT(CASE WHEN stocktype = '1' THEN symbol END) AS so_ma_tpdnny
  FROM equity_data
  GROUP BY pt
)
-- 2.5. Khối lượng mở (OI) HĐTL VN30: Tại d_cur, cuối tháng trước, cuối năm trước
, oi AS (
  SELECT
    SUM(CASE WHEN o.report_date = k.d_cur THEN o.open_interest_volume END) AS oi_cur,
    SUM(CASE WHEN o.report_date = k.d_pm THEN o.open_interest_volume END) AS oi_pm,
    SUM(CASE WHEN o.report_date = k.d_py THEN o.open_interest_volume END) AS oi_py
  FROM uat_vsdc_stg.end_of_day_open_interest o
  CROSS JOIN key_dates k
  JOIN stock_eod s ON o.report_date = s.tradingdate AND o.contract_code = s.symbol AND s.loai_ck = 'HDTL_VN30'
  WHERE o.report_date IN (k.d_cur, k.d_pm, k.d_py)
)
-- 2.6. GDP năm trước (năm báo cáo - 1)
---- Quy đổi về VND: unit_code 3 = Tỷ VND, 8 = VND, 23 = Triệu VND
---- Nếu không có GDP năm thì lấy tổng GDP quý
, gdp AS (
  SELECT period_year, gdp_py
  FROM (
    SELECT
      v.period_type,
      v.period_year,
      SUM(CASE v.unit_code
        WHEN '3' THEN TRY_CAST(v.value AS DOUBLE) * 1000000000
        WHEN '8' THEN TRY_CAST(v.value AS DOUBLE)
        WHEN '23' THEN TRY_CAST(v.value AS DOUBLE) * 1000000
      END) AS gdp_py,
      COUNT(1) sl_ky,
      ROW_NUMBER() OVER(ORDER BY v.period_type DESC) rn -- Thứ tự ưu tiên kỳ Năm > Quý
    FROM uat_mrms_stg.risk_indicator_value v
    LEFT JOIN uat_mrms_stg.risk_indicator i ON i.id = v.indicator_id
    CROSS JOIN params p
    WHERE v.deleted = '0'
      AND i.indicator_code = 'GDP_VN'
      AND v.period_type IN ('3','4') -- GDP theo quý hoặc năm
      AND v.period_year = p.gdp_year 
      AND v.ds_snpst_dt = '2026-10-23'
      AND i.ds_snpst_dt = '2026-10-23'
      GROUP BY v.period_type, v.period_year
  ) WHERE rn = 1
)
-- 2.7. Số lượng tài khoản NĐT còn mở: tại ngày báo cáo và cuối năm trước
---- 1 tài khoản mở/đóng nhiều lần: còn mở tại ngày D khi lần mở gần nhất (<= D) MỚI HƠN lần đóng gần nhất (<= D)
---- Mở và đóng cùng ngày -> coi là đã đóng; tài khoản chỉ có bản ghi đóng -> không tính
, acc_events AS (
  SELECT o.trading_account_no, CAST(o.open_date AS DATE) AS open_date, CAST(NULL AS DATE) AS close_date
  FROM uat_vsdc_stg.open_investors o
  WHERE o.trading_account_no IS NOT NULL
    AND CAST(o.open_date AS DATE) <= :report_date   -- chặn trên: bỏ các dòng sau ngày báo cáo
  UNION ALL
  SELECT c.trading_account_no, CAST(NULL AS DATE) AS open_date, CAST(c.close_date AS DATE) AS close_date
  FROM uat_vsdc_stg.closed_investors c
  WHERE c.trading_account_no IS NOT NULL
    AND CAST(c.close_date AS DATE) <= :report_date
)
, acc_state AS (
  SELECT
    e.trading_account_no,
    MAX(CASE WHEN e.open_date  <= p.report_date THEN e.open_date  END) AS open_cur,
    MAX(CASE WHEN e.close_date <= p.report_date THEN e.close_date END) AS close_cur,
    MAX(CASE WHEN e.open_date  <= p.py_end THEN e.open_date  END) AS open_py,
    MAX(CASE WHEN e.close_date <= p.py_end THEN e.close_date END) AS close_py
  FROM acc_events e
  CROSS JOIN params p
  GROUP BY e.trading_account_no
)
, acc_agg AS (
  SELECT
    COUNT(CASE WHEN open_cur IS NOT NULL AND (close_cur IS NULL OR open_cur > close_cur) THEN 1 END) AS tk_cur,
    COUNT(CASE WHEN open_py  IS NOT NULL AND (close_py  IS NULL OR open_py  > close_py)  THEN 1 END) AS tk_py
  FROM acc_state
)
-- 2.8. Gom các giá trị về 1 dòng; bình quân = tổng / số phiên của kỳ
, w AS (
  SELECT
    idx.vnindex_cur, idx.vnindex_pm, idx.vnindex_py, idx.hnxindex_cur, idx.hnxindex_pm, idx.hnxindex_py,
    ec.von_hoa_cophieu AS von_hoa_cophieu_cur, -- Ngày báo cáo là ngày giao dịch mới nhất (chưa có T+1 để lấy VWAP UPCoM) -> chưa tính vốn hóa
    ep.von_hoa_cophieu AS von_hoa_cophieu_py,
    ec.so_ma_cp_ccq_hnx_hose AS so_ma_cp_ccq_hnx_hose_cur, 
    ec.so_ma_cp_upcom AS so_ma_cp_upcom_cur,
    ec.gt_niemyet_cp_ccq AS gt_niemyet_cp_ccq_cur, 
    ep.gt_niemyet_cp_ccq AS gt_niemyet_cp_ccq_py,
    ec.so_ma_tpdnny AS so_ma_tpdnny_cur, 
    ec.gt_niemyet_tpdnny AS gt_niemyet_tpdnny_cur, 
    ep.gt_niemyet_tpdnny AS gt_niemyet_tpdnny_py,
    oi.oi_cur, oi.oi_pm, oi.oi_py,
    gdp.gdp_py,
    ta.cp_gt_m / NULLIF(ss.n_m, 0) AS cp_gt_bq_m,
    ta.cp_gt_pm / NULLIF(ss.n_pm, 0) AS cp_gt_bq_pm,
    ta.cp_gt_lym / NULLIF(ss.n_lym, 0) AS cp_gt_bq_lym,
    ta.cp_gt_y / NULLIF(ss.n_y, 0) AS cp_gt_bq_y,
    ta.cp_gt_py / NULLIF(ss.n_py, 0) AS cp_gt_bq_py,
    ta.tp_gt_m / NULLIF(ss.n_m, 0) AS tp_gt_bq_m,
    ta.tp_gt_pm / NULLIF(ss.n_pm, 0) AS tp_gt_bq_pm,
    ta.tp_gt_lym / NULLIF(ss.n_lym, 0) AS tp_gt_bq_lym,
    ta.tp_gt_y / NULLIF(ss.n_y, 0) AS tp_gt_bq_y,
    ta.tp_gt_py / NULLIF(ss.n_py, 0) AS tp_gt_bq_py,
    ta.cw_gt_m / NULLIF(ss.n_m, 0) AS cw_gt_bq_m,
    ta.cw_gt_pm / NULLIF(ss.n_pm, 0) AS cw_gt_bq_pm,
    ta.cw_gt_lym / NULLIF(ss.n_lym, 0) AS cw_gt_bq_lym,
    ta.cw_gt_y / NULLIF(ss.n_y, 0) AS cw_gt_bq_y,
    ta.cw_gt_py / NULLIF(ss.n_py, 0) AS cw_gt_bq_py,
    ta.cw_kl_m / NULLIF(ss.n_m, 0) AS cw_kl_bq_m,
    ta.cw_kl_pm / NULLIF(ss.n_pm, 0) AS cw_kl_bq_pm,
    ta.cw_kl_lym / NULLIF(ss.n_lym, 0) AS cw_kl_bq_lym,
    ta.cw_kl_y / NULLIF(ss.n_y, 0) AS cw_kl_bq_y,
    ta.cw_kl_py / NULLIF(ss.n_py, 0) AS cw_kl_bq_py,
    ta.ps_kl_m / NULLIF(ss.n_m, 0) AS ps_kl_bq_m,
    ta.ps_kl_pm / NULLIF(ss.n_pm, 0) AS ps_kl_bq_pm,
    ta.ps_kl_lym / NULLIF(ss.n_lym, 0) AS ps_kl_bq_lym,
    ta.ps_kl_y / NULLIF(ss.n_y, 0) AS ps_kl_bq_y,
    ta.ps_kl_py / NULLIF(ss.n_py, 0) AS ps_kl_bq_py,
    ta.ndtnn_rong_cq_ccq_m AS ndtnn_rong_cq_ccq_m,
    ta.ndtnn_rong_tpdnny_m AS ndtnn_rong_tpdnny_m,
    ta.ndtnn_rong_cp_ccq_y AS ndtnn_rong_cp_ccq_y,
    ta.ndtnn_rong_tpdnny_y AS ndtnn_rong_tpdnny_y,
    a.tk_cur, a.tk_py 
  FROM trade_agg ta
  CROSS JOIN key_dates ss
  CROSS JOIN idx
  CROSS JOIN oi
  CROSS JOIN acc_agg a 
  LEFT JOIN gdp ON 1 = 1
  LEFT JOIN (SELECT * FROM equity_agg WHERE pt = 'CUR') ec ON 1 = 1
  LEFT JOIN (SELECT * FROM equity_agg WHERE pt = 'PY') ep ON 1 = 1
)
-- 2.9. Dữ liệu lên dashboard: mỗi dòng 1 chỉ tiêu
SELECT
  p.report_date,
  k.d_cur AS ngay_du_lieu, -- Ngày dữ liệu thực tế (ngày giao dịch gần nhất <= ngày báo cáo)
  x.nhom_stt,
  x.nhom,
  x.metric_code,
  x.metric_name,
  x.gia_tri,
  x.don_vi
FROM params p
CROSS JOIN key_dates k
CROSS JOIN (
  SELECT STACK(52,
    1, '1', '1. Thị trường cổ phiếu', 'cp_vnindex', 'Chỉ số VN-Index ngày báo cáo', CAST(w.vnindex_cur AS DOUBLE), 'Điểm',
    2, '1', '1. Thị trường cổ phiếu', 'cp_vnindex_pct_cuoithangtruoc', 'Chỉ số VN-Index - % so với cuối tháng trước', CAST((w.vnindex_cur - w.vnindex_pm) / NULLIF(ABS(w.vnindex_pm), 0) * 100 AS DOUBLE), '%',
    3, '1', '1. Thị trường cổ phiếu', 'cp_vnindex_pct_cuoinamtruoc', 'Chỉ số VN-Index - % so với cuối năm trước', CAST((w.vnindex_cur - w.vnindex_py) / NULLIF(ABS(w.vnindex_py), 0) * 100 AS DOUBLE), '%',
    4, '1', '1. Thị trường cổ phiếu', 'cp_hnxindex', 'Chỉ số HNX-Index ngày báo cáo', CAST(w.hnxindex_cur AS DOUBLE), 'Điểm',
    5, '1', '1. Thị trường cổ phiếu', 'cp_hnxindex_pct_cuoithangtruoc', 'Chỉ số HNX-Index - % so với cuối tháng trước', CAST((w.hnxindex_cur - w.hnxindex_pm) / NULLIF(ABS(w.hnxindex_pm), 0) * 100 AS DOUBLE), '%',
    6, '1', '1. Thị trường cổ phiếu', 'cp_hnxindex_pct_cuoinamtruoc', 'Chỉ số HNX-Index - % so với cuối năm trước', CAST((w.hnxindex_cur - w.hnxindex_py) / NULLIF(ABS(w.hnxindex_py), 0) * 100 AS DOUBLE), '%',
    7, '1', '1. Thị trường cổ phiếu', 'cp_vonhoa', 'Vốn hóa thị trường cổ phiếu', CAST(w.von_hoa_cophieu_cur AS DOUBLE), 'VND',
    8, '1', '1. Thị trường cổ phiếu', 'cp_vonhoa_pct_cuoinamtruoc', 'Vốn hóa thị trường cổ phiếu - % so với cuối năm trước', CAST((w.von_hoa_cophieu_cur - w.von_hoa_cophieu_py) / NULLIF(ABS(w.von_hoa_cophieu_py), 0) * 100 AS DOUBLE), '%',
    9, '1', '1. Thị trường cổ phiếu', 'cp_vonhoa_gdp_pct', 'Tỷ lệ vốn hóa/GDP năm trước', CAST(w.von_hoa_cophieu_cur / NULLIF(w.gdp_py, 0) * 100 AS DOUBLE), '%',
    10, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_thang', 'GTGD bình quân/phiên tháng báo cáo', CAST(w.cp_gt_bq_m AS DOUBLE), 'VND',
    11, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_thang_pct', 'GTGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.cp_gt_bq_m - w.cp_gt_bq_pm) / NULLIF(ABS(w.cp_gt_bq_pm), 0) * 100 AS DOUBLE), '%',
    12, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_thang_pct_cungky', 'GTGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.cp_gt_bq_m - w.cp_gt_bq_lym) / NULLIF(ABS(w.cp_gt_bq_lym), 0) * 100 AS DOUBLE), '%',
    13, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_nam', 'GTGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.cp_gt_bq_y AS DOUBLE), 'VND',
    14, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_nam_pct', 'GTGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.cp_gt_bq_y - w.cp_gt_bq_py) / NULLIF(ABS(w.cp_gt_bq_py), 0) * 100 AS DOUBLE), '%',
    15, '1', '1. Thị trường cổ phiếu', 'cp_soma_cp_ccq_hnx_hose', 'Số mã cổ phiếu, CCQ niêm yết trên HNX, HOSE', CAST(w.so_ma_cp_ccq_hnx_hose_cur AS DOUBLE), 'Mã',
    16, '1', '1. Thị trường cổ phiếu', 'cp_soma_cp_upcom', 'Số mã cổ phiếu ĐKGD trên UPCoM', CAST(w.so_ma_cp_upcom_cur AS DOUBLE), 'Mã',
    17, '1', '1. Thị trường cổ phiếu', 'cp_gt_niemyet', 'Tổng giá trị niêm yết, ĐKGD (mệnh giá 10.000 x KL lưu hành)', CAST(w.gt_niemyet_cp_ccq_cur AS DOUBLE), 'VND',
    18, '1', '1. Thị trường cổ phiếu', 'cp_gt_niemyet_pct_cuoinamtruoc', 'Tổng giá trị niêm yết, ĐKGD - % so với cuối năm trước', CAST((w.gt_niemyet_cp_ccq_cur - w.gt_niemyet_cp_ccq_py) / NULLIF(ABS(w.gt_niemyet_cp_ccq_py), 0) * 100 AS DOUBLE), '%',
    19, '1', '1. Thị trường cổ phiếu', 'cp_gt_niemyet_gdp_pct', 'Tổng giá trị niêm yết, ĐKGD - % so với GDP năm trước', CAST(w.gt_niemyet_cp_ccq_cur / NULLIF(w.gdp_py, 0) * 100 AS DOUBLE), '%',
    20, '2', '2. Thị trường trái phiếu', 'tp_gtgd_bq_thang', 'GTGD bình quân/phiên tháng báo cáo', CAST(w.tp_gt_bq_m AS DOUBLE), 'VND',
    21, '2', '2. Thị trường trái phiếu', 'tp_gtgd_bq_thang_pct', 'GTGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.tp_gt_bq_m - w.tp_gt_bq_pm) / NULLIF(ABS(w.tp_gt_bq_pm), 0) * 100 AS DOUBLE), '%',
    22, '2', '2. Thị trường trái phiếu', 'tp_gtgd_bq_thang_pct_cungky', 'GTGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.tp_gt_bq_m - w.tp_gt_bq_lym) / NULLIF(ABS(w.tp_gt_bq_lym), 0) * 100 AS DOUBLE), '%',
    23, '2', '2. Thị trường trái phiếu', 'tp_gtgd_bq_nam', 'GTGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.tp_gt_bq_y AS DOUBLE), 'VND',
    24, '2', '2. Thị trường trái phiếu', 'tp_gtgd_bq_nam_pct', 'GTGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.tp_gt_bq_y - w.tp_gt_bq_py) / NULLIF(ABS(w.tp_gt_bq_py), 0) * 100 AS DOUBLE), '%',
    25, '2', '2. Thị trường trái phiếu', 'tp_soma_niemyet', 'Số mã trái phiếu niêm yết (TPDN niêm yết)', CAST(w.so_ma_tpdnny_cur AS DOUBLE), 'Mã',
    26, '2', '2. Thị trường trái phiếu', 'tp_gt_niemyet', 'Giá trị niêm yết trái phiếu (TPDN niêm yết)', CAST(w.gt_niemyet_tpdnny_cur AS DOUBLE), 'VND',
    27, '2', '2. Thị trường trái phiếu', 'tp_gt_niemyet_pct_cuoinamtruoc', 'Giá trị niêm yết trái phiếu - % so với cuối năm trước', CAST((w.gt_niemyet_tpdnny_cur - w.gt_niemyet_tpdnny_py) / NULLIF(ABS(w.gt_niemyet_tpdnny_py), 0) * 100 AS DOUBLE), '%',
    28, '2', '2. Thị trường trái phiếu', 'tp_gt_niemyet_gdp_pct', 'Giá trị niêm yết trái phiếu - % so với GDP năm trước', CAST(w.gt_niemyet_tpdnny_cur / NULLIF(w.gdp_py, 0) * 100 AS DOUBLE), '%',
    29, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_klgd_bq_thang', 'KLGD bình quân/phiên tháng báo cáo', CAST(w.ps_kl_bq_m AS DOUBLE), 'Hợp đồng',
    30, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_klgd_bq_thang_pct', 'KLGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.ps_kl_bq_m - w.ps_kl_bq_pm) / NULLIF(ABS(w.ps_kl_bq_pm), 0) * 100 AS DOUBLE), '%',
    31, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_klgd_bq_thang_pct_cungky', 'KLGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.ps_kl_bq_m - w.ps_kl_bq_lym) / NULLIF(ABS(w.ps_kl_bq_lym), 0) * 100 AS DOUBLE), '%',
    32, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_klgd_bq_nam', 'KLGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.ps_kl_bq_y AS DOUBLE), 'Hợp đồng',
    33, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_klgd_bq_nam_pct', 'KLGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.ps_kl_bq_y - w.ps_kl_bq_py) / NULLIF(ABS(w.ps_kl_bq_py), 0) * 100 AS DOUBLE), '%',
    34, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_oi', 'Khối lượng mở (OI)', CAST(w.oi_cur AS DOUBLE), 'Hợp đồng',
    35, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_oi_pct_cuoithangtruoc', 'Khối lượng mở (OI) - % so với cuối tháng trước', CAST((w.oi_cur - w.oi_pm) / NULLIF(ABS(w.oi_pm), 0) * 100 AS DOUBLE), '%',
    36, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_oi_pct_cuoinamtruoc', 'Khối lượng mở (OI) - % so với cuối năm trước', CAST((w.oi_cur - w.oi_py) / NULLIF(ABS(w.oi_py), 0) * 100 AS DOUBLE), '%',
    37, '4', '3.2. Chứng quyền', 'cw_klgd_bq_thang', 'KLGD bình quân/phiên tháng báo cáo', CAST(w.cw_kl_bq_m AS DOUBLE), 'Chứng quyền',
    38, '4', '3.2. Chứng quyền', 'cw_klgd_bq_thang_pct', 'KLGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.cw_kl_bq_m - w.cw_kl_bq_pm) / NULLIF(ABS(w.cw_kl_bq_pm), 0) * 100 AS DOUBLE), '%',
    39, '4', '3.2. Chứng quyền', 'cw_klgd_bq_thang_pct_cungky', 'KLGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.cw_kl_bq_m - w.cw_kl_bq_lym) / NULLIF(ABS(w.cw_kl_bq_lym), 0) * 100 AS DOUBLE), '%',
    40, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_thang', 'GTGD bình quân/phiên tháng báo cáo', CAST(w.cw_gt_bq_m AS DOUBLE), 'VND',
    41, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_thang_pct', 'GTGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.cw_gt_bq_m - w.cw_gt_bq_pm) / NULLIF(ABS(w.cw_gt_bq_pm), 0) * 100 AS DOUBLE), '%',
    42, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_thang_pct_cungky', 'GTGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.cw_gt_bq_m - w.cw_gt_bq_lym) / NULLIF(ABS(w.cw_gt_bq_lym), 0) * 100 AS DOUBLE), '%',
    43, '4', '3.2. Chứng quyền', 'cw_klgd_bq_nam', 'KLGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.cw_kl_bq_y AS DOUBLE), 'Chứng quyền',
    44, '4', '3.2. Chứng quyền', 'cw_klgd_bq_nam_pct', 'KLGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.cw_kl_bq_y - w.cw_kl_bq_py) / NULLIF(ABS(w.cw_kl_bq_py), 0) * 100 AS DOUBLE), '%',
    45, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_nam', 'GTGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.cw_gt_bq_y AS DOUBLE), 'VND',
    46, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_nam_pct', 'GTGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.cw_gt_bq_y - w.cw_gt_bq_py) / NULLIF(ABS(w.cw_gt_bq_py), 0) * 100 AS DOUBLE), '%',
    47, '5', '4. Hoạt động NĐT (tháng/năm báo cáo, tính đến ngày báo cáo)', 'ndtnn_rong_cp_ccq_thang', 'GT NĐTNN mua/bán ròng cổ phiếu, CCQ tháng báo cáo', CAST(w.ndtnn_rong_cq_ccq_m AS DOUBLE), 'VND',
    48, '5', '4. Hoạt động NĐT (tháng/năm báo cáo, tính đến ngày báo cáo)', 'ndtnn_rong_tpdnny_thang', 'GT NĐTNN mua/bán ròng trái phiếu (TPDN niêm yết) tháng báo cáo', CAST(w.ndtnn_rong_tpdnny_m AS DOUBLE), 'VND',
    49, '5', '4. Hoạt động NĐT (tháng/năm báo cáo, tính đến ngày báo cáo)', 'ndtnn_rong_cp_ccq_nam', 'GT NĐTNN mua/bán ròng cổ phiếu, CCQ năm báo cáo', CAST(w.ndtnn_rong_cp_ccq_y AS DOUBLE), 'VND',
    50, '5', '4. Hoạt động NĐT (tháng/năm báo cáo, tính đến ngày báo cáo)', 'ndtnn_rong_tpdnny_nam', 'GT NĐTNN mua/bán ròng trái phiếu (TPDN niêm yết) năm báo cáo', CAST(w.ndtnn_rong_tpdnny_y AS DOUBLE), 'VND',
    51, '6', '4. Hoạt động NĐT (tháng/năm báo cáo, tính đến ngày báo cáo)', 'tk_luyke_thang', 'Số lượng tài khoản của NĐT tính đến cuối tháng', CAST(w.tk_cur AS DOUBLE), 'TK',
    52, '6', '4. Hoạt động NĐT (tháng/năm báo cáo, tính đến ngày báo cáo)', 'tk_luyke_nam_pct', 'Số lượng tài khoản của NĐT - % so với cuối năm trước', CAST((w.tk_cur - w.tk_py) / NULLIF(ABS(w.tk_py), 0) * 100 AS DOUBLE), '%'
  ) AS (thu_tu, nhom_stt, nhom, metric_code, metric_name, gia_tri, don_vi)
  FROM w
) x
ORDER BY x.thu_tu
;