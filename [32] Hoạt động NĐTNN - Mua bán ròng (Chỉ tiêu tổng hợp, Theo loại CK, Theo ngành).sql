-- HOẠT ĐỘNG NĐTNN >> MUA/BÁN RÒNG: TÍNH TẠI 1 KỲ
/* Tham số tra cứu:
 * :period_type  Loại kỳ: D/M/Q/Y
 * :period_to    Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 *
 * Gồm 3 câu lệnh độc lập, mỗi câu cho 1 widget:
 *   NHÓM 1: Chỉ tiêu tổng hợp (4 thẻ KPI)
 *   NHÓM 2: Chi tiết giao dịch theo loại chứng khoán (bảng)
 *   NHÓM 3: Mua/bán ròng cổ phiếu NĐTNN theo nhóm ngành (biểu đồ)
 * Đơn vị: VND (chia 1e9 ở frontend để hiển thị "Tỷ đồng").
 * Nhận diện Giao dịch của NĐTNN: Ký tự thứ 4 trong số tài khoản giao dịch IN ('E','F')
 */

-- ======================================================================================
-- NHÓM 1: CHỈ TIÊU TỔNG HỢP
--   * GT mua/bán ròng (kỳ), GT NĐTNN mua, GT NĐTNN bán : so sánh với KỲ TRƯỚC
--   * GT mua/bán ròng YTD                              : so sánh với CÙNG KỲ NĂM TRƯỚC (YTD năm trước)
--   Phạm vi tổng: CP + CCQ + CW + TPCP + TPDNNY + TPDNRL.
--   Phái sinh (GT danh nghĩa) mặc định KHÔNG cộng vào tổng -> muốn cộng, bỏ dòng "AND d.loai_ck <> 'PS'" ở CTE kpi.
-- ======================================================================================
WITH
-- 1. Tham số tra cứu: Loại kỳ (D/M/Q/Y) + Kỳ báo cáo -> ngày đầu/cuối kỳ này, kỳ trước, YTD, YTD cùng kỳ năm trước
params AS (
  SELECT
    x.*,
    CAST(DATE_TRUNC('YEAR', x.period_to_startdate) AS DATE) AS ytd_startdate, -- Ngày đầu năm của kỳ này
    ADD_MONTHS(CAST(DATE_TRUNC('YEAR', x.period_to_startdate) AS DATE), -12) AS ytd_py_startdate, -- Ngày đầu năm trước
    CASE WHEN x.period_type = 'D' THEN ADD_MONTHS(x.period_to_enddate, -12)
       ELSE LAST_DAY(ADD_MONTHS(x.period_to_enddate, -12)) -- Kỳ M/Q/Y kết thúc cuối tháng -> giữ cuối tháng (tránh lệch 28/29-02)
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
      WHEN stocktype = '2' THEN 'CP' -- Cổ phiếu
      WHEN stocktype IN ('3', '6') THEN 'CCQ' -- Chứng chỉ quỹ (gồm ETF)
      WHEN floorcode = '10' AND stocktype = '4' THEN 'CW' -- Chứng quyền
      WHEN floorcode = '03' AND stocktype IN ('4', '5') THEN 'PS' -- Phái sinh: HĐTL (4), HĐ quyền chọn (5)
    END AS loai_ck
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.symbolisin, s.floorcode, s.stocktype,
      CAST(s.contractmultiplier AS DOUBLE) AS contractmultiplier,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN params p
    WHERE s.tradingdate BETWEEN p.ytd_py_startdate AND p.period_to_enddate
      AND s.stocktype IN ('2', '3', '4', '5', '6') -- Bỏ trái phiếu (stocktype = '1'): TP đi theo nguồn riêng bên dưới
  )
  WHERE rn = 1 -- Bản ghi cuối mỗi ngày
)
-- 3. GT NĐTNN mua/bán theo ngày x loại chứng khoán (NĐTNN: ký tự thứ 4 của số tài khoản IN ('E','F'))
, trade_daily AS (
  -- 3.1. HOSE: Cổ phiếu, CCQ, Chứng quyền
  SELECT
    h.trade_date AS trade_date,
    s.loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS ban_gt
  FROM uat_hose_stg.trade_book h
  JOIN stock_daily_eod s ON h.symbol = s.symbol AND h.trade_date = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id = 'STK'
    AND s.loai_ck IN ('CP', 'CCQ', 'CW')
    AND h.trade_date BETWEEN p.ytd_py_startdate AND p.period_to_enddate
  GROUP BY h.trade_date, s.loai_ck
  UNION ALL
  -- 3.2. HNX + UPCoM: Cổ phiếu, CCQ (trade_date kiểu string yyyyMMdd; join theo mã ISIN)
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    s.loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ban_gt
  FROM uat_hnx_stg.trade_book h
  JOIN stock_daily_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id IN ('STX', 'UPX')
    AND s.loai_ck IN ('CP', 'CCQ', 'CW')
    AND h.trade_date BETWEEN DATE_FORMAT(p.ytd_py_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
  GROUP BY h.trade_date, s.loai_ck
  UNION ALL
  -- 3.3. Phái sinh (HNX - DVX): GT = KL x Giá x Hệ số nhân hợp đồng (contractmultiplier trong jad_stockinfor)
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    s.loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price * s.contractmultiplier ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price * s.contractmultiplier ELSE 0 END) AS ban_gt
  FROM uat_hnx_stg.trade_book h
  JOIN stock_daily_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id = 'DVX'
    AND s.loai_ck = 'PS'
    AND h.trade_date BETWEEN DATE_FORMAT(p.ytd_py_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
  GROUP BY h.trade_date, s.loai_ck
  UNION ALL
  -- 3.4. TPCP: Sổ lệnh outright đã thực hiện (ĐTH)
  SELECT
    o.trading_date AS trade_date,
    'TPCP' AS loai_ck,
    SUM(CASE WHEN SUBSTR(o.buying_account_no, 4, 1) IN ('E', 'F') THEN o.trading_value ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(o.selling_account_no, 4, 1) IN ('E', 'F') THEN o.trading_value ELSE 0 END) AS ban_gt
  FROM uat_hnx_stg.outright_order_book o
  CROSS JOIN params p
  WHERE o.order_status = 'ĐTH'
    AND o.trading_date BETWEEN p.ytd_py_startdate AND p.period_to_enddate
  GROUP BY o.trading_date
  UNION ALL
  -- 3.5. TPDN niêm yết (HNX - HCX)
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    'TPDNNY' AS loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ban_gt
  FROM uat_hnx_stg.trade_book h
  CROSS JOIN params p
  WHERE h.market_id = 'HCX'
    AND h.trade_date BETWEEN DATE_FORMAT(p.ytd_py_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
  GROUP BY h.trade_date
  UNION ALL
  -- 3.6. TPDN riêng lẻ: Báo cáo HNX09 (chỉ lấy nguồn từ Sở - ICP; không lấy CDW/KDL)
  SELECT
    r.report_date AS trade_date,
    'TPDNRL' AS loai_ck,
    SUM(CASE WHEN r.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA' THEN r.value ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN r.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN' THEN r.value ELSE 0 END) AS ban_gt
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
      AND f.ds_snpst_dt = '2026-09-04' -- Snapshot: giữ như script TPDNRL gốc
      AND MAKE_DATE(f.report_year, f.report_month, f.report_day) BETWEEN p.ytd_py_startdate AND p.period_to_enddate
  ) r
  GROUP BY r.report_date
)
-- 4. Tổng hợp 1 lần: kỳ này, kỳ trước, YTD kỳ này, YTD cùng kỳ năm trước
, kpi AS (
  SELECT
    SUM(CASE WHEN d.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate THEN d.mua_gt ELSE 0 END) AS cur_mua,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate THEN d.ban_gt ELSE 0 END) AS cur_ban,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_prev_startdate AND p.period_prev_enddate THEN d.mua_gt ELSE 0 END) AS prev_mua,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_prev_startdate AND p.period_prev_enddate THEN d.ban_gt ELSE 0 END) AS prev_ban,
    SUM(CASE WHEN d.trade_date BETWEEN p.ytd_startdate AND p.period_to_enddate THEN d.mua_gt ELSE 0 END) AS ytd_mua,
    SUM(CASE WHEN d.trade_date BETWEEN p.ytd_startdate AND p.period_to_enddate THEN d.ban_gt ELSE 0 END) AS ytd_ban,
    SUM(CASE WHEN d.trade_date BETWEEN p.ytd_py_startdate AND p.ytd_py_enddate THEN d.mua_gt ELSE 0 END) AS ytd_py_mua,
    SUM(CASE WHEN d.trade_date BETWEEN p.ytd_py_startdate AND p.ytd_py_enddate THEN d.ban_gt ELSE 0 END) AS ytd_py_ban
  FROM trade_daily d
  CROSS JOIN params p
  WHERE d.loai_ck <> 'PS' -- Bỏ dòng này nếu muốn cộng cả phái sinh vào tổng
)
-- 5. Dữ liệu 4 thẻ KPI
SELECT p.period_type, p.period_code AS ky, m.metric_code, m.metric_name, m.gia_tri, m.gia_tri_so_sanh,
  m.gia_tri - m.gia_tri_so_sanh AS chenh_lech,
  (m.gia_tri - m.gia_tri_so_sanh) / NULLIF(ABS(m.gia_tri_so_sanh), 0) * 100 AS ty_le_thay_doi_pt,
  m.co_so_so_sanh
FROM params p
CROSS JOIN (
  SELECT 1 AS thu_tu, 'gt_rong_ky' AS metric_code, 'GT mua/bán ròng NĐTNN (kỳ)' AS metric_name,
    cur_mua - cur_ban AS gia_tri, prev_mua - prev_ban AS gia_tri_so_sanh, 'Kỳ trước' AS co_so_so_sanh FROM kpi
  UNION ALL
  SELECT 2, 'gt_rong_ytd', 'GT mua/bán ròng NĐTNN (YTD)',
    ytd_mua - ytd_ban, ytd_py_mua - ytd_py_ban, 'Cùng kỳ năm trước' FROM kpi
  UNION ALL
  SELECT 3, 'gt_mua', 'GT giao dịch NĐTNN mua', cur_mua, prev_mua, 'Kỳ trước' FROM kpi
  UNION ALL
  SELECT 4, 'gt_ban', 'GT giao dịch NĐTNN bán', cur_ban, prev_ban, 'Kỳ trước' FROM kpi
) m
ORDER BY m.thu_tu
;


-- ======================================================================================
-- NHÓM 2: CHI TIẾT GIAO DỊCH THEO LOẠI CHỨNG KHOÁN (mỗi chỉ tiêu có % thay đổi so với kỳ trước)
--   Phân loại theo uat_mdds_stg.jad_stockinfor (bản ghi cuối ngày):
--     CP  : stocktype = '2'
--     CCQ : stocktype IN ('3', '6')
--     CW  : floorcode = '10' AND stocktype = '4'
--     PS  : floorcode = '03' AND stocktype IN ('4', '5')
--   TPCP / TPDNNY / TPDNRL lấy theo nguồn của các script TPCP, TPDNNY, TPDNRL hiện có.
-- ======================================================================================
WITH
-- 1. Tham số tra cứu: Loại kỳ (D/M/Q/Y) + Kỳ báo cáo -> ngày đầu/cuối kỳ này, kỳ trước, YTD, YTD cùng kỳ năm trước
params AS (
  SELECT
    x.*,
    CAST(DATE_TRUNC('YEAR', x.period_to_startdate) AS DATE) AS ytd_startdate, -- Ngày đầu năm của kỳ này
    ADD_MONTHS(CAST(DATE_TRUNC('YEAR', x.period_to_startdate) AS DATE), -12) AS ytd_py_startdate, -- Ngày đầu năm trước
    CASE WHEN x.period_type = 'D' THEN ADD_MONTHS(x.period_to_enddate, -12)
       ELSE LAST_DAY(ADD_MONTHS(x.period_to_enddate, -12)) -- Kỳ M/Q/Y kết thúc cuối tháng -> giữ cuối tháng (tránh lệch 28/29-02)
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
      WHEN stocktype = '2' THEN 'CP' -- Cổ phiếu
      WHEN stocktype IN ('3', '6') THEN 'CCQ' -- Chứng chỉ quỹ (gồm ETF)
      WHEN floorcode = '10' AND stocktype = '4' THEN 'CW' -- Chứng quyền
      WHEN floorcode = '03' AND stocktype IN ('4', '5') THEN 'PS' -- Phái sinh: HĐTL (4), HĐ quyền chọn (5)
    END AS loai_ck
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.symbolisin, s.floorcode, s.stocktype,
      CAST(s.contractmultiplier AS DOUBLE) AS contractmultiplier,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN params p
    WHERE s.tradingdate BETWEEN p.period_prev_startdate AND p.period_to_enddate
      AND s.stocktype IN ('2', '3', '4', '5', '6') -- Bỏ trái phiếu (stocktype = '1'): TP đi theo nguồn riêng bên dưới
  )
  WHERE rn = 1 -- Bản ghi cuối mỗi ngày
)
-- 3. GT NĐTNN mua/bán theo ngày x loại chứng khoán (NĐTNN: ký tự thứ 4 của số tài khoản IN ('E','F'))
, trade_daily AS (
  -- 3.1. HOSE: Cổ phiếu, CCQ, Chứng quyền
  SELECT
    h.trade_date AS trade_date,
    s.loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS ban_gt
  FROM uat_hose_stg.trade_book h
  JOIN stock_daily_eod s ON h.symbol = s.symbol AND h.trade_date = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id = 'STK'
    AND s.loai_ck IN ('CP', 'CCQ', 'CW')
    AND h.trade_date BETWEEN p.period_prev_startdate AND p.period_to_enddate
  GROUP BY h.trade_date, s.loai_ck
  UNION ALL
  -- 3.2. HNX + UPCoM: Cổ phiếu, CCQ (trade_date kiểu string yyyyMMdd; join theo mã ISIN)
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    s.loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ban_gt
  FROM uat_hnx_stg.trade_book h
  JOIN stock_daily_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id IN ('STX', 'UPX')
    AND s.loai_ck IN ('CP', 'CCQ', 'CW')
    AND h.trade_date BETWEEN DATE_FORMAT(p.period_prev_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
  GROUP BY h.trade_date, s.loai_ck
  UNION ALL
  -- 3.3. Phái sinh (HNX - DVX): GT = KL x Giá x Hệ số nhân hợp đồng (contractmultiplier trong jad_stockinfor)
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    s.loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price * s.contractmultiplier ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price * s.contractmultiplier ELSE 0 END) AS ban_gt
  FROM uat_hnx_stg.trade_book h
  JOIN stock_daily_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
  CROSS JOIN params p
  WHERE h.market_id = 'DVX'
    AND s.loai_ck = 'PS'
    AND h.trade_date BETWEEN DATE_FORMAT(p.period_prev_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
  GROUP BY h.trade_date, s.loai_ck
  UNION ALL
  -- 3.4. TPCP: Sổ lệnh outright đã thực hiện (ĐTH)
  SELECT
    o.trading_date AS trade_date,
    'TPCP' AS loai_ck,
    SUM(CASE WHEN SUBSTR(o.buying_account_no, 4, 1) IN ('E', 'F') THEN o.trading_value ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(o.selling_account_no, 4, 1) IN ('E', 'F') THEN o.trading_value ELSE 0 END) AS ban_gt
  FROM uat_hnx_stg.outright_order_book o
  CROSS JOIN params p
  WHERE o.order_status = 'ĐTH'
    AND o.trading_date BETWEEN p.period_prev_startdate AND p.period_to_enddate
  GROUP BY o.trading_date
  UNION ALL
  -- 3.5. TPDN niêm yết (HNX - HCX)
  SELECT
    TO_DATE(h.trade_date, 'yyyyMMdd') AS trade_date,
    'TPDNNY' AS loai_ck,
    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ban_gt
  FROM uat_hnx_stg.trade_book h
  CROSS JOIN params p
  WHERE h.market_id = 'HCX'
    AND h.trade_date BETWEEN DATE_FORMAT(p.period_prev_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
  GROUP BY h.trade_date
  UNION ALL
  -- 3.6. TPDN riêng lẻ: Báo cáo HNX09 (chỉ lấy nguồn từ Sở - ICP; không lấy CDW/KDL)
  SELECT
    r.report_date AS trade_date,
    'TPDNRL' AS loai_ck,
    SUM(CASE WHEN r.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ MUA' THEN r.value ELSE 0 END) AS mua_gt,
    SUM(CASE WHEN r.row_path = 'GIÁ TRỊ GIAO DỊCH NHÀ ĐẦU TƯ NƯỚC NGOÀI - GIÁ TRỊ BÁN' THEN r.value ELSE 0 END) AS ban_gt
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
      AND f.ds_snpst_dt = '2026-09-04' -- Snapshot: giữ như script TPDNRL gốc
      AND MAKE_DATE(f.report_year, f.report_month, f.report_day) BETWEEN p.period_prev_startdate AND p.period_to_enddate
  ) r
  GROUP BY r.report_date
)
-- 4. Danh mục dòng hiển thị (đảm bảo luôn đủ dòng kể cả khi không có giao dịch)
, loai_dm AS (
  SELECT * FROM VALUES
    (1, 'Thị trường cơ sở', 1, 'CP',     'Cổ phiếu'),
    (1, 'Thị trường cơ sở', 2, 'CCQ',    'Chứng chỉ quỹ'),
    (1, 'Thị trường cơ sở', 3, 'CW',     'Chứng quyền'),
    (2, 'Phái sinh',        1, 'PS',     'Phái sinh'),
    (3, 'Trái phiếu',       1, 'TPCP',   'TPCP'),
    (3, 'Trái phiếu',       2, 'TPDNNY', 'TPDN niêm yết'),
    (3, 'Trái phiếu',       3, 'TPDNRL', 'TPDN riêng lẻ')
  AS t(nhom_order, nhom, loai_order, loai_ck, loai)
)
-- 5. Tổng hợp theo loại: kỳ này, kỳ trước
, loai_period AS (
  SELECT
    d.loai_ck,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate THEN d.mua_gt ELSE 0 END) AS cur_mua,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate THEN d.ban_gt ELSE 0 END) AS cur_ban,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_prev_startdate AND p.period_prev_enddate THEN d.mua_gt ELSE 0 END) AS prev_mua,
    SUM(CASE WHEN d.trade_date BETWEEN p.period_prev_startdate AND p.period_prev_enddate THEN d.ban_gt ELSE 0 END) AS prev_ban
  FROM trade_daily d
  CROSS JOIN params p
  GROUP BY d.loai_ck
)
-- 6. Dữ liệu bảng "Chi tiết giao dịch"
SELECT
  p.period_type,
  p.period_code AS ky,
  p.period_prev_code AS ky_truoc,
  l.nhom,
  l.loai_ck,
  l.loai,
  -- Mua
  COALESCE(t.cur_mua, 0) AS mua_gt,
  COALESCE(t.prev_mua, 0) AS mua_gt_ky_truoc,
  (COALESCE(t.cur_mua, 0) - COALESCE(t.prev_mua, 0)) / NULLIF(ABS(COALESCE(t.prev_mua, 0)), 0) * 100 AS mua_gt_thay_doi_pt,
  -- Bán
  COALESCE(t.cur_ban, 0) AS ban_gt,
  COALESCE(t.prev_ban, 0) AS ban_gt_ky_truoc,
  (COALESCE(t.cur_ban, 0) - COALESCE(t.prev_ban, 0)) / NULLIF(ABS(COALESCE(t.prev_ban, 0)), 0) * 100 AS ban_gt_thay_doi_pt,
  -- Ròng = Mua - Bán (% thay đổi chia cho trị tuyệt đối kỳ trước, như các script hiện có)
  COALESCE(t.cur_mua, 0) - COALESCE(t.cur_ban, 0) AS rong_gt,
  COALESCE(t.prev_mua, 0) - COALESCE(t.prev_ban, 0) AS rong_gt_ky_truoc,
  ((COALESCE(t.cur_mua, 0) - COALESCE(t.cur_ban, 0)) - (COALESCE(t.prev_mua, 0) - COALESCE(t.prev_ban, 0)))
    / NULLIF(ABS(COALESCE(t.prev_mua, 0) - COALESCE(t.prev_ban, 0)), 0) * 100 AS rong_gt_thay_doi_pt
FROM loai_dm l
LEFT JOIN loai_period t ON l.loai_ck = t.loai_ck
CROSS JOIN params p
ORDER BY l.nhom_order, l.loai_order
;


-- ======================================================================================
-- NHÓM 3: GIÁ TRỊ MUA/BÁN RÒNG CỔ PHIẾU NĐTNN THEO NHÓM NGÀNH (biểu đồ cột, sắp xếp ròng giảm dần)
--   Cổ phiếu: stocktype = '2' (HOSE + HNX + UPCoM). Ngành lấy theo script "Tính vốn hóa & GTGD cổ phiếu theo ngành":
--   ngành cấp 1 từ IDS; CTCK/CTQLQ là CTĐC -> mặc định ngành 07000 (Tài chính ngân hàng).
-- ======================================================================================
WITH
-- 1. Tham số tra cứu: Loại kỳ (D/M/Q/Y) + Kỳ báo cáo -> ngày đầu/cuối kỳ này, kỳ trước, YTD, YTD cùng kỳ năm trước
params AS (
  SELECT
    x.*,
    CAST(DATE_TRUNC('YEAR', x.period_to_startdate) AS DATE) AS ytd_startdate, -- Ngày đầu năm của kỳ này
    ADD_MONTHS(CAST(DATE_TRUNC('YEAR', x.period_to_startdate) AS DATE), -12) AS ytd_py_startdate, -- Ngày đầu năm trước
    CASE WHEN x.period_type = 'D' THEN ADD_MONTHS(x.period_to_enddate, -12)
       ELSE LAST_DAY(ADD_MONTHS(x.period_to_enddate, -12)) -- Kỳ M/Q/Y kết thúc cuối tháng -> giữ cuối tháng (tránh lệch 28/29-02)
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
  WHERE rn = 1
)
-- 3. GT NĐTNN mua/bán trong kỳ theo mã cổ phiếu
, stock_trade AS (
  SELECT symbol, SUM(mua_gt) AS mua_gt, SUM(ban_gt) AS ban_gt
  FROM (
    SELECT -- HOSE
      s.symbol,
      SUM(CASE WHEN SUBSTR(h.buy_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS mua_gt,
      SUM(CASE WHEN SUBSTR(h.sell_acct_no, 4, 1) IN ('E', 'F') THEN h.execution_value ELSE 0 END) AS ban_gt
    FROM uat_hose_stg.trade_book h
    JOIN stock_daily_eod s ON h.symbol = s.symbol AND h.trade_date = s.tradingdate
    CROSS JOIN params p
    WHERE h.market_id = 'STK'
      AND h.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate
    GROUP BY s.symbol
    UNION ALL
    SELECT -- HNX + UPCoM
      s.symbol,
      SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS mua_gt,
      SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ban_gt
    FROM uat_hnx_stg.trade_book h
    JOIN stock_daily_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
    CROSS JOIN params p
    WHERE h.market_id IN ('STX', 'UPX')
      AND h.trade_date BETWEEN DATE_FORMAT(p.period_to_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd')
    GROUP BY s.symbol
  )
  GROUP BY symbol
)
-- 4. Ngành của mã cổ phiếu (IDS/SCMS/FMS) - snapshot ds_snpst_dt giữ nguyên như script gốc
, industry_map AS (
  SELECT
    t.symbol,
    CASE WHEN sc.securities_code IS NOT NULL OR f.stock_code IS NOT NULL THEN '07000' ELSE c.industry_cd END AS industry_cd,
    CASE WHEN sc.securities_code IS NOT NULL OR f.stock_code IS NOT NULL THEN i07.industry_name ELSE c.industry_name END AS industry_name
  FROM (SELECT DISTINCT symbol FROM stock_trade) t
  LEFT JOIN (
    SELECT equity_ticker, category_l1_id
    FROM (
      SELECT equity_ticker, category_l1_id,
        ROW_NUMBER() OVER(PARTITION BY equity_ticker ORDER BY id) rn -- Lấy bản ghi cũ hơn (lọc dữ liệu test trùng)
      FROM uat_ids_stg.company_profiles
      WHERE ds_snpst_dt = '2026-10-17'
        AND delete_flg <> '1'
        AND (approval_status_cd <> 'REJECTED' OR approval_status_cd IS NULL)
    ) WHERE rn = 1
  ) p ON t.symbol = p.equity_ticker
  LEFT JOIN (
    SELECT id, industry_cd, industry_name
    FROM uat_ids_stg.categories
    WHERE ds_snpst_dt = '2026-10-17'
  ) c ON p.category_l1_id = c.id
  -- CTCK là CTĐC đã niêm yết/ĐKGD -> Tài chính ngân hàng (DISTINCT tránh nhân dòng)
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
    SELECT MAX(industry_name) AS industry_name
    FROM uat_ids_stg.categories
    WHERE industry_cd = '07000' AND active_flg = '1' AND ds_snpst_dt = '2026-10-17'
  ) i07
)
-- 5. Dữ liệu biểu đồ: Mua/Bán ròng theo ngành
SELECT
  p.period_type,
  p.period_code AS ky,
  COALESCE(m.industry_cd, 'N/A') AS industry_cd,
  COALESCE(m.industry_name, 'Chưa phân ngành') AS industry_name,
  SUM(t.mua_gt) AS mua_gt,
  SUM(t.ban_gt) AS ban_gt,
  SUM(t.mua_gt - t.ban_gt) AS rong_gt
FROM stock_trade t
LEFT JOIN industry_map m ON t.symbol = m.symbol
CROSS JOIN params p
GROUP BY p.period_type, p.period_code, COALESCE(m.industry_cd, 'N/A'), COALESCE(m.industry_name, 'Chưa phân ngành')
ORDER BY rong_gt DESC
;
