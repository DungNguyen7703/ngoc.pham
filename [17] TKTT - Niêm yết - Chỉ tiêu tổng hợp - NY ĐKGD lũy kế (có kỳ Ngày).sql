-- THỐNG KÊ NIÊM YẾT/ĐKGD >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ + % SO VỚI KỲ TRƯỚC
/* Tham số:
 *   :period_type  Loại kỳ: D/M/Q/Y
 *   :period_to    Kỳ tra cứu: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * Kỳ trước: D = ngày liền trước; M = tháng trước; Q = quý trước; Y = năm trước.
 * % so với kỳ trước = (kỳ này - kỳ trước) / kỳ trước * 100. Kỳ trước = 0 hoặc NULL -> NULL.
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
    END AS period_startdate,
    CASE :period_type
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), CAST(RIGHT(:period_to, 1) AS INT) * 3 - 1))
      WHEN 'Y' THEN MAKE_DATE(:period_to,12,31) -- Ngày cuối kỳ tra cứu
    END AS period_enddate
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
      WHEN 'M' THEN ADD_MONTHS(period_startdate, -1)
      WHEN 'Q' THEN ADD_MONTHS(period_startdate, -3)
      WHEN 'Y' THEN ADD_MONTHS(period_startdate, -12)
    END AS period_startdate,
    CASE period_type
      WHEN 'D' THEN DATE_SUB(period_enddate, 1)
      WHEN 'M' THEN LAST_DAY(ADD_MONTHS(period_enddate, -1))
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(period_enddate, -3))
      WHEN 'Y' THEN LAST_DAY(ADD_MONTHS(period_enddate, -12))
    END AS period_enddate
  FROM params_base
)
-- ===== I. CỔ PHIẾU, CHỨNG CHỈ QUỸ, ETF, CHỨNG QUYỀN, TPDNNY =====
-- 2. Ngày giao dịch gần nhất <= ngày cuối kỳ này, kỳ trước
, last_tradingdate AS (
  SELECT p.period_tag, MAX(s.tradingdate) AS tradingdate
  FROM uat_mdds_stg.jad_stockinfor s
  CROSS JOIN params p
  WHERE s.tradingdate <= p.period_enddate
  GROUP BY p.period_tag
)
-- 3. Dữ liệu cuối ngày của từng mã + phân loại chứng khoán + mệnh giá (cho từng kỳ)
, stock_eod AS (
  -- Bước 2. Lọc dữ liệu cuối ngày, tính mệnh giá
  SELECT t.*    
  FROM (
    -- Bước 1. Lấy số liệu tại ngày giao dịch cuối kỳ tra cứu
    SELECT
      d.period_tag,
      s.symbol,
      CAST(s.listedshare AS BIGINT) AS listedshare,
      s.reference,
      CASE
        WHEN s.stocktype = '1' THEN 'TPDNNY'                           -- TPDN niêm yết
        WHEN s.stocktype = '2' THEN 'CP'                               -- Cổ phiếu
        WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'M' THEN 'CCQ' -- Chứng chỉ quỹ (không gồm ETF)
        WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'E' THEN 'ETF' -- Chứng chỉ quỹ ETF
        WHEN SUBSTR(s.productid, 6, 2) = 'EW' THEN 'CQ'                -- Chứng quyền (EW = Equity Warrant)
      END AS loai_ck,
      CASE 
        WHEN s.stocktype = '1' THEN 100000 * POWER(10, ROUND(LN(NULLIF(reference, 0) / 100000) / LN(10))) -- TPDNNY: Mệnh giá suy ngược từ giá tham chiếu (bội số 100000, bước nhảy x10)
        WHEN s.stocktype IN ('2','3','6') OR SUBSTR(s.productid, 6, 2) = 'EW' THEN 10000 -- CP, CCQ, ETF: 10000đ
        -- CQ: không có mệnh giá -> NULL
      END AS par_value, -- Mệnh giá
      ROW_NUMBER() OVER(PARTITION BY d.period_tag, s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s 
    JOIN last_tradingdate d ON s.tradingdate = d.tradingdate -- Ngày giao dịch cuối kỳ
    WHERE s.floorcode <> '03' -- Không lấy chứng khoán phái sinh
  ) t 
  WHERE rn = 1 
)
-- 4. Tổng hợp theo loại chứng khoán + kỳ
, stock_agg AS (
  SELECT
    period_tag,
    loai_ck,
    COUNT(symbol) AS so_ma_ny_dkgd, -- Số lượng mã niêm yết/ĐKGD
    SUM(listedshare) AS kl_ny_dkgd, -- KL niêm yết/ĐKGD
    SUM(listedshare * par_value) AS gt_ny_dkgd -- GT niêm yết/ĐKGD = KL niêm yết/ĐKGD x Mệnh giá (CQ: NULL)
  FROM stock_eod
  GROUP BY period_tag, loai_ck
)
-- II. TPCP
, govbond_agg AS (
  SELECT 
    period_tag,
    'TPCP' AS loai_ck,
    COUNT(bond_code) AS so_ma_ny_dkgd,
    SUM(listed_volume) AS kl_ny_dkgd,
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
    COUNT(bond_code) AS so_ma_ny_dkgd,
    SUM(registered_trading_volume) AS kl_ny_dkgd,
    SUM(registered_trading_volume * par_value) AS gt_ny_dkgd
  FROM (
    SELECT
      -- Lọc lấy tháng mới nhất trong kỳ tra cứu + lọc snapshot date mới nhất của tháng
      c.*,
      DENSE_RANK() OVER(PARTITION BY c.period_tag ORDER BY c.report_month_startdate DESC, c.ds_snpst_dt DESC) AS rk
    FROM (
      SELECT
        p.period_tag, p.period_type, p.period_startdate, p.period_enddate,
        MAKE_DATE(b.report_year, b.report_month, 1) AS report_month_startdate,
        b.bond_code, b.registered_trading_volume, b.par_value, b.ds_snpst_dt
      FROM uat_hnx_stg.private_corp_bond_registration b
      CROSS JOIN params p
    ) c
    WHERE
      CASE
        -- Kỳ D: Ngày = Ngày cuối tháng -> Lấy tháng đó. Ngày < Ngày cuối tháng -> Lấy tháng liền trước
        WHEN c.period_type = 'D' THEN c.report_month_startdate = TRUNC(IF(c.period_enddate = LAST_DAY(c.period_enddate), c.period_enddate, ADD_MONTHS(c.period_enddate, -1)), 'MM') 
        -- Kỳ M/Q/Y: Lấy tháng báo cáo trong kỳ tra cứu
        ELSE c.report_month_startdate BETWEEN TRUNC(c.period_startdate, 'MM') AND TRUNC(c.period_enddate, 'MM') 
      END
  ) t
  WHERE rk = 1
  GROUP BY period_tag
)
-- IV. TỔNG HỢP
-- Gộp tất cả các loại chứng khoán
, all_agg AS (
  SELECT * FROM stock_agg
  UNION ALL
  SELECT * FROM govbond_agg
  UNION ALL
  SELECT * FROM private_corpbond_agg
)
-- TỔNG HỢP LÊN BIỂU ĐỒ: kỳ này + kỳ trước + % thay đổi
SELECT
  c.loai_ck,
  -- Kỳ tra cứu
  c.so_ma_ny_dkgd,
  c.kl_ny_dkgd,
  c.gt_ny_dkgd,
  -- Kỳ trước
  p.so_ma_ny_dkgd AS so_ma_ny_dkgd_kytruoc,
  p.kl_ny_dkgd    AS kl_ny_dkgd_kytruoc,
  p.gt_ny_dkgd    AS gt_ny_dkgd_kytruoc,
  -- % so với kỳ trước
  ROUND((c.so_ma_ny_dkgd - p.so_ma_ny_dkgd) / NULLIF(p.so_ma_ny_dkgd, 0) * 100, 2) AS so_ma_ny_dkgd_pct,
  ROUND((c.kl_ny_dkgd    - p.kl_ny_dkgd)    / NULLIF(p.kl_ny_dkgd, 0)    * 100, 2) AS kl_ny_dkgd_pct,
  ROUND((c.gt_ny_dkgd    - p.gt_ny_dkgd)    / NULLIF(p.gt_ny_dkgd, 0)    * 100, 2) AS gt_ny_dkgd_pct
FROM all_agg c
LEFT JOIN all_agg p ON p.loai_ck = c.loai_ck AND p.period_tag = 'prev'
WHERE c.period_tag = 'cur'
ORDER BY MAP('CP',1,'CCQ',2,'ETF',3,'CQ',4,'TPCP',5,'TPDNNY',6,'TPDNRL',7)[loai_ck]
;

-- ========== TÍNH 1 KỲ NÀY ========== --
-- THỐNG KÊ NIÊM YẾT/ĐKGD >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ
/* Tham số:
 *   :period_type  Loại kỳ: D/M/Q/Y
 *   :period_to    Kỳ tra cứu: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * TPCP, TPDNRL: Nguồn (snapshot tháng, danh sách TP chưa đáo hạn/hủy ĐKGD tính đến cuối tháng):
 *   Tháng báo cáo được dùng: report_month_from <= tháng báo cáo <= report_month_to (đều là ngày đầu tháng), chỉ lấy đúng các tháng của kỳ, không lùi sang tháng cũ hơn; không có snapshot -> NULL:
 *   - Kỳ D   : ngày tra cứu = ngày cuối tháng -> tháng đó; ngày tra cứu < ngày cuối tháng -> tháng liền trước
 *   - Kỳ M/Q/Y : tháng trong quý/năm -> lấy tháng mới nhất có dữ liệu
 */
WITH 
-- 1. THAM SỐ -> Ngày đầu + cuối kỳ tra cứu
params AS (
  SELECT
    :period_type AS period_type,
    :period_to   AS period_to,
    CASE :period_type
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN TO_DATE(CONCAT(:period_to, '-01'))
      WHEN 'Q' THEN ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), (CAST(RIGHT(:period_to, 1) AS INT) - 1) * 3)
      WHEN 'Y' THEN TO_DATE(CONCAT(:period_to, '-01-01'))
    END AS period_startdate, -- Ngày đầu kỳ tra cứu
    CASE :period_type
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), CAST(RIGHT(:period_to, 1) AS INT) * 3 - 1))
      WHEN 'Y' THEN TO_DATE(CONCAT(:period_to, '-12-31'))
    END AS period_enddate    -- Ngày cuối kỳ tra cứu
)
-- 2. Ngày giao dịch gần nhất <= ngày cuối kỳ
, last_tradingdate AS (
  SELECT MAX(s.tradingdate) AS tradingdate
  FROM uat_mdds_stg.jad_stockinfor s
  CROSS JOIN params p
  WHERE s.tradingdate <= p.period_enddate
)
-- =============== I. CỔ PHIẾU, CHỨNG CHỈ QUỸ, ETF, CHỨNG QUYỀN, TPDNNY
-- 3. Dữ liệu cuối ngày của từng mã tại ngày giao dịch gần nhất với ngày cuối kỳ tra cứu + phân loại chứng khoán + mệnh giá
, stock_eod AS (
  SELECT
    symbol,
    loai_ck,
    listedshare,
    CASE 
      WHEN loai_ck = 'TPDNNY' THEN 100000 * POWER(10, ROUND(LN(NULLIF(reference, 0) / 100000) / LN(10))) -- Mệnh giá suy ngược từ giá tham chiếu (bội số 100000, bước nhảy x10)
      WHEN loai_ck IN ('CP', 'CCQ', 'ETF') THEN 10000
      -- CQ: không có mệnh giá -> NULL
    END AS parvalue -- Mệnh giá
  FROM (
    SELECT
      s.symbol,
      CAST(s.listedshare AS BIGINT) AS listedshare,
      s.reference,
      CASE
        WHEN s.stocktype = '1' THEN 'TPDNNY'                           -- TPDN niêm yết
        WHEN s.stocktype = '2' THEN 'CP'                               -- Cổ phiếu
        WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'M' THEN 'CCQ' -- Chứng chỉ quỹ (không gồm ETF)
        WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'E' THEN 'ETF' -- Chứng chỉ quỹ ETF
        WHEN SUBSTR(s.productid, 6, 2) = 'EW' THEN 'CQ'                -- Chứng quyền (EW = Equity Warrant)
      END AS loai_ck,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s 
    JOIN last_tradingdate d ON s.tradingdate = d.tradingdate -- Số liệu tính đến ngày giao dịch gần nhất <= ngày cuối kỳ tra cứu
    WHERE s.floorcode <> '03' -- Không lấy chứng khoán phái sinh
  ) t 
  WHERE rn = 1 
)
-- 5. Tổng hợp theo loại chứng khoán
, stock_agg AS (
  SELECT
    loai_ck,
    COUNT(symbol) AS so_ma_ny_dkgd,            -- Số lượng mã niêm yết/ĐKGD
    SUM(listedshare) AS kl_ny_dkgd,            -- KL niêm yết/ĐKGD
    SUM(listedshare * parvalue) AS gt_ny_dkgd  -- GT niêm yết/ĐKGD = KL niêm yết/ĐKGD x Mệnh giá (CQ: NULL)
  FROM stock_eod
  GROUP BY loai_ck
)
-- 2. TPCP
, govbond_agg AS (
  SELECT 
    'TPCP' AS loai_ck,
    COUNT(bond_code) AS so_ma_ny_dkgd,
    SUM(listed_volume) AS kl_ny_dkgd,
    SUM(listed_volume * 100000) AS gt_ny_dkgd -- Mệnh giá TPCP = 100.000
    -- , MAX(DATE_FORMAT(report_month_startdate, 'yyyy-MM')) AS thang_bc
  FROM (
    -- Lọc lấy tháng mới nhất trong kỳ tra cứu + lọc snapshot date mới nhất của tháng
    SELECT 
      g.*,
      DENSE_RANK() OVER(ORDER BY g.report_month_startdate DESC, g.ds_snpst_dt DESC) AS rk 
    FROM (
      SELECT 
        MAKE_DATE(report_year, report_month, 1) AS report_month_startdate, -- Ngày đầu tháng báo cáo
        report_year, report_month, bond_code, listed_volume, ds_snpst_dt
      FROM uat_hnx_stg.gov_bond_listed_list
    ) g
    CROSS JOIN params p
    WHERE
      CASE
        -- Kỳ D: Ngày = Ngày cuối tháng -> Lấy tháng đó. Ngày < Ngày cuối tháng -> Lấy tháng liền trước
        WHEN p.period_type = 'D' THEN g.report_month_startdate = TRUNC(IF(p.period_enddate = LAST_DAY(p.period_enddate), p.period_enddate, ADD_MONTHS(p.period_enddate, -1)), 'MM') 
        -- Kỳ M/Q/Y: Lấy tháng báo cáo trong kỳ tra cứu
        ELSE g.report_month_startdate BETWEEN TRUNC(p.period_startdate, 'MM') AND TRUNC(p.period_enddate, 'MM') 
      END
  ) t 
  WHERE t.rk = 1
)
-- 3. TPDNRL
, private_corpbond_agg AS (
  SELECT 
    'TPDNRL' AS loai_ck,
    COUNT(bond_code) AS so_ma_ny_dkgd,
    SUM(registered_trading_volume) AS kl_ny_dkgd,
    SUM(registered_trading_volume * par_value) AS gt_ny_dkgd
    --, MAX(DATE_FORMAT(report_month_startdate, 'yyyy-MM')) AS report_month
  FROM (
    -- Lọc lấy tháng mới nhất trong kỳ tra cứu + lọc snapshot date mới nhất của tháng
    SELECT
      c.*,
      DENSE_RANK() OVER(ORDER BY c.report_month_startdate DESC, c.ds_snpst_dt DESC) AS rk
    FROM (
      SELECT
        MAKE_DATE(report_year, report_month, 1) AS report_month_startdate, -- Ngày đầu tháng báo cáo
        bond_code, registered_trading_volume, par_value, ds_snpst_dt
      FROM uat_hnx_stg.private_corp_bond_registration
    ) c
    CROSS JOIN params p
    WHERE
      CASE
        -- Kỳ D: Ngày = Ngày cuối tháng -> Lấy tháng đó. Ngày < Ngày cuối tháng -> Lấy tháng liền trước
        WHEN p.period_type = 'D' THEN c.report_month_startdate = TRUNC(IF(p.period_enddate = LAST_DAY(p.period_enddate), p.period_enddate, ADD_MONTHS(p.period_enddate, -1)), 'MM') 
        -- Kỳ M/Q/Y: Lấy tháng báo cáo trong kỳ tra cứu
        ELSE c.report_month_startdate BETWEEN TRUNC(p.period_startdate, 'MM') AND TRUNC(p.period_enddate, 'MM') 
      END
  ) t
  WHERE rk = 1
)
-- TỔNG HỢP LÊN BIỂU ĐỒ
SELECT * FROM stock_agg s
UNION ALL
SELECT * FROM govbond_agg
UNION ALL
SELECT * FROM private_corpbond_agg
;