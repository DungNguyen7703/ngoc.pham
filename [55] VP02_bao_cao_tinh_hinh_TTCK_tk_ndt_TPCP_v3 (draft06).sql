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
 *  - Phân loại CK: bản ghi cuối ngày của jad_stockinfor (stocktype 2 = CP, 3/6 = CCQ, floorcode 10 + stocktype 4 = CW, floorcode 03 + stocktype 4 + underlyingsymbol VN30 = HĐTL VN30).
 *  - NĐTNN: SUBSTR(số tài khoản, 4, 1) IN ('E','F').
 *  - Giá trị tiền tệ tính bằng VND.
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
    WHERE m.marketcode IN ('HOSE', 'HNX') -- HOSE = VNIndex, HNX = HNX-Index
      AND m.tradingdate IN (k.report_date, k.d_pm, k.d_py) -- Ngày báo cáo, Ngày giao dịch cuối tháng trước, Ngày giao dịch cuối năm trước
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
    SUM(CASE WHEN t.trade_date BETWEEN p.month_start AND p.report_date THEN t.execution_value ELSE 0 END) AS gt_m,
    SUM(CASE WHEN t.trade_date BETWEEN p.pm_start AND p.pm_end THEN t.execution_value ELSE 0 END) AS gt_pm,
    SUM(CASE WHEN t.trade_date BETWEEN p.lym_start AND p.lym_end THEN t.execution_value ELSE 0 END) AS gt_lym,
    SUM(CASE WHEN t.trade_date BETWEEN p.year_start AND p.report_date THEN t.execution_value ELSE 0 END) AS gt_y,
    SUM(CASE WHEN t.trade_date BETWEEN p.py_start AND p.py_end THEN t.execution_value ELSE 0 END) AS gt_py,
    SUM(CASE WHEN t.trade_date BETWEEN p.month_start AND p.report_date THEN t.execution_volume ELSE 0 END) AS kl_m,
    SUM(CASE WHEN t.trade_date BETWEEN p.pm_start AND p.pm_end THEN t.execution_volume ELSE 0 END) AS kl_pm,
    SUM(CASE WHEN t.trade_date BETWEEN p.lym_start AND p.lym_end THEN t.execution_volume ELSE 0 END) AS kl_lym,
    SUM(CASE WHEN t.trade_date BETWEEN p.year_start AND p.report_date THEN t.execution_volume ELSE 0 END) AS kl_y,
    SUM(CASE WHEN t.trade_date BETWEEN p.py_start AND p.py_end THEN t.execution_volume ELSE 0 END) AS kl_py,
    SUM(CASE WHEN t.trade_date BETWEEN p.month_start AND p.report_date 
      THEN (CASE WHEN SUBSTR(t.buy_acct_no, 4, 1) IN ('E', 'F') THEN t.execution_value ELSE 0 END) 
            - (CASE WHEN SUBSTR(t.sell_acct_no, 4, 1) IN ('E', 'F') THEN t.execution_value ELSE 0 END) 
      ELSE 0 
    END) AS ndtnn_rong_m,
    SUM(CASE WHEN t.trade_date BETWEEN p.year_start AND p.report_date 
      THEN (CASE WHEN SUBSTR(t.buy_acct_no, 4, 1) IN ('E', 'F') THEN t.execution_value ELSE 0 END) 
            - (CASE WHEN SUBSTR(t.sell_acct_no, 4, 1) IN ('E', 'F') THEN t.execution_value ELSE 0 END) 
      ELSE 0 
    END) AS ndtnn_rong_y
  FROM uat_hose_stg.trade_book t
  JOIN stock_list s ON t.symbol = s.symbol
  CROSS JOIN params p
  WHERE t.market_id = 'STK'
    AND t.trade_date BETWEEN p.py_start AND p.report_date
    --AND s.loai_ck IN ('CP', 'CCQ', 'CW')
  GROUP BY s.loai_ck
  UNION ALL
  -- 2.3.2. HNX + UPCoM: Cổ phiếu, CCQ, HĐTL VN30 (DVX); join với stock_list theo mã ISIN
  ---- Nếu là Phái sinh (DVX) có hệ số nhân contractmultiplier <> 1, loại khác = 1 (lấy nvl để tránh trường hợp bị lỗi giá trị s.contractmultiplier null) --> Tính dư GTGD danh nghĩa của Phái sinh do cùng câu lấy dữ liệu, còn báo cáo không cần
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
  WHERE h.market_id IN ('STX', 'UPX', 'DVX') -- Chỉ lấy CP, Phái sinh, không lấy TPDN niêm yết
    AND h.trade_date BETWEEN DATE_FORMAT(p.py_start, 'yyyyMMdd') AND DATE_FORMAT(p.report_date, 'yyyyMMdd')
    --AND s.loai_ck IN ('CP', 'CCQ', 'HDTL_VN30')
  GROUP BY s.loai_ck
  UNION ALL
  -- 2.3.3. Trái phiếu = TPCP (trái phiếu chính phủ):
  ---- HNX: TPCP - sổ lệnh Outright + Repo (GT Repo = giá trị thanh toán lần 1), chỉ lấy lệnh đã thực hiện (ĐTH)
  SELECT
    'TPCP' AS loai_ck,
    SUM(CASE WHEN o.trading_date BETWEEN p.month_start AND p.report_date THEN o.gt ELSE 0 END) AS gt_m,
    SUM(CASE WHEN o.trading_date BETWEEN p.pm_start AND p.pm_end THEN o.gt ELSE 0 END) AS gt_pm,
    SUM(CASE WHEN o.trading_date BETWEEN p.lym_start AND p.lym_end THEN o.gt ELSE 0 END) AS gt_lym,
    SUM(CASE WHEN o.trading_date BETWEEN p.year_start AND p.report_date THEN o.gt ELSE 0 END) AS gt_y,
    SUM(CASE WHEN o.trading_date BETWEEN p.py_start AND p.py_end THEN o.gt ELSE 0 END) AS gt_py,
    SUM(CASE WHEN o.trading_date BETWEEN p.month_start AND p.report_date THEN o.kl ELSE 0 END) AS kl_m,
    SUM(CASE WHEN o.trading_date BETWEEN p.pm_start AND p.pm_end THEN o.kl ELSE 0 END) AS kl_pm,
    SUM(CASE WHEN o.trading_date BETWEEN p.lym_start AND p.lym_end THEN o.kl ELSE 0 END) AS kl_lym,
    SUM(CASE WHEN o.trading_date BETWEEN p.year_start AND p.report_date THEN o.kl ELSE 0 END) AS kl_y,
    SUM(CASE WHEN o.trading_date BETWEEN p.py_start AND p.py_end THEN o.kl ELSE 0 END) AS kl_py,
    SUM(CASE WHEN o.trading_date BETWEEN p.month_start AND p.report_date
      THEN (CASE WHEN SUBSTR(o.buy_acct, 4, 1) IN ('E', 'F') THEN o.gt ELSE 0 END)
            - (CASE WHEN SUBSTR(o.sell_acct, 4, 1) IN ('E', 'F') THEN o.gt ELSE 0 END)
      ELSE 0
    END) AS ndtnn_rong_m,
    SUM(CASE WHEN o.trading_date BETWEEN p.year_start AND p.report_date
      THEN (CASE WHEN SUBSTR(o.buy_acct, 4, 1) IN ('E', 'F') THEN o.gt ELSE 0 END)
            - (CASE WHEN SUBSTR(o.sell_acct, 4, 1) IN ('E', 'F') THEN o.gt ELSE 0 END)
      ELSE 0
    END) AS ndtnn_rong_y
  FROM (
    SELECT o.trading_date, o.volume AS kl, o.trading_value AS gt, o.buying_account_no AS buy_acct, o.selling_account_no AS sell_acct
    FROM uat_hnx_stg.outright_order_book o
    CROSS JOIN params p
    WHERE o.order_status = 'ĐTH'
      AND o.trading_date BETWEEN p.py_start AND p.report_date
    UNION ALL
    SELECT r.trading_date, r.volume AS kl, r.first_settlement_value AS gt, r.buying_account_no AS buy_acct, r.selling_account_no AS sell_acct
    FROM uat_hnx_stg.repo_order_book r
    CROSS JOIN params p
    WHERE r.order_status = 'ĐTH'
      AND r.trading_date BETWEEN p.py_start AND p.report_date
  ) o
  CROSS JOIN params p
)
----> Chuyển loại CK thành cột
, trade_agg AS (
  SELECT * FROM (
    SELECT
      CASE WHEN loai_ck IN ('CP','CCQ') THEN 'CP_CCQ' ELSE loai_ck END AS grp, -- gộp CP + CCQ
      gt_m, gt_pm, gt_lym, gt_y, gt_py,
      kl_m, kl_pm, kl_lym, kl_y, kl_py,
      ndtnn_rong_m, ndtnn_rong_y
    FROM trade_period
  )
  PIVOT (
    SUM(gt_m) AS gt_m, SUM(gt_pm) AS gt_pm, SUM(gt_lym) AS gt_lym, SUM(gt_y) AS gt_y, SUM(gt_py) AS gt_py,
    SUM(kl_m) AS kl_m, SUM(kl_pm) AS kl_pm, SUM(kl_lym) AS kl_lym, SUM(kl_y) AS kl_y, SUM(kl_py) AS kl_py,
    SUM(ndtnn_rong_m) AS ndtnn_rong_m, SUM(ndtnn_rong_y) AS ndtnn_rong_y
    FOR grp IN ('CP_CCQ' AS cp_ccq, 'TPCP' AS tpcp, 'CW' AS cw, 'HDTL_VN30' AS ps_hdtl_vn30)
  )
)
-- 2.4. Chỉ tiêu vốn hóa, số mã niêm yết/ĐKGD
---- Cổ phiếu, CCQ niêm yết/ĐKGD tại ngày dữ liệu d_cur (CUR) và cuối năm trước (PY): KL lưu hành, Số mã NY/ĐKGD
---- HOSE, HNX (floorcode 02, 10): Giá đóng cửa
---- UPCoM (floorcode 04): Giá trung bình (VWAP) ngày T được Sở gửi trong tín hiệu MDDS (d - security definition) ngày T+1; nếu VWAP = 0 (mã trắng thanh khoản) thì lấy giá tham chiếu ngày T
---- Nếu ngày BC là ngày giao dịch mới nhất thì CHƯA có số liệu vốn hóa UPCoM (NULL)
, equity_data AS (
  SELECT
    x.pt, x.tradingdate, x.symbol, x.floorcode, x.stocktype, x.loai_ck, x.price, x.closeprice, x.reference, x.d_next, x.vwap,
    x.listedshare, -- Khối lượng niêm yết
    os.outstanding_shares AS kllh_cp, -- Khối lượng lưu hành
    CASE WHEN x.stocktype = '2' THEN x.price * os.outstanding_shares END AS von_hoa_cophieu, -- Vốn hóa (cổ phiếu)
    -- GT niêm yết (CP, CCQ) = KL niêm yết x Mệnh giá (CP/CCQ 10000vnd)
    CASE 
      WHEN x.stocktype IN ('2','3','6') THEN x.listedshare * 10000 
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
      s.closeprice, s.reference, s.listedshare, 
      k.d_next, n.vwap
    FROM stock_eod s
    CROSS JOIN key_dates k
    LEFT JOIN stock_eod n ON n.symbol = s.symbol AND n.tradingdate = k.d_next -- Lấy giá VWAP ngày T Sở gửi ngày T+1 để tính vốn hóa upcom
    WHERE s.tradingdate = k.d_cur
      AND s.floorcode IN ('02','04','10') AND s.stocktype IN ('2', '3', '6') -- CP, CCQ
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
      s.closeprice, s.reference, s.listedshare, 
      k.d_py_next, n.vwap
    FROM stock_eod s
    CROSS JOIN key_dates k
    LEFT JOIN stock_eod n ON n.symbol = s.symbol AND n.tradingdate = k.d_py_next -- Lấy giá VWAP ngày T Sở gửi ngày T+1 để tính vốn hóa upcom
    WHERE s.tradingdate = k.d_py
      AND s.floorcode IN ('02','04','10') AND s.stocktype IN ('2', '3', '6') -- CP, CCQ
  ) x
  LEFT JOIN uat_vsdc_stg.outstanding_shares os ON os.transaction_date = x.tradingdate AND os.ticker_symbol = x.symbol -- Khối lượng lưu hành CP/CCQ cuối ngày để tính vốn hóa
)
-- Tính vốn hóa, GT niêm yết, Số mã NY/ĐKGD
, equity_agg AS (
  SELECT
    pt,
    SUM(von_hoa_cophieu) AS von_hoa_cophieu, 
    SUM(CASE WHEN stocktype IN ('2', '3', '6') THEN gt_niemyet ELSE 0 END) AS gt_niemyet_cp_ccq,
    COUNT(CASE WHEN floorcode IN ('02', '10') AND stocktype IN ('2', '3', '6') THEN symbol END) AS so_ma_cp_ccq_hnx_hose, -- CP, CCQ niêm yết HNX, HOSE
    COUNT(CASE WHEN floorcode = '04' AND stocktype = '2' THEN symbol END) AS so_ma_cp_upcom -- CP ĐKGD UPCoM
  FROM equity_data
  GROUP BY pt
)
-- 2.4.1. TPCP niêm yết: danh sách TPCP niêm yết thống kê hàng tháng (gov_bond_listed_list)
---- CUR (Đến ngày báo cáo): Lấy tháng của ngày báo cáo; PY (Cuối năm trước): Lấy tháng 12 năm trước. Nếu ngày báo cáo < ngày cuối tháng của dữ liệu thì CHƯA có số liệu (NULL)
---- GT niêm yết = KL niêm yết x mệnh giá 100.000 VND
, gb_listed AS (
  SELECT
    t.pt,
    COUNT(DISTINCT g.bond_code) AS so_ma_tpcp,
    SUM(g.listed_volume * 100000) AS gt_niemyet_tpcp
  FROM (
    SELECT 'CUR' AS pt, LAST_DAY(p.report_date) AS d_end FROM params p
    UNION ALL
    SELECT 'PY' AS pt, p.py_end AS d_end FROM params p
  ) t
  CROSS JOIN params p
  JOIN uat_hnx_stg.gov_bond_listed_list g
    ON CAST(g.report_year AS INT) = YEAR(t.d_end)
   AND CAST(g.report_month AS INT) = MONTH(t.d_end)
  WHERE p.report_date >= t.d_end
  -- AND g.ds_snpst_dt = ...
  GROUP BY t.pt
)
-- 2.5. Khối lượng mở (OI) HĐTL VN30: Tại d_cur, cuối tháng trước, cuối năm trước
, oi AS (
  SELECT
    SUM(CASE WHEN oi.report_date = k.d_cur THEN oi.open_interest_volume END) AS oi_cur,
    SUM(CASE WHEN oi.report_date = k.d_pm THEN oi.open_interest_volume END) AS oi_pm,
    SUM(CASE WHEN oi.report_date = k.d_py THEN oi.open_interest_volume END) AS oi_py
  FROM uat_vsdc_stg.end_of_day_open_interest oi
  CROSS JOIN key_dates k
  JOIN stock_eod s ON oi.report_date = s.tradingdate AND oi.contract_code = s.symbol AND s.loai_ck = 'HDTL_VN30'
  WHERE oi.report_date IN (k.d_cur, k.d_pm, k.d_py)
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
      SUM(TRY_CAST(v.value AS DOUBLE) * MAP('3',1000000000,'8',1,'23',1000000)[v.unit_code]) AS gdp_py,
      COUNT(1) sl_ky,
      ROW_NUMBER() OVER(ORDER BY v.period_type DESC) rn -- Thứ tự ưu tiên kỳ Năm > Quý
    FROM uat_mrms_stg.risk_indicator_value v
    LEFT JOIN uat_mrms_stg.risk_indicator i ON i.id = v.indicator_id
    CROSS JOIN params p
    WHERE i.indicator_code = 'GDP_VN'
      AND v.period_type IN ('3','4') -- GDP theo quý hoặc năm
      AND v.period_year = p.gdp_year 
      AND v.deleted = '0'
      AND v.ds_snpst_dt = '2026-10-23'
      AND i.ds_snpst_dt = '2026-10-23'
      GROUP BY v.period_type, v.period_year
  ) WHERE rn = 1
  AND (period_type = '4' OR (period_type = '3' AND sl_ky = 4))
)
-- 2.7. Số lượng tài khoản NĐT hoạt động tính đến ngày báo cáo (cur) / ngày cuối năm trước (py)
---- Tài khoản mở/đóng nhiều lần: trạng thái tại ngày D = loại sự kiện (mở/đóng) có ngày GẦN NHẤT <= D; sự kiện gần nhất là mở -> còn hoạt động
---- Ngày gần nhất có cả mở và đóng (không có thứ tự bản ghi/timestamp) -> suy luận theo trạng thái ngày liền trước:
----   trước đó đang hoạt động -> đóng rồi mở lại -> hoạt động; trước đó chưa mở/đã đóng/không có event -> mở rồi đóng -> đã đóng
---- Tài khoản chỉ có bản ghi đóng (thiếu dữ liệu mở) -> không tính
, acc_agg AS (
  SELECT
    COUNT(CASE WHEN period = 'cur' AND is_active THEN 1 END) AS tk_cur,
    COUNT(CASE WHEN period = 'py'  AND is_active THEN 1 END) AS tk_py
  FROM (
    -- Trạng thái tại ngày event gần nhất (rn = 1) của từng tài khoản theo từng kỳ
    SELECT
      s.period, s.trading_account_no,
      CASE
        WHEN s.has_open  AND NOT s.has_close THEN TRUE   -- Ngày gần nhất chỉ có mở -> hoạt động
        WHEN s.has_close AND NOT s.has_open  THEN FALSE  -- Ngày gần nhất chỉ có đóng -> không hoạt động
        ELSE COALESCE(s.prev_is_open, FALSE)             -- Trùng ngày mở/đóng -> theo ngày liền trước (không có -> đóng)
      END AS is_active
    FROM (
      SELECT
        d.*,
        -- Ngày liền trước chỉ có mở (không có đóng) -> tài khoản đang hoạt động trước ngày này
        LAG(d.has_open AND NOT d.has_close) OVER (PARTITION BY d.period, d.trading_account_no ORDER BY d.event_date) AS prev_is_open,
        ROW_NUMBER() OVER (PARTITION BY d.period, d.trading_account_no ORDER BY d.event_date DESC) AS rn
      FROM (
        -- Gộp theo kỳ + tài khoản + ngày: ngày đó có mở? có đóng?
        SELECT
          ap.period, e.trading_account_no, e.event_date,
          BOOL_OR(e.event_type = 'OPEN')  AS has_open,
          BOOL_OR(e.event_type = 'CLOSE') AS has_close
        FROM (
          -- Event mở/đóng tài khoản
          SELECT o.trading_account_no, CAST(o.open_date AS DATE) AS event_date, 'OPEN' AS event_type
          FROM uat_vsdc_stg.open_investors o
          WHERE o.trading_account_no IS NOT NULL AND o.open_date IS NOT NULL -- Loại trừ dữ liệu lỗi
          UNION ALL
          SELECT c.trading_account_no, CAST(c.close_date AS DATE) AS event_date, 'CLOSE' AS event_type
          FROM uat_vsdc_stg.closed_investors c
          WHERE c.trading_account_no IS NOT NULL AND c.close_date IS NOT NULL -- Loại trừ dữ liệu lỗi
        ) e
        JOIN (
          -- Hai mốc tính: ngày báo cáo, ngày cuối năm trước
          SELECT 'cur' AS period, p.report_date AS as_of_date FROM params p
          UNION ALL
          SELECT 'py'  AS period, p.py_end      AS as_of_date FROM params p
        ) ap ON e.event_date <= ap.as_of_date
        GROUP BY ap.period, e.trading_account_no, e.event_date
      ) d
    ) s
    WHERE s.rn = 1
  ) t
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
    gc.so_ma_tpcp AS so_ma_tpcp_cur,
    gc.gt_niemyet_tpcp AS gt_niemyet_tpcp_cur,
    gp.gt_niemyet_tpcp AS gt_niemyet_tpcp_py,
    oi.oi_cur, oi.oi_pm, oi.oi_py,
    gdp.gdp_py,
    ta.cp_ccq_gt_m / NULLIF(ss.n_m, 0) AS cp_ccq_gt_bq_m,
    ta.cp_ccq_gt_pm / NULLIF(ss.n_pm, 0) AS cp_ccq_gt_bq_pm,
    ta.cp_ccq_gt_lym / NULLIF(ss.n_lym, 0) AS cp_ccq_gt_bq_lym,
    ta.cp_ccq_gt_y / NULLIF(ss.n_y, 0) AS cp_ccq_gt_bq_y,
    ta.cp_ccq_gt_py / NULLIF(ss.n_py, 0) AS cp_ccq_gt_bq_py,
    ta.tpcp_gt_m / NULLIF(ss.n_m, 0) AS tpcp_gt_bq_m,
    ta.tpcp_gt_pm / NULLIF(ss.n_pm, 0) AS tpcp_gt_bq_pm,
    ta.tpcp_gt_lym / NULLIF(ss.n_lym, 0) AS tpcp_gt_bq_lym,
    ta.tpcp_gt_y / NULLIF(ss.n_y, 0) AS tpcp_gt_bq_y,
    ta.tpcp_gt_py / NULLIF(ss.n_py, 0) AS tpcp_gt_bq_py,
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
    ta.ps_hdtl_vn30_kl_m / NULLIF(ss.n_m, 0) AS ps_hdtl_vn30_kl_bq_m,
    ta.ps_hdtl_vn30_kl_pm / NULLIF(ss.n_pm, 0) AS ps_hdtl_vn30_kl_bq_pm,
    ta.ps_hdtl_vn30_kl_lym / NULLIF(ss.n_lym, 0) AS ps_hdtl_vn30_kl_bq_lym,
    ta.ps_hdtl_vn30_kl_y / NULLIF(ss.n_y, 0) AS ps_hdtl_vn30_kl_bq_y,
    ta.ps_hdtl_vn30_kl_py / NULLIF(ss.n_py, 0) AS ps_hdtl_vn30_kl_bq_py,
    ta.cp_ccq_ndtnn_rong_m AS cp_ccq_ndtnn_rong_m,
    ta.tpcp_ndtnn_rong_m AS tpcp_ndtnn_rong_m,
    ta.cp_ccq_ndtnn_rong_y AS cp_ccq_ndtnn_rong_y,
    ta.tpcp_ndtnn_rong_y AS tpcp_ndtnn_rong_y,
    a.tk_cur, a.tk_py 
  FROM trade_agg ta
  CROSS JOIN key_dates ss
  CROSS JOIN idx
  CROSS JOIN oi
  CROSS JOIN acc_agg a 
  LEFT JOIN gdp ON 1 = 1
  LEFT JOIN (SELECT * FROM equity_agg WHERE pt = 'CUR') ec ON 1 = 1
  LEFT JOIN (SELECT * FROM equity_agg WHERE pt = 'PY') ep ON 1 = 1
  LEFT JOIN (SELECT * FROM gb_listed WHERE pt = 'CUR') gc ON 1 = 1 -- TPCP
  LEFT JOIN (SELECT * FROM gb_listed WHERE pt = 'PY') gp ON 1 = 1  -- TPCP
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
    9, '1', '1. Thị trường cổ phiếu', 'cp_vonhoa_gdp_pct', 'Tỷ lệ vốn hóa/GDP năm', CAST(w.von_hoa_cophieu_cur / NULLIF(w.gdp_py, 0) * 100 AS DOUBLE), '%',
    10, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_thang', 'Cổ phiếu, CCQ - GTGD bình quân tháng báo cáo', CAST(w.cp_ccq_gt_bq_m AS DOUBLE), 'VND',
    11, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_thang_pct', 'Cổ phiếu, CCQ - GTGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.cp_ccq_gt_bq_m - w.cp_ccq_gt_bq_pm) / NULLIF(ABS(w.cp_ccq_gt_bq_pm), 0) * 100 AS DOUBLE), '%',
    12, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_thang_pct_cungky', 'Cổ phiếu, CCQ - GTGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.cp_ccq_gt_bq_m - w.cp_ccq_gt_bq_lym) / NULLIF(ABS(w.cp_ccq_gt_bq_lym), 0) * 100 AS DOUBLE), '%',
    13, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_nam', 'Cổ phiếu, CCQ - GTGD bình quân năm báo cáo', CAST(w.cp_ccq_gt_bq_y AS DOUBLE), 'VND',
    14, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_nam_pct', 'Cổ phiếu, CCQ - GTGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.cp_ccq_gt_bq_y - w.cp_ccq_gt_bq_py) / NULLIF(ABS(w.cp_ccq_gt_bq_py), 0) * 100 AS DOUBLE), '%',
    15, '1', '1. Thị trường cổ phiếu', 'cp_soma_cp_ccq_hnx_hose', 'Cổ phiếu, CCQ - Số mã niêm yết trên HNX, HOSE', CAST(w.so_ma_cp_ccq_hnx_hose_cur AS DOUBLE), 'Mã',
    16, '1', '1. Thị trường cổ phiếu', 'cp_soma_cp_upcom', 'Cổ phiếu - Số mã cổ phiếu ĐKGD trên UPCoM', CAST(w.so_ma_cp_upcom_cur AS DOUBLE), 'Mã',
    17, '1', '1. Thị trường cổ phiếu', 'cp_gt_niemyet', 'Cổ phiếu, CCQ - Tổng giá trị niêm yết, ĐKGD', CAST(w.gt_niemyet_cp_ccq_cur AS DOUBLE), 'VND',
    18, '1', '1. Thị trường cổ phiếu', 'cp_gt_niemyet_pct_cuoinamtruoc', 'Cổ phiếu, CCQ - Tổng giá trị niêm yết, ĐKGD - % so với cuối năm trước', CAST((w.gt_niemyet_cp_ccq_cur - w.gt_niemyet_cp_ccq_py) / NULLIF(ABS(w.gt_niemyet_cp_ccq_py), 0) * 100 AS DOUBLE), '%',
    19, '1', '1. Thị trường cổ phiếu', 'cp_gt_niemyet_gdp_pct', 'Cổ phiếu, CCQ - Tổng giá trị niêm yết, ĐKGD - % so với GDP năm', CAST(w.gt_niemyet_cp_ccq_cur / NULLIF(w.gdp_py, 0) * 100 AS DOUBLE), '%',
    20, '2', '2. Thị trường trái phiếu', 'tpcp_gtgd_bq_thang', 'TPCP - GTGD bình quân tháng báo cáo', CAST(w.tpcp_gt_bq_m AS DOUBLE), 'VND',
    21, '2', '2. Thị trường trái phiếu', 'tpcp_gtgd_bq_thang_pct', 'TPCP - GTGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.tpcp_gt_bq_m - w.tpcp_gt_bq_pm) / NULLIF(ABS(w.tpcp_gt_bq_pm), 0) * 100 AS DOUBLE), '%',
    22, '2', '2. Thị trường trái phiếu', 'tpcp_gtgd_bq_thang_pct_cungky', 'TPCP - GTGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.tpcp_gt_bq_m - w.tpcp_gt_bq_lym) / NULLIF(ABS(w.tpcp_gt_bq_lym), 0) * 100 AS DOUBLE), '%',
    23, '2', '2. Thị trường trái phiếu', 'tpcp_gtgd_bq_nam', 'TPCP - GTGD bình quân năm báo cáo', CAST(w.tpcp_gt_bq_y AS DOUBLE), 'VND',
    24, '2', '2. Thị trường trái phiếu', 'tpcp_gtgd_bq_nam_pct', 'TPCP - GTGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.tpcp_gt_bq_y - w.tpcp_gt_bq_py) / NULLIF(ABS(w.tpcp_gt_bq_py), 0) * 100 AS DOUBLE), '%',
    25, '2', '2. Thị trường trái phiếu', 'tpcp_soma_niemyet', 'TPCP - Số mã trái phiếu niêm yết', CAST(w.so_ma_tpcp_cur AS DOUBLE), 'Mã',
    26, '2', '2. Thị trường trái phiếu', 'tpcp_gt_niemyet', 'TPCP - Giá trị niêm yết trái phiếu', CAST(w.gt_niemyet_tpcp_cur AS DOUBLE), 'VND',
    27, '2', '2. Thị trường trái phiếu', 'tpcp_gt_niemyet_pct_cuoinamtruoc', 'TPCP - Giá trị niêm yết trái phiếu - % so với cuối năm trước', CAST((w.gt_niemyet_tpcp_cur - w.gt_niemyet_tpcp_py) / NULLIF(ABS(w.gt_niemyet_tpcp_py), 0) * 100 AS DOUBLE), '%',
    28, '2', '2. Thị trường trái phiếu', 'tpcp_gt_niemyet_gdp_pct', 'TPCP - Giá trị niêm yết trái phiếu - % so với GDP năm', CAST(w.gt_niemyet_tpcp_cur / NULLIF(w.gdp_py, 0) * 100 AS DOUBLE), '%',
    29, '3', '3.1. Thị trường chứng khoán phái sinh', 'ps_klgd_bq_thang', 'HĐTL VN30 - KLGD bình quân/phiên tháng báo cáo', CAST(w.ps_hdtl_vn30_kl_bq_m AS DOUBLE), 'Hợp đồng',
    30, '3', '3.1. Thị trường chứng khoán phái sinh', 'ps_klgd_bq_thang_pct', 'HĐTL VN30 - KLGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.ps_hdtl_vn30_kl_bq_m - w.ps_hdtl_vn30_kl_bq_pm) / NULLIF(ABS(w.ps_hdtl_vn30_kl_bq_pm), 0) * 100 AS DOUBLE), '%',
    31, '3', '3.1. Thị trường chứng khoán phái sinh', 'ps_klgd_bq_thang_pct_cungky', 'HĐTL VN30 - KLGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.ps_hdtl_vn30_kl_bq_m - w.ps_hdtl_vn30_kl_bq_lym) / NULLIF(ABS(w.ps_hdtl_vn30_kl_bq_lym), 0) * 100 AS DOUBLE), '%',
    32, '3', '3.1. Thị trường chứng khoán phái sinh', 'ps_klgd_bq_nam', 'HĐTL VN30 - KLGD bình quân năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.ps_hdtl_vn30_kl_bq_y AS DOUBLE), 'Hợp đồng',
    33, '3', '3.1. Thị trường chứng khoán phái sinh', 'ps_klgd_bq_nam_pct', 'HĐTL VN30 - KLGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.ps_hdtl_vn30_kl_bq_y - w.ps_hdtl_vn30_kl_bq_py) / NULLIF(ABS(w.ps_hdtl_vn30_kl_bq_py), 0) * 100 AS DOUBLE), '%',
    34, '3', '3.1. Thị trường chứng khoán phái sinh', 'ps_oi', 'HĐTL VN30 - Khối lượng mở (OI) ngày báo cáo', CAST(w.oi_cur AS DOUBLE), 'Hợp đồng',
    35, '3', '3.1. Thị trường chứng khoán phái sinh', 'ps_oi_pct_cuoithangtruoc', 'HĐTL VN30 - Khối lượng mở (OI) - % so với cuối tháng trước', CAST((w.oi_cur - w.oi_pm) / NULLIF(ABS(w.oi_pm), 0) * 100 AS DOUBLE), '%',
    36, '3', '3.1. Thị trường chứng khoán phái sinh', 'ps_oi_pct_cuoinamtruoc', 'HĐTL VN30 - Khối lượng mở (OI) - % so với cuối năm trước', CAST((w.oi_cur - w.oi_py) / NULLIF(ABS(w.oi_py), 0) * 100 AS DOUBLE), '%',
    37, '4', '3.2. Chứng quyền', 'cw_klgd_bq_thang', 'CW - KLGD bình quân tháng báo cáo', CAST(w.cw_kl_bq_m AS DOUBLE), 'Chứng quyền',
    38, '4', '3.2. Chứng quyền', 'cw_klgd_bq_thang_pct', 'CW - KLGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.cw_kl_bq_m - w.cw_kl_bq_pm) / NULLIF(ABS(w.cw_kl_bq_pm), 0) * 100 AS DOUBLE), '%',
    39, '4', '3.2. Chứng quyền', 'cw_klgd_bq_thang_pct_cungky', 'CW - KLGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.cw_kl_bq_m - w.cw_kl_bq_lym) / NULLIF(ABS(w.cw_kl_bq_lym), 0) * 100 AS DOUBLE), '%',
    40, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_thang', 'CW - GTGD bình quân tháng báo cáo', CAST(w.cw_gt_bq_m AS DOUBLE), 'VND',
    41, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_thang_pct', 'CW - GTGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.cw_gt_bq_m - w.cw_gt_bq_pm) / NULLIF(ABS(w.cw_gt_bq_pm), 0) * 100 AS DOUBLE), '%',
    42, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_thang_pct_cungky', 'CW - GTGD bình quân tháng báo cáo - % so với bình quân cùng tháng năm trước', CAST((w.cw_gt_bq_m - w.cw_gt_bq_lym) / NULLIF(ABS(w.cw_gt_bq_lym), 0) * 100 AS DOUBLE), '%',
    43, '4', '3.2. Chứng quyền', 'cw_klgd_bq_nam', 'CW - KLGD bình quân năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.cw_kl_bq_y AS DOUBLE), 'Chứng quyền',
    44, '4', '3.2. Chứng quyền', 'cw_klgd_bq_nam_pct', 'CW - KLGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.cw_kl_bq_y - w.cw_kl_bq_py) / NULLIF(ABS(w.cw_kl_bq_py), 0) * 100 AS DOUBLE), '%',
    45, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_nam', 'CW - GTGD bình quân năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.cw_gt_bq_y AS DOUBLE), 'VND',
    46, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_nam_pct', 'CW - GTGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.cw_gt_bq_y - w.cw_gt_bq_py) / NULLIF(ABS(w.cw_gt_bq_py), 0) * 100 AS DOUBLE), '%',
    47, '5', '4. Hoạt động NĐT', 'ndtnn_rong_cp_ccq_thang', 'GT NĐTNN mua/bán ròng cổ phiếu, CCQ tháng báo cáo', CAST(w.cp_ccq_ndtnn_rong_m AS DOUBLE), 'VND',
    48, '5', '4. Hoạt động NĐT', 'ndtnn_rong_tpcp_thang', 'GT NĐTNN mua/bán ròng trái phiếu (TPCP) tháng báo cáo', CAST(w.tpcp_ndtnn_rong_m AS DOUBLE), 'VND',
    49, '5', '4. Hoạt động NĐT', 'ndtnn_rong_cp_ccq_nam', 'GT NĐTNN mua/bán ròng cổ phiếu, CCQ năm báo cáo', CAST(w.cp_ccq_ndtnn_rong_y AS DOUBLE), 'VND',
    50, '5', '4. Hoạt động NĐT', 'ndtnn_rong_tpcp_nam', 'GT NĐTNN mua/bán ròng trái phiếu (TPCP) năm báo cáo', CAST(w.tpcp_ndtnn_rong_y AS DOUBLE), 'VND',
    51, '6', '4. Hoạt động NĐT', 'tk_luyke_thang', 'Số lượng tài khoản của NĐT tính đến cuối tháng', CAST(w.tk_cur AS DOUBLE), 'TK',
    52, '6', '4. Hoạt động NĐT', 'tk_luyke_nam_pct', 'Số lượng tài khoản của NĐT - % so với cuối năm trước', CAST((w.tk_cur - w.tk_py) / NULLIF(ABS(w.tk_py), 0) * 100 AS DOUBLE), '%'
  ) AS (thu_tu, nhom_stt, nhom, metric_code, metric_name, gia_tri, don_vi)
  FROM w
) x
ORDER BY x.thu_tu
;