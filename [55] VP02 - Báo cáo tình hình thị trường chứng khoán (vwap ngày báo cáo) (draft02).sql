-- VP02 - BÁO CÁO TÌNH HÌNH THỊ TRƯỜNG CHỨNG KHOÁN: TÍNH TẠI 1 NGÀY BÁO CÁO
/* Tham số tra cứu:
 * :report_date  Ngày báo cáo (yyyy-MM-dd)
 *
 * Kết quả: mỗi dòng là 1 chỉ tiêu (metric_code), cột gia_tri + don_vi. Giá trị tiền tệ tính bằng VND (chia 1e9 ở frontend để hiển thị tỷ đồng).
 * Nhóm: 1. Thị trường cổ phiếu | 2. Thị trường trái phiếu | 3.1. Phái sinh (HĐTL VN30) | 3.2. Chứng quyền | 3.3. NĐTNN
 *
 * Quy ước chung:
 *  - Ngày dữ liệu (d_cur) = ngày giao dịch gần nhất <= ngày báo cáo; cuối tháng trước (d_pm), cuối năm trước (d_py) = ngày giao dịch cuối cùng <= 31 của tháng/năm trước.
 *    Lịch ngày giao dịch lấy từ chỉ số HOSE trong jad_marketinfor.
 *  - Bình quân tháng/năm = Tổng giá trị (khối lượng) / số phiên giao dịch của thị trường trong kỳ.
 *      + Tháng báo cáo: từ ngày 01 của tháng đến ngày báo cáo; so sánh với CẢ THÁNG TRƯỚC.
 *      + Năm báo cáo: từ 01/01 đến ngày báo cáo; so sánh với CẢ NĂM TRƯỚC (01/01 - 31/12).
 *  - Phân loại CK: bản ghi cuối ngày của jad_stockinfor (stocktype 1 = TPDNNY, 2 = CP, 3/6 = CCQ, floorcode 10 + stocktype 4 = CW, floorcode 03 + stocktype 4 + underlyingsymbol VN30 = HĐTL VN30).
 *  - NĐTNN: SUBSTR(số tài khoản, 4, 1) IN ('E','F').
 */
WITH
-- 1. Tham số: ngày báo cáo -> các mốc tháng, năm
params AS (
  SELECT
    report_date,
    month_start,
    ADD_MONTHS(month_start, -1) AS pm_start, -- Ngày đầu tháng trước
    DATE_SUB(month_start, 1) AS pm_end, -- Ngày cuối tháng trước
    year_start,
    ADD_MONTHS(year_start, -12) AS py_start, -- Ngày đầu năm trước
    DATE_SUB(year_start, 1) AS py_end, -- Ngày cuối năm trước
    YEAR(report_date) - 1 AS gdp_year -- Năm lấy GDP
  FROM (
    SELECT
      r AS report_date,
      CAST(DATE_TRUNC('MONTH', r) AS DATE) AS month_start,
      CAST(DATE_TRUNC('YEAR', r) AS DATE) AS year_start
    FROM (SELECT CAST(:report_date AS DATE) AS r)
  )
)
-- 2. Lịch ngày giao dịch (từ chỉ số HOSE): từ đầu năm trước đến ngày báo cáo
, cal AS (
  SELECT DISTINCT m.tradingdate
  FROM uat_mdds_stg.jad_marketinfor m
  CROSS JOIN params p
  WHERE m.marketcode = 'HOSE'
    AND m.tradingdate BETWEEN p.py_start AND p.report_date
)
-- 3. Các ngày dữ liệu cần lấy + số phiên giao dịch từng kỳ
, key_dates AS (
  SELECT
    MAX(CASE WHEN c.tradingdate <= p.report_date THEN c.tradingdate END) AS d_cur, -- Ngày dữ liệu gần nhất <= ngày báo cáo
    MAX(CASE WHEN c.tradingdate <= p.pm_end THEN c.tradingdate END) AS d_pm, -- Cuối tháng trước
    MAX(CASE WHEN c.tradingdate <= p.py_end THEN c.tradingdate END) AS d_py, -- Cuối năm trước
    SUM(CASE WHEN c.tradingdate BETWEEN p.month_start AND p.report_date THEN 1 ELSE 0 END) AS n_m, -- Số phiên tháng báo cáo
    SUM(CASE WHEN c.tradingdate BETWEEN p.pm_start AND p.pm_end THEN 1 ELSE 0 END) AS n_pm, -- Số phiên tháng trước
    SUM(CASE WHEN c.tradingdate BETWEEN p.year_start AND p.report_date THEN 1 ELSE 0 END) AS n_y, -- Số phiên năm báo cáo (YTD)
    SUM(CASE WHEN c.tradingdate BETWEEN p.py_start AND p.py_end THEN 1 ELSE 0 END) AS n_py -- Số phiên năm trước
  FROM cal c
  CROSS JOIN params p
)
-- 3b. Ngày tính vốn hóa, niêm yết: ngày gần nhất có dữ liệu KL lưu hành (VSDC) <= ngày báo cáo / <= cuối năm trước
, eq_dates AS (
  SELECT
    MAX(CASE WHEN o.snapshot_date <= p.report_date THEN o.snapshot_date END) AS e_cur,
    MAX(CASE WHEN o.snapshot_date <= p.py_end THEN o.snapshot_date END) AS e_py
  FROM uat_vsdc_stg.outstanding_shares o
  CROSS JOIN params p
  WHERE o.snapshot_date BETWEEN DATE_SUB(p.report_date, 30) AND p.report_date
     OR o.snapshot_date BETWEEN DATE_SUB(p.py_end, 30) AND p.py_end
)
-- 4. Chỉ số VN-Index, HNX-Index: bản ghi cuối ngày tại d_cur, cuối tháng trước, cuối năm trước
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
, idx AS (
  SELECT
    MAX(CASE WHEN i.marketcode = 'HOSE' AND i.tradingdate = k.d_cur THEN i.marketindex END) AS vn_cur,
    MAX(CASE WHEN i.marketcode = 'HOSE' AND i.tradingdate = k.d_pm THEN i.marketindex END) AS vn_pm,
    MAX(CASE WHEN i.marketcode = 'HOSE' AND i.tradingdate = k.d_py THEN i.marketindex END) AS vn_py,
    MAX(CASE WHEN i.marketcode = 'HNX' AND i.tradingdate = k.d_cur THEN i.marketindex END) AS hnx_cur,
    MAX(CASE WHEN i.marketcode = 'HNX' AND i.tradingdate = k.d_pm THEN i.marketindex END) AS hnx_pm,
    MAX(CASE WHEN i.marketcode = 'HNX' AND i.tradingdate = k.d_py THEN i.marketindex END) AS hnx_py
  FROM index_eod i
  CROSS JOIN key_dates k
)
-- 5. Danh sách mã chứng khoán: lấy bản ghi cuối ngày trong jad_stockinfor -> phân loại; đọc từ đầu năm trước đến ngày báo cáo
, stock_eod AS (
  SELECT
    tradingdate, symbol, symbolisin, floorcode, stocktype, closeprice, vwap, reference,
    CASE
      WHEN stocktype = '1' THEN 'TPDNNY' -- TPDN niêm yết
      WHEN stocktype = '2' THEN 'CP' -- Cổ phiếu
      WHEN stocktype IN ('3', '6') THEN 'CCQ' -- Chứng chỉ quỹ (gồm ETF)
      WHEN floorcode = '10' AND stocktype = '4' THEN 'CW' -- Chứng quyền
      WHEN floorcode = '03' AND stocktype = '4' AND underlyingsymbol = 'VN30' THEN 'PS_VN30' -- HĐTL VN30
    END AS loai_ck
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.symbolisin, s.floorcode, s.stocktype, s.underlyingsymbol,
      s.closeprice, s.vwap, s.reference,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN params p
    WHERE s.tradingdate BETWEEN p.py_start AND p.report_date
  )
  WHERE rn = 1 -- Bản ghi cuối mỗi ngày
)
-- 6. Giao dịch theo ngày x loại CK: GTGD, KLGD, GT NĐTNN mua/bán (từ đầu năm trước đến ngày báo cáo)
, trade_daily AS (
  -- 6.1. HOSE: Cổ phiếu, CCQ, Chứng quyền
  SELECT
    h.trade_date AS trade_date,
    s.loai_ck,
    SUM(h.execution_value) AS gtgd,
    SUM(h.execution_volume) AS klgd,
    SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS ndtnn_mua,
    SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS ndtnn_ban
  FROM uat_hose_stg.trade_book h
  JOIN stock_eod s ON h.symbol = s.symbol AND h.trade_date = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id = 'STK'
    AND h.trade_date BETWEEN p.py_start AND p.report_date
    AND s.loai_ck IN ('CP', 'CCQ', 'CW')
  GROUP BY h.trade_date, s.loai_ck
  UNION ALL
  -- 6.2. HNX + UPCoM: Cổ phiếu, CCQ, TPDN niêm yết (HCX), HĐTL VN30 (DVX); join với jad_stockinfor theo mã ISIN
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    s.loai_ck,
    SUM(h.trade_quantity * h.trade_price) AS gtgd, -- Với HĐTL: không nhân hệ số hợp đồng (chỉ dùng KLGD)
    SUM(h.trade_quantity) AS klgd,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ndtnn_mua,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ndtnn_ban
  FROM uat_hnx_stg.trade_book h
  JOIN stock_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id IN ('STX', 'UPX', 'HCX', 'DVX')
    AND h.trade_date BETWEEN DATE_FORMAT(p.py_start, 'yyyyMMdd') AND DATE_FORMAT(p.report_date, 'yyyyMMdd')
    AND s.loai_ck IN ('CP', 'CCQ', 'TPDNNY', 'PS_VN30')
  GROUP BY h.trade_date, s.loai_ck
)
-- 7. Tổng hợp giao dịch theo kỳ: tháng báo cáo (m), tháng trước (pm), năm báo cáo đến ngày báo cáo (y), năm trước (py)
, trade_agg AS (
  SELECT
    SUM(CASE WHEN d.loai_ck = 'CP' AND d.trade_date BETWEEN p.month_start AND p.report_date THEN d.gtgd ELSE 0 END) AS cp_gt_m,
    SUM(CASE WHEN d.loai_ck = 'CP' AND d.trade_date BETWEEN p.pm_start AND p.pm_end THEN d.gtgd ELSE 0 END) AS cp_gt_pm,
    SUM(CASE WHEN d.loai_ck = 'CP' AND d.trade_date BETWEEN p.year_start AND p.report_date THEN d.gtgd ELSE 0 END) AS cp_gt_y,
    SUM(CASE WHEN d.loai_ck = 'CP' AND d.trade_date BETWEEN p.py_start AND p.py_end THEN d.gtgd ELSE 0 END) AS cp_gt_py,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' AND d.trade_date BETWEEN p.month_start AND p.report_date THEN d.gtgd ELSE 0 END) AS tp_gt_m,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' AND d.trade_date BETWEEN p.pm_start AND p.pm_end THEN d.gtgd ELSE 0 END) AS tp_gt_pm,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' AND d.trade_date BETWEEN p.year_start AND p.report_date THEN d.gtgd ELSE 0 END) AS tp_gt_y,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' AND d.trade_date BETWEEN p.py_start AND p.py_end THEN d.gtgd ELSE 0 END) AS tp_gt_py,
    SUM(CASE WHEN d.loai_ck = 'CW' AND d.trade_date BETWEEN p.month_start AND p.report_date THEN d.gtgd ELSE 0 END) AS cw_gt_m,
    SUM(CASE WHEN d.loai_ck = 'CW' AND d.trade_date BETWEEN p.month_start AND p.report_date THEN d.klgd ELSE 0 END) AS cw_kl_m,
    SUM(CASE WHEN d.loai_ck = 'CW' AND d.trade_date BETWEEN p.pm_start AND p.pm_end THEN d.gtgd ELSE 0 END) AS cw_gt_pm,
    SUM(CASE WHEN d.loai_ck = 'CW' AND d.trade_date BETWEEN p.pm_start AND p.pm_end THEN d.klgd ELSE 0 END) AS cw_kl_pm,
    SUM(CASE WHEN d.loai_ck = 'CW' AND d.trade_date BETWEEN p.year_start AND p.report_date THEN d.gtgd ELSE 0 END) AS cw_gt_y,
    SUM(CASE WHEN d.loai_ck = 'CW' AND d.trade_date BETWEEN p.year_start AND p.report_date THEN d.klgd ELSE 0 END) AS cw_kl_y,
    SUM(CASE WHEN d.loai_ck = 'CW' AND d.trade_date BETWEEN p.py_start AND p.py_end THEN d.gtgd ELSE 0 END) AS cw_gt_py,
    SUM(CASE WHEN d.loai_ck = 'CW' AND d.trade_date BETWEEN p.py_start AND p.py_end THEN d.klgd ELSE 0 END) AS cw_kl_py,
    SUM(CASE WHEN d.loai_ck = 'PS_VN30' AND d.trade_date BETWEEN p.month_start AND p.report_date THEN d.klgd ELSE 0 END) AS ps_kl_m,
    SUM(CASE WHEN d.loai_ck = 'PS_VN30' AND d.trade_date BETWEEN p.pm_start AND p.pm_end THEN d.klgd ELSE 0 END) AS ps_kl_pm,
    SUM(CASE WHEN d.loai_ck = 'PS_VN30' AND d.trade_date BETWEEN p.year_start AND p.report_date THEN d.klgd ELSE 0 END) AS ps_kl_y,
    SUM(CASE WHEN d.loai_ck = 'PS_VN30' AND d.trade_date BETWEEN p.py_start AND p.py_end THEN d.klgd ELSE 0 END) AS ps_kl_py,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') AND d.trade_date BETWEEN p.month_start AND p.report_date THEN (d.ndtnn_mua - d.ndtnn_ban) ELSE 0 END) AS nn_cpccq_m,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' AND d.trade_date BETWEEN p.month_start AND p.report_date THEN (d.ndtnn_mua - d.ndtnn_ban) ELSE 0 END) AS nn_tp_m,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') AND d.trade_date BETWEEN p.year_start AND p.report_date THEN (d.ndtnn_mua - d.ndtnn_ban) ELSE 0 END) AS nn_cpccq_y,
    SUM(CASE WHEN d.loai_ck = 'TPDNNY' AND d.trade_date BETWEEN p.year_start AND p.report_date THEN (d.ndtnn_mua - d.ndtnn_ban) ELSE 0 END) AS nn_tp_y
  FROM trade_daily d
  CROSS JOIN params p
)
-- 8. Khối lượng lưu hành cuối ngày (VSDC) tại các ngày cần lấy: 1 dòng / (ngày, mã)
, os_eod AS (
  SELECT o.snapshot_date, o.ticker_symbol, MAX(o.outstanding_shares) AS outstanding_shares
  FROM uat_vsdc_stg.outstanding_shares o
  CROSS JOIN eq_dates k
  WHERE o.snapshot_date IN (k.e_cur, k.e_py)
  GROUP BY o.snapshot_date, o.ticker_symbol
)
-- 9. Cổ phiếu, CCQ niêm yết/ĐKGD tại ngày gần nhất có dữ liệu (CUR) và cuối năm trước (PY): giá tính vốn hóa, KL lưu hành
----  HOSE, HNX (floorcode 02, 10): Giá đóng cửa
----  UPCoM (floorcode 04): Giá trung bình = vwap tại ngày tính; nếu vwap = 0 thì lấy giá tham chiếu cùng ngày
, equity_src AS (
  SELECT
    x.pt, x.symbol, x.floorcode, x.stocktype, x.price, os.outstanding_shares
  FROM (
    SELECT
      'CUR' AS pt, s.tradingdate, s.symbol, s.floorcode, s.stocktype,
      CASE WHEN s.floorcode IN ('02', '10') THEN s.closeprice ELSE COALESCE(NULLIF(s.vwap, 0), s.reference) END AS price
    FROM stock_eod s
    CROSS JOIN eq_dates k
    WHERE s.tradingdate = k.e_cur
      AND ((s.floorcode IN ('02', '10') AND s.stocktype IN ('2', '3', '6')) OR (s.floorcode = '04' AND s.stocktype = '2'))
    UNION ALL
    SELECT
      'PY' AS pt, s.tradingdate, s.symbol, s.floorcode, s.stocktype,
      CASE WHEN s.floorcode IN ('02', '10') THEN s.closeprice ELSE COALESCE(NULLIF(s.vwap, 0), s.reference) END AS price
    FROM stock_eod s
    CROSS JOIN eq_dates k
    WHERE s.tradingdate = k.e_py
      AND ((s.floorcode IN ('02', '10') AND s.stocktype IN ('2', '3', '6')) OR (s.floorcode = '04' AND s.stocktype = '2'))
  ) x
  LEFT JOIN os_eod os ON os.snapshot_date = x.tradingdate AND os.ticker_symbol = x.symbol
)
, equity_agg AS (
  SELECT
    pt,
    SUM(CASE WHEN stocktype = '2' THEN price * outstanding_shares END) AS von_hoa, -- Vốn hóa: chỉ cổ phiếu
    COUNT(DISTINCT CASE WHEN floorcode IN ('02', '10') THEN symbol END) AS so_ma_hnx_hose, -- CP, CCQ niêm yết HNX, HOSE
    COUNT(DISTINCT CASE WHEN floorcode = '04' THEN symbol END) AS so_ma_upcom, -- CP ĐKGD UPCoM
    SUM(10000 * outstanding_shares) AS gt_niemyet -- Mệnh giá 10.000 x KL lưu hành
  FROM equity_src
  GROUP BY pt
)
-- 10. TPDN niêm yết tại ngày gần nhất có danh sách niêm yết (CUR) và cuối năm trước (PY): số mã, giá trị niêm yết = KL niêm yết x mệnh giá
---- Mệnh giá TPDN niêm yết: tính ngược từ giá tham chiếu (bội số của 100.000, nhảy bậc x10) - như script TPDNNY hiện có
, bond_dates AS (
  SELECT
    MAX(CASE WHEN l.report_date <= p.report_date THEN l.report_date END) AS b_cur,
    MAX(CASE WHEN l.report_date <= p.py_end THEN l.report_date END) AS b_py
  FROM uat_hnx_stg.listed_securities_list l
  CROSS JOIN params p
  WHERE l.report_date BETWEEN DATE_SUB(p.report_date, 30) AND p.report_date
     OR l.report_date BETWEEN DATE_SUB(p.py_end, 30) AND p.py_end
)
, bond_src AS (
  SELECT
    CASE WHEN s.tradingdate = k.b_cur THEN 'CUR' ELSE 'PY' END AS pt,
    s.symbol,
    ls.outstanding_shares * 100000 * POWER(10, ROUND(LN(NULLIF(CAST(s.reference AS DOUBLE), 0) / 100000) / LN(10))) AS gt_niemyet
  FROM stock_eod s
  CROSS JOIN bond_dates k
  LEFT JOIN uat_hnx_stg.listed_securities_list ls ON ls.report_date = s.tradingdate AND ls.ticker_symbol = s.symbol
  WHERE s.stocktype = '1' -- TPDN niêm yết
    AND s.tradingdate IN (k.b_cur, k.b_py)
)
, bond_agg AS (
  SELECT pt, COUNT(DISTINCT symbol) AS so_ma, SUM(gt_niemyet) AS gt_niemyet
  FROM bond_src
  GROUP BY pt
)
-- 11. Khối lượng mở (OI) HĐTL VN30: Tại d_cur, cuối tháng trước, cuối năm trước
, oi AS (
  SELECT
    SUM(CASE WHEN o.report_date = k.d_cur THEN o.open_interest_volume END) AS oi_cur,
    SUM(CASE WHEN o.report_date = k.d_pm THEN o.open_interest_volume END) AS oi_pm,
    SUM(CASE WHEN o.report_date = k.d_py THEN o.open_interest_volume END) AS oi_py
  FROM uat_vsdc_stg.end_of_day_open_interest o
  CROSS JOIN key_dates k
  JOIN stock_eod s ON o.report_date = s.tradingdate AND o.contract_code = s.symbol AND s.loai_ck = 'PS_VN30'
  WHERE o.report_date IN (k.d_cur, k.d_pm, k.d_py)
)
-- 12. GDP năm trước (năm báo cáo - 1), quy đổi về VND: unit_code 3 = Tỷ VND, 8 = VND, 23 = Triệu VND
, gdp AS (
  SELECT gdp_py
  FROM (
    SELECT
      CASE CAST(t.unit_code AS STRING)
        WHEN '3' THEN TRY_CAST(t.value AS DOUBLE) * 1000000000
        WHEN '8' THEN TRY_CAST(t.value AS DOUBLE)
        WHEN '23' THEN TRY_CAST(t.value AS DOUBLE) * 1000000
      END AS gdp_py,
      ROW_NUMBER() OVER(ORDER BY CASE WHEN CAST(t.data_origin AS STRING) = '2' THEN 0 ELSE 1 END, t.period_date DESC) AS rn -- Ưu tiên dữ liệu user chỉnh sửa (data_origin = 2)
    FROM uat_mrms_stg.risk_indicator_value t
    LEFT JOIN uat_mrms_stg.risk_indicator i ON i.id = t.indicator_id
    CROSS JOIN params p
    WHERE t.deleted = '0'
      AND i.indicator_code = 'GDP_VN'
      AND CAST(t.period_type AS STRING) = '4' -- GDP theo năm
      AND CAST(t.period_year AS INT) = p.gdp_year
  )
  WHERE rn = 1
)
-- 13. Gom các giá trị về 1 dòng; bình quân = tổng / số phiên của kỳ
, w AS (
  SELECT
    idx.vn_cur, idx.vn_pm, idx.vn_py, idx.hnx_cur, idx.hnx_pm, idx.hnx_py,
    ec.von_hoa AS vh_cur, ep.von_hoa AS vh_py,
    ec.so_ma_hnx_hose AS sm_hh_cur, ec.so_ma_upcom AS sm_up_cur,
    ec.gt_niemyet AS gtny_cur, ep.gt_niemyet AS gtny_py,
    bc.so_ma AS tp_sm_cur, bc.gt_niemyet AS tp_gtny_cur, bp.gt_niemyet AS tp_gtny_py,
    oi.oi_cur, oi.oi_pm, oi.oi_py,
    gdp.gdp_py,
    ta.cp_gt_m / NULLIF(ss.n_m, 0) AS cp_gt_m,
    ta.cp_gt_pm / NULLIF(ss.n_pm, 0) AS cp_gt_pm,
    ta.cp_gt_y / NULLIF(ss.n_y, 0) AS cp_gt_y,
    ta.cp_gt_py / NULLIF(ss.n_py, 0) AS cp_gt_py,
    ta.tp_gt_m / NULLIF(ss.n_m, 0) AS tp_gt_m,
    ta.tp_gt_pm / NULLIF(ss.n_pm, 0) AS tp_gt_pm,
    ta.tp_gt_y / NULLIF(ss.n_y, 0) AS tp_gt_y,
    ta.tp_gt_py / NULLIF(ss.n_py, 0) AS tp_gt_py,
    ta.cw_gt_m / NULLIF(ss.n_m, 0) AS cw_gt_m,
    ta.cw_gt_pm / NULLIF(ss.n_pm, 0) AS cw_gt_pm,
    ta.cw_gt_y / NULLIF(ss.n_y, 0) AS cw_gt_y,
    ta.cw_gt_py / NULLIF(ss.n_py, 0) AS cw_gt_py,
    ta.cw_kl_m / NULLIF(ss.n_m, 0) AS cw_kl_m,
    ta.cw_kl_pm / NULLIF(ss.n_pm, 0) AS cw_kl_pm,
    ta.cw_kl_y / NULLIF(ss.n_y, 0) AS cw_kl_y,
    ta.cw_kl_py / NULLIF(ss.n_py, 0) AS cw_kl_py,
    ta.ps_kl_m / NULLIF(ss.n_m, 0) AS ps_kl_m,
    ta.ps_kl_pm / NULLIF(ss.n_pm, 0) AS ps_kl_pm,
    ta.ps_kl_y / NULLIF(ss.n_y, 0) AS ps_kl_y,
    ta.ps_kl_py / NULLIF(ss.n_py, 0) AS ps_kl_py,
    ta.nn_cpccq_m AS nn_cpccq_m,
    ta.nn_tp_m AS nn_tp_m,
    ta.nn_cpccq_y AS nn_cpccq_y,
    ta.nn_tp_y AS nn_tp_y
  FROM trade_agg ta
  CROSS JOIN key_dates ss
  CROSS JOIN idx
  CROSS JOIN oi
  LEFT JOIN gdp ON 1 = 1
  LEFT JOIN (SELECT * FROM equity_agg WHERE pt = 'CUR') ec ON 1 = 1
  LEFT JOIN (SELECT * FROM equity_agg WHERE pt = 'PY') ep ON 1 = 1
  LEFT JOIN (SELECT * FROM bond_agg WHERE pt = 'CUR') bc ON 1 = 1
  LEFT JOIN (SELECT * FROM bond_agg WHERE pt = 'PY') bp ON 1 = 1
)
-- 14. Dữ liệu lên dashboard: mỗi dòng 1 chỉ tiêu
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
  SELECT STACK(45,
    1, '1', '1. Thị trường cổ phiếu', 'cp_vnindex', 'Chỉ số VN-Index ngày báo cáo', CAST(w.vn_cur AS DOUBLE), 'Điểm',
    2, '1', '1. Thị trường cổ phiếu', 'cp_vnindex_pct_cuoithangtruoc', 'Chỉ số VN-Index - % so với cuối tháng trước', CAST((w.vn_cur - w.vn_pm) / NULLIF(ABS(w.vn_pm), 0) * 100 AS DOUBLE), '%',
    3, '1', '1. Thị trường cổ phiếu', 'cp_vnindex_pct_cuoinamtruoc', 'Chỉ số VN-Index - % so với cuối năm trước', CAST((w.vn_cur - w.vn_py) / NULLIF(ABS(w.vn_py), 0) * 100 AS DOUBLE), '%',
    4, '1', '1. Thị trường cổ phiếu', 'cp_hnxindex', 'Chỉ số HNX-Index ngày báo cáo', CAST(w.hnx_cur AS DOUBLE), 'Điểm',
    5, '1', '1. Thị trường cổ phiếu', 'cp_hnxindex_pct_cuoithangtruoc', 'Chỉ số HNX-Index - % so với cuối tháng trước', CAST((w.hnx_cur - w.hnx_pm) / NULLIF(ABS(w.hnx_pm), 0) * 100 AS DOUBLE), '%',
    6, '1', '1. Thị trường cổ phiếu', 'cp_hnxindex_pct_cuoinamtruoc', 'Chỉ số HNX-Index - % so với cuối năm trước', CAST((w.hnx_cur - w.hnx_py) / NULLIF(ABS(w.hnx_py), 0) * 100 AS DOUBLE), '%',
    7, '1', '1. Thị trường cổ phiếu', 'cp_vonhoa', 'Vốn hóa thị trường cổ phiếu', CAST(w.vh_cur AS DOUBLE), 'VND',
    8, '1', '1. Thị trường cổ phiếu', 'cp_vonhoa_pct_cuoinamtruoc', 'Vốn hóa thị trường cổ phiếu - % so với cuối năm trước', CAST((w.vh_cur - w.vh_py) / NULLIF(ABS(w.vh_py), 0) * 100 AS DOUBLE), '%',
    9, '1', '1. Thị trường cổ phiếu', 'cp_vonhoa_gdp_pct', 'Tỷ lệ vốn hóa/GDP năm trước', CAST(w.vh_cur / NULLIF(w.gdp_py, 0) * 100 AS DOUBLE), '%',
    10, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_thang', 'GTGD bình quân/phiên tháng báo cáo', CAST(w.cp_gt_m AS DOUBLE), 'VND',
    11, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_thang_pct', 'GTGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.cp_gt_m - w.cp_gt_pm) / NULLIF(ABS(w.cp_gt_pm), 0) * 100 AS DOUBLE), '%',
    12, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_nam', 'GTGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.cp_gt_y AS DOUBLE), 'VND',
    13, '1', '1. Thị trường cổ phiếu', 'cp_gtgd_bq_nam_pct', 'GTGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.cp_gt_y - w.cp_gt_py) / NULLIF(ABS(w.cp_gt_py), 0) * 100 AS DOUBLE), '%',
    14, '1', '1. Thị trường cổ phiếu', 'cp_soma_cp_ccq_hnx_hose', 'Số mã cổ phiếu, CCQ niêm yết trên HNX, HOSE', CAST(w.sm_hh_cur AS DOUBLE), 'Mã',
    15, '1', '1. Thị trường cổ phiếu', 'cp_soma_cp_upcom', 'Số mã cổ phiếu ĐKGD trên UPCoM', CAST(w.sm_up_cur AS DOUBLE), 'Mã',
    16, '1', '1. Thị trường cổ phiếu', 'cp_gt_niemyet', 'Tổng giá trị niêm yết, ĐKGD (mệnh giá 10.000 x KL lưu hành)', CAST(w.gtny_cur AS DOUBLE), 'VND',
    17, '1', '1. Thị trường cổ phiếu', 'cp_gt_niemyet_pct_cuoinamtruoc', 'Tổng giá trị niêm yết, ĐKGD - % so với cuối năm trước', CAST((w.gtny_cur - w.gtny_py) / NULLIF(ABS(w.gtny_py), 0) * 100 AS DOUBLE), '%',
    18, '1', '1. Thị trường cổ phiếu', 'cp_gt_niemyet_gdp_pct', 'Tổng giá trị niêm yết, ĐKGD - % so với GDP năm trước', CAST(w.gtny_cur / NULLIF(w.gdp_py, 0) * 100 AS DOUBLE), '%',
    19, '2', '2. Thị trường trái phiếu', 'tp_gtgd_bq_thang', 'GTGD bình quân/phiên tháng báo cáo', CAST(w.tp_gt_m AS DOUBLE), 'VND',
    20, '2', '2. Thị trường trái phiếu', 'tp_gtgd_bq_thang_pct', 'GTGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.tp_gt_m - w.tp_gt_pm) / NULLIF(ABS(w.tp_gt_pm), 0) * 100 AS DOUBLE), '%',
    21, '2', '2. Thị trường trái phiếu', 'tp_gtgd_bq_nam', 'GTGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.tp_gt_y AS DOUBLE), 'VND',
    22, '2', '2. Thị trường trái phiếu', 'tp_gtgd_bq_nam_pct', 'GTGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.tp_gt_y - w.tp_gt_py) / NULLIF(ABS(w.tp_gt_py), 0) * 100 AS DOUBLE), '%',
    23, '2', '2. Thị trường trái phiếu', 'tp_soma_niemyet', 'Số mã trái phiếu niêm yết (TPDN niêm yết)', CAST(w.tp_sm_cur AS DOUBLE), 'Mã',
    24, '2', '2. Thị trường trái phiếu', 'tp_gt_niemyet', 'Giá trị niêm yết trái phiếu (TPDN niêm yết)', CAST(w.tp_gtny_cur AS DOUBLE), 'VND',
    25, '2', '2. Thị trường trái phiếu', 'tp_gt_niemyet_pct_cuoinamtruoc', 'Giá trị niêm yết trái phiếu - % so với cuối năm trước', CAST((w.tp_gtny_cur - w.tp_gtny_py) / NULLIF(ABS(w.tp_gtny_py), 0) * 100 AS DOUBLE), '%',
    26, '2', '2. Thị trường trái phiếu', 'tp_gt_niemyet_gdp_pct', 'Giá trị niêm yết trái phiếu - % so với GDP năm trước', CAST(w.tp_gtny_cur / NULLIF(w.gdp_py, 0) * 100 AS DOUBLE), '%',
    27, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_klgd_bq_thang', 'KLGD bình quân/phiên tháng báo cáo', CAST(w.ps_kl_m AS DOUBLE), 'Hợp đồng',
    28, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_klgd_bq_thang_pct', 'KLGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.ps_kl_m - w.ps_kl_pm) / NULLIF(ABS(w.ps_kl_pm), 0) * 100 AS DOUBLE), '%',
    29, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_klgd_bq_nam', 'KLGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.ps_kl_y AS DOUBLE), 'Hợp đồng',
    30, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_klgd_bq_nam_pct', 'KLGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.ps_kl_y - w.ps_kl_py) / NULLIF(ABS(w.ps_kl_py), 0) * 100 AS DOUBLE), '%',
    31, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_oi', 'Khối lượng mở (OI)', CAST(w.oi_cur AS DOUBLE), 'Hợp đồng',
    32, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_oi_pct_cuoithangtruoc', 'Khối lượng mở (OI) - % so với cuối tháng trước', CAST((w.oi_cur - w.oi_pm) / NULLIF(ABS(w.oi_pm), 0) * 100 AS DOUBLE), '%',
    33, '3', '3.1. Thị trường chứng khoán phái sinh - HĐTL VN30', 'ps_oi_pct_cuoinamtruoc', 'Khối lượng mở (OI) - % so với cuối năm trước', CAST((w.oi_cur - w.oi_py) / NULLIF(ABS(w.oi_py), 0) * 100 AS DOUBLE), '%',
    34, '4', '3.2. Chứng quyền', 'cw_klgd_bq_thang', 'KLGD bình quân/phiên tháng báo cáo', CAST(w.cw_kl_m AS DOUBLE), 'Chứng quyền',
    35, '4', '3.2. Chứng quyền', 'cw_klgd_bq_thang_pct', 'KLGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.cw_kl_m - w.cw_kl_pm) / NULLIF(ABS(w.cw_kl_pm), 0) * 100 AS DOUBLE), '%',
    36, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_thang', 'GTGD bình quân/phiên tháng báo cáo', CAST(w.cw_gt_m AS DOUBLE), 'VND',
    37, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_thang_pct', 'GTGD bình quân tháng báo cáo - % so với bình quân tháng trước', CAST((w.cw_gt_m - w.cw_gt_pm) / NULLIF(ABS(w.cw_gt_pm), 0) * 100 AS DOUBLE), '%',
    38, '4', '3.2. Chứng quyền', 'cw_klgd_bq_nam', 'KLGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.cw_kl_y AS DOUBLE), 'Chứng quyền',
    39, '4', '3.2. Chứng quyền', 'cw_klgd_bq_nam_pct', 'KLGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.cw_kl_y - w.cw_kl_py) / NULLIF(ABS(w.cw_kl_py), 0) * 100 AS DOUBLE), '%',
    40, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_nam', 'GTGD bình quân/phiên năm báo cáo (từ đầu năm đến ngày báo cáo)', CAST(w.cw_gt_y AS DOUBLE), 'VND',
    41, '4', '3.2. Chứng quyền', 'cw_gtgd_bq_nam_pct', 'GTGD bình quân năm báo cáo - % so với bình quân năm trước', CAST((w.cw_gt_y - w.cw_gt_py) / NULLIF(ABS(w.cw_gt_py), 0) * 100 AS DOUBLE), '%',
    42, '5', '3.3. Hoạt động NĐTNN (tháng/năm báo cáo, tính đến ngày báo cáo)', 'ndtnn_rong_cp_ccq_thang', 'GT NĐTNN mua/bán ròng cổ phiếu, CCQ tháng báo cáo', CAST(w.nn_cpccq_m AS DOUBLE), 'VND',
    43, '5', '3.3. Hoạt động NĐTNN (tháng/năm báo cáo, tính đến ngày báo cáo)', 'ndtnn_rong_tpdnny_thang', 'GT NĐTNN mua/bán ròng trái phiếu (TPDN niêm yết) tháng báo cáo', CAST(w.nn_tp_m AS DOUBLE), 'VND',
    44, '5', '3.3. Hoạt động NĐTNN (tháng/năm báo cáo, tính đến ngày báo cáo)', 'ndtnn_rong_cp_ccq_nam', 'GT NĐTNN mua/bán ròng cổ phiếu, CCQ năm báo cáo', CAST(w.nn_cpccq_y AS DOUBLE), 'VND',
    45, '5', '3.3. Hoạt động NĐTNN (tháng/năm báo cáo, tính đến ngày báo cáo)', 'ndtnn_rong_tpdnny_nam', 'GT NĐTNN mua/bán ròng trái phiếu (TPDN niêm yết) năm báo cáo', CAST(w.nn_tp_y AS DOUBLE), 'VND'
  ) AS (thu_tu, nhom_stt, nhom, metric_code, metric_name, gia_tri, don_vi)
  FROM w
) x
ORDER BY x.thu_tu
;
