-- [20] VỐN HÓA THỊ TRƯỜNG - CHỈ TIÊU TỔNG HỢP - GT NIÊM YẾT TP: TÍNH TẠI 1 KỲ + % SO VỚI KỲ TRƯỚC
/* Tham số:
 *   :period_type  Loại kỳ: D/M/Q/Y
 *   :period_to    Kỳ tra cứu: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * GDP: năm GDP của mỗi mốc = năm của ngày cuối kỳ - 1 (năm liền trước đã có số liệu chính thức).
 * TPCP, TPDNRL: Nguồn (snapshot tháng, danh sách TP chưa đáo hạn/hủy ĐKGD tính đến cuối tháng):
 *   Tháng báo cáo được dùng: report_month_from <= tháng báo cáo <= report_month_to (đều là ngày đầu tháng), chỉ lấy đúng các tháng của kỳ, không lùi sang tháng cũ hơn; không có snapshot -> NULL:
 *   - Kỳ D   : ngày tra cứu = ngày cuối tháng -> tháng đó; ngày tra cứu < ngày cuối tháng -> tháng liền trước
 *   - Kỳ M/Q/Y : tháng trong quý/năm -> lấy tháng mới nhất có dữ liệu
 */
WITH 
-- 1a. THAM SỐ GỐC -> Ngày đầu + cuối kỳ tra cứu
params_base AS (
  SELECT
    :period_type AS period_type,
    CASE :period_type
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN TO_DATE(CONCAT(:period_to, '-01'))
      WHEN 'Q' THEN ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), (CAST(RIGHT(:period_to, 1) AS INT) - 1) * 3)
      WHEN 'Y' THEN MAKE_DATE(:period_to,1,1) -- Ngày đầu kỳ tra cứu
    END AS period_startdate, -- Ngày đầu kỳ tra cứu
    CASE :period_type
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), CAST(RIGHT(:period_to, 1) AS INT) * 3 - 1))
      WHEN 'Y' THEN MAKE_DATE(:period_to,12,31) -- Ngày cuối kỳ tra cứu
    END AS period_enddate -- Ngày cuối kỳ tra cứu
)
-- 1b. THAM SỐ 2 KỲ: cur = kỳ tra cứu, prev = kỳ liền trước
, params AS (
  SELECT 'cur' AS period_tag, period_type, period_startdate, period_enddate
  FROM params_base
  UNION ALL
  SELECT
    'prev' AS period_tag,
    period_type,
    CASE period_type
      WHEN 'D' THEN DATE_SUB(period_startdate, 1)
      ELSE ADD_MONTHS(period_startdate, MAP('M',-1,'Q',-3,'Y',-12)[period_type])
    END AS period_startdate, -- Ngày đầu kỳ trước
    CASE period_type
      WHEN 'D' THEN DATE_SUB(period_enddate, 1)
      ELSE LAST_DAY(ADD_MONTHS(period_startdate, MAP('M',-1,'Q',-3,'Y',-12)[period_type]))
    END AS period_enddate -- Ngày cuối kỳ này
  FROM params_base
)
-- ===== I. TPDNNY =====
-- 2. Dữ liệu cuối ngày của từng mã + phân loại chứng khoán + mệnh giá
, stock_eod AS (
  -- Lọc dữ liệu cuối ngày, tính mệnh giá
  SELECT t.*    
  FROM (
    SELECT
      s.tradingdate,
      s.symbol,
      CAST(s.listedshare AS DECIMAL(38,2)) AS listedshare,
      s.reference,
      CASE WHEN s.stocktype = '1' THEN 'TPDNNY' END AS loai_ck, -- TPDN niêm yết
      100000 * POWER(10, ROUND(LN(NULLIF(reference, 0) / 100000) / LN(10))) AS par_value, /* TPDNNY: Mệnh giá suy ngược từ giá tham chiếu (bội số 100000, bước nhảy x10) */
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s 
    WHERE s.stocktype = '1' -- TPDN niêm yết
  ) t 
  WHERE rn = 1 
)
-- 3. Tổng hợp theo loại chứng khoán + kỳ
, stock_agg AS (
  SELECT
    d.period_tag,
    s.loai_ck,
    SUM(s.listedshare * s.par_value) AS gt_ny_dkgd -- GT niêm yết/ĐKGD = KL niêm yết/ĐKGD x Mệnh giá (CQ: NULL)
  FROM stock_eod s
  JOIN (
    -- Ngày giao dịch gần nhất <= ngày cuối kỳ này, kỳ trước
    SELECT p.period_tag, MAX(si.tradingdate) AS tradingdate
    FROM stock_eod si
    CROSS JOIN params p
    WHERE si.tradingdate <= p.period_enddate
    GROUP BY p.period_tag
  ) d ON s.tradingdate = d.tradingdate
  GROUP BY period_tag, loai_ck
)
-- II. TPCP
, govbond_agg AS (
  SELECT 
    period_tag,
    'TPCP' AS loai_ck,
    SUM(listed_volume * 100000) AS gt_ny_dkgd -- Mệnh giá TPCP = 100.000
  FROM (
    -- Lọc lấy tháng mới nhất trong kỳ tra cứu + lọc snapshot date mới nhất của tháng
    SELECT 
      g.*,
      DENSE_RANK() OVER(PARTITION BY g.period_tag ORDER BY g.report_month_startdate DESC, g.ds_snpst_dt DESC) AS rk 
    FROM (
      SELECT 
        p.period_tag, p.period_type, p.period_startdate, p.period_enddate,
        MAKE_DATE(b.report_year, b.report_month, 1) AS report_month_startdate,
        b.bond_code, b.listed_volume, b.ds_snpst_dt
      FROM uat_hnx_stg.gov_bond_listed_list b
      CROSS JOIN params p
    ) g
    WHERE
      CASE
        -- Kỳ D: Ngày = Ngày cuối tháng -> Lấy tháng đó. Ngày < Ngày cuối tháng -> Lấy tháng liền trước
        WHEN g.period_type = 'D' THEN g.report_month_startdate = TRUNC(IF(g.period_enddate = LAST_DAY(g.period_enddate), g.period_enddate, ADD_MONTHS(g.period_enddate, -1)), 'MM') 
        -- Kỳ M/Q/Y: Lấy tháng báo cáo trong kỳ tra cứu
        ELSE g.report_month_startdate BETWEEN TRUNC(g.period_startdate, 'MM') AND TRUNC(g.period_enddate, 'MM') 
      END
  ) t 
  WHERE t.rk = 1
  GROUP BY period_tag
)
-- III. TPDNRL
, private_corpbond_agg AS (
  SELECT 
    period_tag,
    'TPDNRL' AS loai_ck,
    SUM(registered_trading_volume * par_value) AS gt_ny_dkgd
  FROM (
    -- Lọc lấy tháng mới nhất trong kỳ tra cứu + lọc snapshot date mới nhất của tháng
    SELECT 
      c1.*,
      DENSE_RANK() OVER(PARTITION BY period_tag ORDER BY report_month_startdate DESC, ds_snpst_dt DESC) AS rk
    FROM (
      SELECT
        p.period_tag, p.period_type, p.period_startdate, p.period_enddate,
        b.report_year, b.report_month,
        MAKE_DATE(b.report_year, b.report_month, 1) AS report_month_startdate,
        b.bond_code, b.registered_trading_volume, b.par_value, b.ds_snpst_dt
      FROM uat_hnx_stg.private_corp_bond_registration b
      CROSS JOIN params p
    ) c1
    WHERE (CASE
      -- Kỳ D: Ngày = Ngày cuối tháng -> Lấy tháng đó. Ngày < Ngày cuối tháng -> Lấy tháng liền trước
      WHEN period_type = 'D' THEN report_month_startdate = TRUNC(IF(period_enddate = LAST_DAY(period_enddate), period_enddate, ADD_MONTHS(period_enddate, -1)), 'MM') 
      -- Kỳ M/Q/Y: Lấy tháng báo cáo trong kỳ tra cứu
      ELSE report_month_startdate BETWEEN TRUNC(period_startdate, 'MM') AND TRUNC(period_enddate, 'MM') 
    END)
  ) c
  WHERE rk = 1
  GROUP BY period_tag
)
-- IV. GDP THAM CHIẾU (cách lấy theo file [19]): GDP NĂM TRƯỚC của năm chứa ngày cuối kỳ
, gdp AS (
  -- GDP theo kỳ này / kỳ trước: năm GDP = năm của ngày cuối kỳ - 1
  SELECT p.period_tag, g.period_year, g.gdp_val
  FROM params p
  LEFT JOIN (
    -- Quy tắc: quy đổi về VND (unit_code: 3 = Tỷ, 8 = Đồng, 23 = Triệu); ưu tiên Năm > Quý; nếu lấy Quý thì phải đủ 4 quý.
    SELECT period_year, gdp_val
    FROM (
      SELECT
        v.period_year,
        v.period_type,
        SUM(CAST(v.value AS DECIMAL(38,10)) * MAP('3', 1e9, '8', 1, '23', 1e6)[v.unit_code]) AS gdp_val, -- Quy đổi về VND
        COUNT(1) AS sl_ky,
        ROW_NUMBER() OVER(PARTITION BY v.period_year ORDER BY v.period_type DESC) AS rn         -- Ưu tiên Năm (4) > Quý (3)
      FROM uat_mrms_stg.risk_indicator_value v
      LEFT JOIN uat_mrms_stg.risk_indicator i ON i.id = v.indicator_id
      WHERE i.indicator_code = 'GDP_VN'
        AND v.period_type IN ('3', '4') -- 4: Năm, 3: Quý
        AND v.period_year IN (SELECT YEAR(period_enddate) - 1 FROM params)
        AND v.deleted = '0'
        AND v.ds_snpst_dt = '2026-10-23'
        AND i.ds_snpst_dt = '2026-10-23'
      GROUP BY v.period_year, v.period_type
    ) t
    WHERE rn = 1
      AND (period_type = '4' OR (period_type = '3' AND sl_ky = 4)) -- Quý phải đủ 4 quý
  ) g ON g.period_year = YEAR(p.period_enddate) - 1
)
-- V. TỔNG HỢP
-- Gộp các loại trái phiếu + dòng tổng TP (= TPCP + TPDNNY + TPDNRL)
, all_agg AS (
  SELECT
    period_tag,
    COALESCE(loai_ck, 'TP') AS loai_ck,  -- Mức chi tiết: loai_ck; mức tổng theo kỳ: 'TP'
    SUM(gt_ny_dkgd)    AS gt_ny_dkgd
  FROM (
    SELECT * FROM stock_agg
    UNION ALL
    SELECT * FROM govbond_agg
    UNION ALL
    SELECT * FROM private_corpbond_agg
  )
  GROUP BY GROUPING SETS ((period_tag, loai_ck), (period_tag))
)
-- TỔNG HỢP LÊN BIỂU ĐỒ: kỳ này + kỳ trước + % thay đổi
SELECT
  c.loai_ck,
  -- Kỳ tra cứu
  c.gt_ny_dkgd,
  -- Kỳ trước
  p.gt_ny_dkgd AS gt_ny_dkgd_kytruoc,
  -- % so với kỳ trước
  ROUND((c.gt_ny_dkgd    - p.gt_ny_dkgd)    / NULLIF(p.gt_ny_dkgd, 0)    * 100, 2) AS gt_ny_dkgd_pct,
  -- GT niêm yết / GDP (%) -> Chỉ tính với tổng GT niêm yết của 3 loại TP
  IF(c.loai_ck = 'TP', ROUND(c.gt_ny_dkgd / NULLIF(gc.gdp_val, 0) * 100, 2), NULL) AS gt_ny_gdp,         -- Kỳ tra cứu
  IF(c.loai_ck = 'TP', ROUND(p.gt_ny_dkgd / NULLIF(gp.gdp_val, 0) * 100, 2), NULL) AS gt_ny_gdp_kytruoc, -- Kỳ trước
  IF(c.loai_ck = 'TP', ROUND(c.gt_ny_dkgd / NULLIF(gc.gdp_val, 0) * 100 - p.gt_ny_dkgd / NULLIF(gp.gdp_val, 0) * 100, 2), NULL) AS gt_ny_gdp_chenhlech -- So với kỳ trước (điểm %)
FROM all_agg c
LEFT JOIN all_agg p ON p.loai_ck = c.loai_ck AND p.period_tag = 'prev'
LEFT JOIN gdp gc ON gc.period_tag = 'cur'
LEFT JOIN gdp gp ON gp.period_tag = 'prev'
WHERE c.period_tag = 'cur'
ORDER BY MAP('CP',1,'CCQ',2,'ETF',3,'CQ',4,'TPCP',5,'TPDNNY',6,'TPDNRL',7)[loai_ck]
;