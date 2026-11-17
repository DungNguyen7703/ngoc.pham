-- [27] HUY ĐỘNG VỐN - TPDN - DƯ NỢ x KỲ HẠN CÒN LẠI BÌNH QUÂN (NĂM): TÍNH TẠI 1 KỲ + % SO VỚI KỲ TRƯỚC
/* Tham số:
 *   :period_type  Loại kỳ: M/Q/Y
 *   :period_to    Kỳ tra cứu: Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * % so với kỳ trước = (kỳ này - kỳ trước) / kỳ trước * 100. Kỳ trước = 0 hoặc NULL -> NULL.
 * CHỈ TIÊU TÍNH ĐẾN KỲ TRA CỨU (SỐ DƯ, không phải phát sinh trong kỳ):
 *   - Dư nợ (VND)
 *   - Kỳ hạn còn lại BQ (năm) = Σ(Kỳ hạn còn lại (năm) x Dư nợ) / Σ Dư nợ (chỉ tính trên các mã có kỳ hạn còn lại >= 0; quy đổi năm = số ngày / 365)
 * TPDNNY: jad_stockinfor (stocktype = '1') lấy dữ liệu ngày mới nhất <= cuối kỳ, bản ghi cuối ngày của mỗi mã
 * TPDNRL: private_corp_bond_registration (snapshot tháng): Chỉ lấy đúng các tháng của kỳ và Lấy tháng mới nhất có dữ liệu trong kỳ, snapshot mới nhất của tháng
 * TPDN = TPDNNY + TPDNRL
 */
WITH
-- ========== A. THAM SỐ LỌC KỲ ==========
-- 1. THAM SỐ GỐC -> Ngày đầu + cuối kỳ tra cứu
params_base AS (
  SELECT
    :period_type AS period_type,
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
-- 2. THAM SỐ 2 KỲ: cur = kỳ tra cứu, prev = kỳ liền trước
, params AS (
  SELECT 'cur' AS period_tag, period_startdate, period_enddate
  FROM params_base
  UNION ALL
  SELECT
    'prev' AS period_tag,
    ADD_MONTHS(period_startdate, CASE period_type WHEN 'M' THEN -1 WHEN 'Q' THEN -3 WHEN 'Y' THEN -12 END) AS period_startdate,
    LAST_DAY(ADD_MONTHS(period_enddate, CASE period_type WHEN 'M' THEN -1 WHEN 'Q' THEN -3 WHEN 'Y' THEN -12 END)) AS period_enddate
  FROM params_base
)
-- ========== B. TPDNNY ==========
---- Dữ liệu cuối ngày của từng mã
, stock_eod AS (
  SELECT t.*
  FROM (
    SELECT
      d.period_tag,
      s.symbol,
      CAST(s.listedshare AS DECIMAL(38,2)) AS listedshare,
      100000 * POWER(10, ROUND(LN(NULLIF(reference, 0) / 100000) / LN(10))) AS par_value, -- Mệnh giá suy ngược từ giá tham chiếu (bội số 100000, bước nhảy x10)
      DATEDIFF(TO_DATE(TRIM(s.maturitydate), 'dd/MM/yyyy'), s.tradingdate) / 365.0 AS ky_han_con_lai_nam, -- Kỳ hạn còn lại (năm) = (Ngày đáo hạn - Ngày GD) / 365
      ROW_NUMBER() OVER(PARTITION BY d.period_tag, s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s
    JOIN (
      -- Ngày giao dịch gần nhất <= ngày cuối kỳ này, kỳ trước
      SELECT p.period_tag, MAX(s.tradingdate) AS tradingdate
      FROM uat_mdds_stg.jad_stockinfor s
      CROSS JOIN params p
      WHERE s.tradingdate <= p.period_enddate
      GROUP BY p.period_tag
    ) d ON s.tradingdate = d.tradingdate
    WHERE s.stocktype = '1' -- TPDN niêm yết
  ) t
  WHERE rn = 1
)
---- Tổng theo kỳ
, stock_cum AS (
  SELECT
    period_tag AS ky,
    'TPDNNY' AS loai_ck,
    SUM(listedshare * par_value) AS du_no, -- Dư nợ = KL niêm yết x Mệnh giá
    SUM(IF(ky_han_con_lai_nam >= 0, ky_han_con_lai_nam * listedshare * par_value, 0)) AS w_sum, -- Tử số: Σ(Kỳ hạn còn lại x Dư nợ)
    SUM(IF(ky_han_con_lai_nam >= 0, listedshare * par_value, 0)) AS w -- Mẫu số: Σ Dư nợ (các mã có kỳ hạn còn lại)
  FROM stock_eod
  GROUP BY period_tag
)
-- ========== C. TPDNRL ==========
, private_corpbond_cum AS (
  SELECT
    period_tag AS ky,
    'TPDNRL' AS loai_ck,
    SUM(outstanding_volume * par_value) AS du_no, -- Dư nợ = KL lưu hành x Mệnh giá
    SUM(IF(remaining_term >= 0, remaining_term / 365.0 * outstanding_volume * par_value, 0)) AS w_sum, -- Tử số: Σ(Kỳ hạn còn lại x Dư nợ)
    SUM(IF(remaining_term >= 0, outstanding_volume * par_value, 0)) AS w -- Mẫu số: Σ Dư nợ (các mã có kỳ hạn còn lại)
  FROM (
    -- Chỉ lấy các tháng thuộc kỳ -> tháng mới nhất của kỳ + snapshot mới nhất của tháng
    SELECT
      p.period_tag, c.bond_code, c.outstanding_volume, c.par_value, c.remaining_term, -- Kỳ hạn còn lại (ngày)
      DENSE_RANK() OVER(PARTITION BY p.period_tag ORDER BY MAKE_DATE(c.report_year, c.report_month, 1) DESC, c.ds_snpst_dt DESC) AS rk -- Lọc tháng mới nhất và snapshot date mới nhất của tháng
    FROM uat_hnx_stg.private_corp_bond_registration c
    JOIN params p ON MAKE_DATE(c.report_year, c.report_month, 1) BETWEEN p.period_startdate AND p.period_enddate
  ) t
  WHERE rk = 1 -- Lọc tháng và snapshot date
  GROUP BY period_tag
)
-- ========== D. TỔNG HỢP: TPDNNY, TPDNRL + dòng tổng TPDN ==========
, all_metrics AS (
  SELECT
    ky,
    IF(GROUPING(loai_ck) = 1, 'TPDN', loai_ck) AS loai_ck,  -- Dòng gộp theo kỳ (không theo loại) = Tổng TPDN
    SUM(du_no) AS du_no,
    SUM(w_sum) / NULLIF(SUM(w), 0) AS ky_han_con_lai_bq_nam -- Kỳ hạn còn lại BQ (năm)
  FROM (
    SELECT * FROM stock_cum
    UNION ALL
    SELECT * FROM private_corpbond_cum
  ) a
  GROUP BY GROUPING SETS (
    (ky, loai_ck), -- Từng loại: TPDNNY, TPDNRL
    (ky)           -- Tổng TPDN
  )
)
-- TỔNG HỢP LÊN BIỂU ĐỒ: kỳ này + kỳ trước + % thay đổi
SELECT
  l.stt,
  l.loai_ck,
  -- Kỳ tra cứu
  CAST(c.du_no AS DECIMAL(38, 2)) AS du_no,
  ROUND(c.ky_han_con_lai_bq_nam, 2) AS ky_han_con_lai_bq_nam,
  -- Kỳ trước
  CAST(p.du_no AS DECIMAL(38, 2)) AS du_no_kytruoc,
  ROUND(p.ky_han_con_lai_bq_nam, 2) AS ky_han_con_lai_bq_nam_kytruoc,
  -- % so với kỳ trước
  ROUND((c.du_no - p.du_no) / NULLIF(p.du_no, 0) * 100, 2) AS du_no_pct,
  ROUND((c.ky_han_con_lai_bq_nam - p.ky_han_con_lai_bq_nam) / NULLIF(p.ky_han_con_lai_bq_nam, 0) * 100, 2) AS ky_han_con_lai_bq_nam_pct
FROM (SELECT POSEXPLODE(ARRAY('TPDNNY', 'TPDNRL', 'TPDN')) AS (stt, loai_ck)) l -- Danh sách loại trái phiếu
LEFT JOIN all_metrics c ON l.loai_ck = c.loai_ck AND c.ky = 'cur'  -- Số liệu kỳ này
LEFT JOIN all_metrics p ON l.loai_ck = p.loai_ck AND p.ky = 'prev' -- Số liệu kỳ trước
WHERE c.ky = 'cur'
ORDER BY l.stt
;