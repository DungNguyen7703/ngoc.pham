-- [29] HUY ĐỘNG VỐN - TPDN - DƯ NỢ THEO NGÀNH (TỔNG TPDN = TPDNNY + TPDNRL): TÍNH TẠI 1 KỲ
/* Tham số:
 *   :period_type  Loại kỳ: M/Q/Y
 *   :period_to    Kỳ tra cứu: Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * Dư nợ (VND) tính đến kỳ tra cứu (SỐ DƯ, không phải phát sinh trong kỳ):
 *   TPDNNY: jad_stockinfor (stocktype = '1') lấy dữ liệu ngày mới nhất <= cuối kỳ, bản ghi cuối ngày của mỗi mã
 *     - Dư nợ = KL niêm yết (listedshare) x Mệnh giá (suy ngược từ giá tham chiếu)
 *     - Ngành: Mã TCPH = SUBSTR(symbol, 3) -> IDS company_profiles + categories (ngành cấp 1); CTCK (SCMS) / CTQLQ (FMS) là CTĐC -> ngành 'Tài chính ngân hàng' (industry_cd = '07000'); không có -> 'Chưa phân ngành'
 *   TPDNRL: private_corp_bond_registration (snapshot tháng): tháng mới nhất có dữ liệu trong kỳ, snapshot mới nhất của tháng
 *     - Dư nợ = KL lưu hành (outstanding_volume) x Mệnh giá (par_value)
 *     - Ngành: không phân ngành -> 'TPDNRL - Chưa có thông tin ngành'
 */
WITH
-- ========== A. THAM SỐ LỌC KỲ: Ngày đầu + cuối kỳ tra cứu ==========
params AS (
  SELECT
    CASE :period_type
      WHEN 'M' THEN TO_DATE(CONCAT(:period_to, '-01'))
      WHEN 'Q' THEN ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), (CAST(RIGHT(:period_to, 1) AS INT) - 1) * 3)
      WHEN 'Y' THEN MAKE_DATE(:period_to, 1, 1)
    END AS period_startdate, -- Ngày đầu kỳ tra cứu
    CASE :period_type
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), CAST(RIGHT(:period_to, 1) AS INT) * 3 - 1))
      WHEN 'Y' THEN MAKE_DATE(:period_to, 12, 31)
    END AS period_enddate    -- Ngày cuối kỳ tra cứu
)
-- ========== B. TPDNNY ==========
---- Fix ngành cho CTCK, CTQLQ là CTĐC: Ngành "Tài chính ngân hàng"
, industry_fix_ctck_ctqlq AS (
  SELECT DISTINCT industry_name
  FROM uat_ids_stg.categories
  WHERE industry_cd = '07000' AND active_flg = '1' AND ds_snpst_dt = '2026-11-11'
  LIMIT 1
)
---- Dữ liệu cuối ngày của từng mã TPDNNY
, stock_eod AS (
  SELECT 
    st.*,
    COALESCE(p.industry_name, sc.industry_name, f.industry_name, 'Chưa phân ngành') AS industry_name,
    st.listedshare * st.par_value AS du_no -- Dư nợ = KL niêm yết x Mệnh giá
  FROM (
    -- Dữ liệu cuối ngày từng mã chứng khoán
    SELECT t.*
    FROM (
      SELECT
        s.symbol,
        SUBSTR(s.symbol, 1, 3) AS issue_code, -- Mã TCPH của TPDN niêm yết
        CAST(s.listedshare AS DECIMAL(38,2)) AS listedshare,
        100000 * POWER(10, ROUND(LN(NULLIF(reference, 0) / 100000) / LN(10))) AS par_value, -- Mệnh giá suy ngược từ giá tham chiếu (bội số 100000, bước nhảy x10)
        ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
      FROM uat_mdds_stg.jad_stockinfor s
      JOIN (
        -- Ngày giao dịch gần nhất <= ngày cuối kỳ
        SELECT MAX(s.tradingdate) AS tradingdate
        FROM uat_mdds_stg.jad_stockinfor s
        CROSS JOIN params p
        WHERE s.tradingdate <= p.period_enddate
      ) d ON s.tradingdate = d.tradingdate
      WHERE s.stocktype = '1' -- TPDN niêm yết
    ) t
    WHERE rn = 1 -- Lọc bản ghi cuối ngày
  ) st 
  -- Map ngành cho TPDNNY theo Mã TCPH
  ---- Thông tin hồ sơ Công ty đại chúng + phân ngành
  LEFT JOIN (
    SELECT cp.equity_ticker, c.industry_name
    FROM (
      SELECT equity_ticker, category_l1_id,
        ROW_NUMBER() OVER(PARTITION BY equity_ticker ORDER BY id) rn -- Lấy bản ghi cũ hơn (lọc dữ liệu test trùng)
      FROM uat_ids_stg.company_profiles
      WHERE delete_flg <> '1'
        AND (approval_status_cd <> 'REJECTED' OR approval_status_cd IS NULL)
        AND ds_snpst_dt = '2026-11-11'
    ) cp
    -- Thông tin ngành nghề kinh tế
    LEFT JOIN (
      SELECT id, industry_name
      FROM uat_ids_stg.categories
      WHERE ds_snpst_dt = '2026-11-11'
    ) c ON cp.category_l1_id = c.id
    WHERE cp.rn = 1
  ) p ON st.issue_code = p.equity_ticker
  ---- CTCK là CTĐC đã niêm yết/ĐKGD
  LEFT JOIN (
    SELECT DISTINCT sc.securities_code, i.industry_name
    FROM uat_scms_stg.SC_FIRM_INFO sc
    CROSS JOIN industry_fix_ctck_ctqlq i --> Fix ngành nghề là Tài chính ngân hàng với CTCK, CTQLQ là CTĐC
    WHERE sc.deleted = '0' AND sc.securities_code IS NOT NULL AND sc.ds_snpst_dt = '2026-08-22'
  ) sc ON st.issue_code = sc.securities_code
  ---- CTQLQ là CTĐC đã niêm yết/ĐKGD
  LEFT JOIN (
    SELECT DISTINCT f.stock_code, i.industry_name
    FROM uat_fms_stg.securities f
    CROSS JOIN industry_fix_ctck_ctqlq i --> Fix ngành nghề là Tài chính ngân hàng với CTCK, CTQLQ là CTĐC
    WHERE f.deleted = 0 AND f.stock_code IS NOT NULL AND f.ds_snpst_dt = '2026-10-21'
  ) f ON st.issue_code = f.stock_code
)
-- ========== C. TPDNRL ==========
, private_corpbond_cum AS (
  SELECT
    'NA' AS industry_cd, 
    'TPDNRL - Chưa phân ngành' AS industry_name, -- TPDNRL không có thông tin phân ngành
    outstanding_volume * par_value AS du_no -- Dư nợ = KL lưu hành x Mệnh giá
  FROM (
    -- Chỉ lấy các tháng thuộc kỳ -> tháng mới nhất của kỳ + snapshot mới nhất của tháng
    SELECT
      c.bond_code, c.outstanding_volume, c.par_value,
      DENSE_RANK() OVER(ORDER BY MAKE_DATE(c.report_year, c.report_month, 1) DESC, c.ds_snpst_dt DESC) AS rk -- Lọc tháng mới nhất x snapshot date mới nhất của tháng
    FROM uat_hnx_stg.private_corp_bond_registration c
    JOIN params p ON MAKE_DATE(c.report_year, c.report_month, 1) BETWEEN p.period_startdate AND p.period_enddate
  ) t
  WHERE rk = 1
)
-- ========== D. KẾT QUẢ: TỔNG TPDN THEO NGÀNH ==========
SELECT 
  industry_cd AS ma_nganh, 
  industry_name AS ten_nganh, 
  du_no, 
  (du_no / SUM(du_no) OVER()) * 100.0 du_no_tytrong
FROM (
  SELECT
    industry_cd, industry_name, SUM(du_no) AS du_no
  FROM (
    SELECT industry_cd, industry_name, du_no FROM stock_eod
    UNION ALL
    SELECT industry_cd, industry_name, du_no FROM private_corpbond_cum
  ) a
  GROUP BY industry_cd, industry_name
)
;