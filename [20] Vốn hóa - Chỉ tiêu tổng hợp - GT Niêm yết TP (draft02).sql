-- THỐNG KÊ THỊ TRƯỜNG >> GIÁ TRỊ NIÊM YẾT/ĐKGD TRÁI PHIẾU (TPCP, TPDNNY, TPDNRL, TỔNG TPDN): TÍNH TẠI 1 KỲ
/* Tham số tra cứu (Spark SQL named parameter):
 * :period_type  Loại kỳ: D/M/Q/Y
 * :period_code  Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * GDP: năm GDP của mỗi mốc = năm của ngày cuối kỳ - 1 (năm liền trước đã có số liệu chính thức).
 * GT niêm yết = Mệnh giá x KL niêm yết/ĐKGD (SỐ DƯ tại cuối kỳ)
 *   - TPCP   : uat_hnx_stg.gov_bond_listed_list (snapshot tháng) -> GT = listed_volume x 100.000
 *   - TPDNNY : uat_mdds_stg.jad_stockinfor (bản ghi cuối của ngày GD cuối cùng <= cuối kỳ) -> GT = listedshare x mệnh giá (mệnh giá suy từ reference)
 *   - TPDNRL : uat_hnx_stg.private_corp_bond_registration (snapshot tháng) GT = registered_trading_volume x par_value (snapshot tháng chỉ chứa mã chưa đáo hạn)
 *    Chọn tháng báo cáo cho snapshot tháng (TPCP, TPDNRL), áp dụng cho cả kỳ này / kỳ trước / cùng kỳ năm trước:
 *   - Kỳ D mà ngày cuối kỳ chưa phải cuối tháng -> lùi 1 tháng (báo cáo tháng chưa hoàn chỉnh).
 *   - Còn lại (D là ngày cuối tháng, M/Q/Y) -> tháng của ngày cuối kỳ.
 *   - Nếu tháng đó chưa có dữ liệu (kỳ đang diễn ra) -> lấy tháng gần nhất có dữ liệu <= tháng đó.
 */
WITH
-- 1. THAM SỐ TRA CỨU: Loại kỳ + Kỳ báo cáo -> ngày cuối kỳ này, kỳ trước, cùng kỳ năm trước
params AS (
  SELECT
    period_type,
    period_code,
    period_to_enddate AS cur_end, -- Ngày cuối kỳ này
    DATE_SUB(period_to_startdate, 1) AS prev_end, -- Ngày cuối kỳ trước
    CASE 
      WHEN period_type = 'D' THEN ADD_MONTHS(period_to_enddate, -12)
      ELSE LAST_DAY(ADD_MONTHS(period_to_enddate, -12)) -- M/Q/Y kết thúc cuối tháng
    END AS py_end, -- Ngày cuối cùng kỳ năm trước
    YEAR(period_to_enddate) - 1 AS gdp_year_cur,                 -- Năm GDP cho kỳ báo cáo
    YEAR(DATE_SUB(period_to_startdate, 1)) - 1 AS gdp_year_prev, -- Năm GDP cho kỳ trước
    YEAR(CASE 
      WHEN period_type = 'D' THEN ADD_MONTHS(period_to_enddate, -12)
      ELSE LAST_DAY(ADD_MONTHS(period_to_enddate, -12))
    END) - 1 AS gdp_year_py                                      -- Năm GDP cho cùng kỳ năm trước
  FROM (
    SELECT
      :period_type AS period_type, -- Loại kỳ: D/M/Q/Y
      :period_code AS period_code, -- Kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
      CASE :period_type
        WHEN 'D' THEN TO_DATE(:period_code)
        WHEN 'M' THEN TO_DATE(CONCAT(:period_code, '-01'))
        WHEN 'Q' THEN ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_code, 1, 4), '-01-01')), (CAST(RIGHT(:period_code, 1) AS INT) - 1) * 3)
        WHEN 'Y' THEN MAKE_DATE(:period_to,1,1) -- Ngày đầu kỳ tra cứu
      END AS period_to_startdate,
      CASE :period_type
        WHEN 'D' THEN TO_DATE(:period_code)
        WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_code, '-01')))
        WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_code, 1, 4), '-01-01')), CAST(RIGHT(:period_code, 1) AS INT) * 3 - 1))
        WHEN 'Y' THEN MAKE_DATE(:period_code,12,31) -- Ngày cuối kỳ tra cứu
      END AS period_to_enddate
  )
)
-- 2. Mốc thời gian cần tính: CUR (kỳ này), PREV (kỳ trước), PY (cùng kỳ năm trước) + tháng báo cáo cho snapshot tháng (DATE đầu tháng)
, periods AS (
  SELECT
    period_key,
    enddate,
    TRUNC(ref_date, 'MM') AS target_month -- Ngày đầu tháng báo cáo (kiểu DATE)
  FROM (
    SELECT
      t.period_key,
      t.enddate,
      CASE 
				WHEN t.period_type = 'D' AND t.enddate <> LAST_DAY(t.enddate) THEN ADD_MONTHS(t.enddate, -1) -- Kỳ D chưa hết tháng -> lùi 1 tháng
        ELSE t.enddate
      END AS ref_date
    FROM (
      SELECT period_type, 'CUR' AS period_key, cur_end AS enddate FROM params
      UNION ALL
      SELECT period_type, 'PREV' AS period_key, prev_end AS enddate FROM params
      UNION ALL
      SELECT period_type, 'PY' AS period_key, py_end AS enddate FROM params
    ) t
  )
)
-- 3. TPDNNY: quét jad_stockinfor 1 lần cho cả 3 mốc (cửa sổ 15 ngày trước mỗi mốc để đi qua kỳ nghỉ lễ dài, giúp prune partition)
, stock_win AS (
  SELECT
    s.symbol, s.tradingdate, s.tradingtime, s.`sequence`,
    CAST(s.listedshare AS DECIMAL(38, 0)) AS listedshare,
    CAST(s.reference AS DOUBLE) AS reference
  FROM uat_mdds_stg.jad_stockinfor s
  CROSS JOIN params p
  WHERE s.stocktype = '1' AND s.floorcode <> '03' -- TPDN niêm yết (floorcode 03 là TPCP -> không tính)
    AND (   s.tradingdate BETWEEN DATE_SUB(LEAST(p.cur_end,  CURRENT_DATE()), 15) AND p.cur_end
         OR s.tradingdate BETWEEN DATE_SUB(LEAST(p.prev_end, CURRENT_DATE()), 15) AND p.prev_end
         OR s.tradingdate BETWEEN DATE_SUB(LEAST(p.py_end,   CURRENT_DATE()), 15) AND p.py_end)
)
-- 3.1. Ngày giao dịch cuối cùng <= ngày cuối kỳ của từng mốc
, last_tradingdate AS (
  SELECT t.period_key, MAX(w.tradingdate) AS tradingdate
  FROM periods t
  JOIN stock_win w ON w.tradingdate BETWEEN DATE_SUB(LEAST(t.enddate, CURRENT_DATE()), 15) AND t.enddate
  GROUP BY t.period_key
)
-- 3.2. Bản ghi cuối của mỗi mã tại ngày giao dịch cuối cùng (jad_stockinfor có nhiều dòng/mã)
, stock_eod AS (
  SELECT period_key, symbol, listedshare, reference
  FROM (
    SELECT
      d.period_key, w.symbol, w.listedshare, w.reference,
      ROW_NUMBER() OVER(PARTITION BY d.period_key, w.symbol ORDER BY w.tradingtime DESC, w.`sequence` DESC) AS rn
    FROM stock_win w
    JOIN last_tradingdate d ON w.tradingdate = d.tradingdate
  )
  WHERE rn = 1
)
-- 3.3. GT niêm yết TPDNNY = KL niêm yết x Mệnh giá (mệnh giá suy từ reference: 100.000 x 10^n)
, tpdnny_value AS (
  SELECT
    period_key,
    SUM(listedshare * 100000 * POWER(10, ROUND(LN(NULLIF(reference, 0) / 100000) / LN(10)))) AS gt
  FROM stock_eod
  GROUP BY period_key
)
-- 4. TPCP: danh sách TPCP niêm yết (snapshot tháng); mỗi tháng lấy snapshot mới nhất
, gov_src AS (
  SELECT report_month, bond_code, listed_volume
  FROM (
    SELECT
      report_month, bond_code, listed_volume, ds_snpst_dt,
      MAX(ds_snpst_dt) OVER(PARTITION BY report_month) AS max_snpst_dt
    FROM (
      SELECT
        MAKE_DATE(CAST(g.report_year AS INT), CAST(RIGHT(CAST(g.report_month AS STRING), 2) AS INT), 1) AS report_month, -- Ngày đầu tháng báo cáo (report_month có thể là 'MM' hoặc 'yyyy-MM')
        g.bond_code,
        CAST(g.listed_volume AS DECIMAL(38, 2)) AS listed_volume,
        g.ds_snpst_dt
      FROM uat_hnx_stg.gov_bond_listed_list g
    )
  )
  WHERE ds_snpst_dt = max_snpst_dt
)
, gov_ym AS ( -- Tháng báo cáo gần nhất <= tháng cần lấy của từng mốc
  SELECT t.period_key, MAX(g.report_month) AS report_month
  FROM periods t
  JOIN gov_src g ON g.report_month <= t.target_month
  GROUP BY t.period_key
)
, tpcp_value AS ( -- GT niêm yết TPCP = KL niêm yết x 100.000 (khử trùng lặp mã)
  SELECT period_key, SUM(listed_volume) * 100000 AS gt
  FROM (
    SELECT y.period_key, g.bond_code, MAX(g.listed_volume) AS listed_volume
    FROM gov_ym y
    JOIN gov_src g ON g.report_month = y.report_month
    GROUP BY y.period_key, g.bond_code
  )
  GROUP BY period_key
)
-- 5. TPDNRL: TPDN riêng lẻ đăng ký giao dịch (snapshot tháng); mỗi tháng lấy snapshot mới nhất
, reg_src AS (
  SELECT report_month, registered_trading_volume, par_value
  FROM (
    SELECT
      report_month, registered_trading_volume, par_value, ds_snpst_dt,
      MAX(ds_snpst_dt) OVER(PARTITION BY report_month) AS max_snpst_dt
    FROM (
      SELECT
        MAKE_DATE(CAST(r.report_year AS INT), CAST(RIGHT(CAST(r.report_month AS STRING), 2) AS INT), 1) AS report_month, -- Ngày đầu tháng báo cáo
        CAST(r.registered_trading_volume AS DECIMAL(38, 2)) AS registered_trading_volume,
        CAST(r.par_value AS DECIMAL(38, 2)) AS par_value,
        r.ds_snpst_dt
      FROM uat_hnx_stg.private_corp_bond_registration r
    )
  )
  WHERE ds_snpst_dt = max_snpst_dt
)
, reg_ym AS (
  SELECT t.period_key, MAX(r.report_month) AS report_month
  FROM periods t
  JOIN reg_src r ON r.report_month <= t.target_month
  GROUP BY t.period_key
)
, tpdnrl_value AS ( -- GT ĐKGD TPDNRL = KL đăng ký giao dịch x Mệnh giá
  SELECT y.period_key, SUM(r.registered_trading_volume * r.par_value) AS gt
  FROM reg_ym y
  JOIN reg_src r ON r.report_month = y.report_month
  GROUP BY y.period_key
)
-- 6. Gộp 3 loại -> pivot theo kỳ (CUR / PREV / PY)
, listed_value AS (
  SELECT
    bond_type,
    MAX(CASE WHEN period_key = 'CUR'  THEN gt END) AS cur_gt,
    MAX(CASE WHEN period_key = 'PREV' THEN gt END) AS prev_gt,
    MAX(CASE WHEN period_key = 'PY'   THEN gt END) AS py_gt
  FROM (
    SELECT 'TPCP'   AS bond_type, period_key, gt FROM tpcp_value
    UNION ALL
    SELECT 'TPDNNY' AS bond_type, period_key, gt FROM tpdnny_value
    UNION ALL
    SELECT 'TPDNRL' AS bond_type, period_key, gt FROM tpdnrl_value
  )
  GROUP BY bond_type
)
-- 7. Thêm dòng tổng TP = TPDNNY + TPDNRL (muốn gồm cả TPCP: đổi điều kiện thành bond_type IN ('TPCP', 'TPDNNY', 'TPDNRL'))
, listed_total AS (
  SELECT bond_type, cur_gt, prev_gt, py_gt FROM listed_value
  UNION ALL
  SELECT 'TP' AS bond_type, SUM(cur_gt), SUM(prev_gt), SUM(py_gt)
  FROM listed_value
  WHERE bond_type IN ('TPDNNY', 'TPDNRL')
)
-- 8. Danh mục dòng hiển thị (luôn đủ dòng kể cả khi không có dữ liệu)
, bond_dm AS (
  SELECT * FROM VALUES
    (1, 'TPCP'),
    (2, 'TPDNNY'),
    (3, 'TPDNRL'),
    (4, 'TP')
  AS t(bond_order, bond_type)
)
-- 9. GDP năm theo 3 mốc (kỳ này, kỳ trước, cùng kỳ năm trước) - cùng quy tắc file [19]
---- Giá trị quy đổi về VND (3 = Tỷ, 8 = Đồng, 23 = Triệu); Ưu tiên Năm > Quý; Nếu lấy Quý thì phải có đủ 4 quý.
, gdp_data AS (
  SELECT
    MAX(IF(t.period_year = p.gdp_year_cur,  t.gdp_val, NULL)) AS gdp_cur,
    MAX(IF(t.period_year = p.gdp_year_prev, t.gdp_val, NULL)) AS gdp_prev,
    MAX(IF(t.period_year = p.gdp_year_py,   t.gdp_val, NULL)) AS gdp_py
  FROM (
    SELECT
      v.period_year,
      v.period_type,
      SUM(CAST(v.value AS DOUBLE) * MAP('3', 1e9, '8', 1, '23', 1e6)[v.unit_code]) AS gdp_val, -- Quy đổi về VND
      COUNT(1) AS sl_ky,
      ROW_NUMBER() OVER(PARTITION BY v.period_year ORDER BY v.period_type DESC) AS rn -- Ưu tiên Năm > Quý
    FROM uat_mrms_stg.risk_indicator_value v
    LEFT JOIN uat_mrms_stg.risk_indicator i ON i.id = v.indicator_id
    CROSS JOIN params p
    WHERE i.indicator_code = 'GDP_VN'
      AND v.period_type IN ('3', '4') -- 4: Năm, 3: Quý
      AND v.period_year IN (p.gdp_year_cur, p.gdp_year_prev, p.gdp_year_py)
      AND v.deleted = '0'
      AND v.ds_snpst_dt = '2026-10-23'
      AND i.ds_snpst_dt = '2026-10-23'
    GROUP BY v.period_year, v.period_type
  ) t
  CROSS JOIN params p
  WHERE t.rn = 1
    AND (t.period_type = '4' OR (t.period_type = '3' AND t.sl_ky = 4)) -- Quý phải đủ 4 quý
)
-- 10. Kết quả
SELECT
  p.period_type,
  p.period_code,
  d.bond_type,
  CAST(l.cur_gt  AS DECIMAL(38, 2)) AS listedvalue_cur,
  CAST(l.prev_gt AS DECIMAL(38, 2)) AS listedvalue_prev,
  CAST(l.py_gt   AS DECIMAL(38, 2)) AS listedvalue_py,
  (l.cur_gt - l.prev_gt) / NULLIF(ABS(l.prev_gt), 0) * 100 AS listedvalue_prev_pct,
  (l.cur_gt - l.py_gt)   / NULLIF(ABS(l.py_gt), 0)   * 100 AS listedvalue_py_pct,
  -- Tỷ lệ GT niêm yết / GDP (%)
  l.cur_gt / NULLIF(g.gdp_cur, 0) * 100 AS listedvalue_gdp_cur,
  (l.cur_gt / NULLIF(g.gdp_cur, 0) - l.prev_gt / NULLIF(g.gdp_prev, 0)) * 100 AS listedvalue_gdp_prev_pct, -- Chênh lệch điểm % so với kỳ trước
  (l.cur_gt / NULLIF(g.gdp_cur, 0) - l.py_gt   / NULLIF(g.gdp_py, 0))   * 100 AS listedvalue_gdp_py_pct    -- Chênh lệch điểm % so với cùng kỳ năm trước
FROM bond_dm d
CROSS JOIN params p
CROSS JOIN gdp_data g
LEFT JOIN listed_total l ON d.bond_type = l.bond_type
ORDER BY d.bond_order
;