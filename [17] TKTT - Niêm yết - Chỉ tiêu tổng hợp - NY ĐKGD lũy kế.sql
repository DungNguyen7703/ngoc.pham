-- THỐNG KÊ NIÊM YẾT/ĐKGD >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ + % SO VỚI KỲ TRƯỚC
/* Tham số:
 *   :period_type  Loại kỳ: M/Q/Y
 *   :period_to    Kỳ tra cứu: Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * % so với kỳ trước = (kỳ này - kỳ trước) / kỳ trước * 100. Kỳ trước = 0 hoặc NULL -> NULL.
 * CHỈ TIÊU SỐ MÃ, KL, GT NIÊM YẾT/ĐKGD TÍNH ĐẾN KỲ TRA CỨU:
 *   CP, CCQ, ETF, CQ, TPDNNY: jad_stockinfor Lấy dữ liệu ngày mới nhất
 *   TPCP, TPDNRL: Nguồn (snapshot tháng, danh sách TP chưa đáo hạn/hủy ĐKGD tính đến cuối tháng):
 *     - Chỉ lấy đúng các tháng của kỳ (đầu tháng >= đầu kỳ và <= cuối kỳ), không lùi sang tháng cũ hơn;
 *     - Lấy tháng mới nhất có dữ liệu trong kỳ, snapshot mới nhất của tháng
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
-- B. CỔ PHIẾU, CHỨNG CHỈ QUỸ, ETF, CHỨNG QUYỀN, TPDNNY: Tổng hợp theo loại chứng khoán + kỳ
---- Dữ liệu cuối ngày của từng mã 
, stock_eod AS (
  SELECT t.*
  FROM (
    SELECT
      d.period_tag,
      s.symbol,
      CASE
        WHEN s.stocktype = '1' THEN 'TPDNNY'                           -- TPDN niêm yết
        WHEN s.stocktype = '2' THEN 'CP'                               -- Cổ phiếu
        WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'M' THEN 'CCQ' -- Chứng chỉ quỹ (không gồm ETF)
        WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'E' THEN 'ETF' -- Chứng chỉ quỹ ETF
        WHEN s.stocktype = '4' THEN 'CQ'                               -- Chứng quyền (Không cần thêm đk floorcode do đã đưa vào đk WHERE floorcode <> '03')
        --WHEN SUBSTR(s.productid, 6, 2) = 'EW' THEN 'CQ'                -- Chứng quyền (EW = Equity Warrant)
      END AS loai_ck,
      CAST(s.listedshare AS BIGINT) AS listedshare,
      CASE 
        WHEN s.stocktype = '1' THEN 100000 * POWER(10, ROUND(LN(NULLIF(reference, 0) / 100000) / LN(10))) -- TPDNNY: Mệnh giá suy ngược từ giá tham chiếu (bội số 100000, bước nhảy x10)
        WHEN s.stocktype IN ('2','3','6') THEN 10000 -- CP, CCQ, ETF: 10000đ
        -- CQ: Không có thông tin Mệnh giá
      END AS par_value, -- Mệnh giá
      ROW_NUMBER() OVER(PARTITION BY d.period_tag, s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s 
    JOIN (
      -- 2. Ngày giao dịch gần nhất <= ngày cuối kỳ này, kỳ trước
      SELECT p.period_tag, MAX(s.tradingdate) AS tradingdate
      FROM uat_mdds_stg.jad_stockinfor s
      CROSS JOIN params p
      WHERE s.tradingdate <= p.period_enddate
      GROUP BY p.period_tag
    ) d ON s.tradingdate = d.tradingdate 
    WHERE s.floorcode <> '03' -- Không lấy chứng khoán phái sinh
  ) t 
  WHERE rn = 1 
)
---- Tổng theo loại chứng khoán
, stock_cum AS (
  SELECT
    period_tag ky,
    loai_ck,
    COUNT(symbol) AS so_ma_ny_dkgd,            -- Số lượng mã niêm yết/ĐKGD
    SUM(listedshare) AS kl_ny_dkgd,            -- KL niêm yết/ĐKGD
    SUM(listedshare * par_value) AS gt_ny_dkgd -- GT niêm yết/ĐKGD = KL x Mệnh giá
  FROM stock_eod
  GROUP BY period_tag, loai_ck
)
-- II. TPCP: 
, govbond_cum AS (
  SELECT 
    period_tag AS ky,
    'TPCP' AS loai_ck,
    COUNT(bond_code) AS so_ma_ny_dkgd,
    SUM(listed_volume) AS kl_ny_dkgd,
    SUM(listed_volume * 100000) AS gt_ny_dkgd -- Mệnh giá TPCP = 100.000
  FROM (
    -- Chỉ lấy các tháng thuộc kỳ -> tháng mới nhất của kỳ + snapshot mới nhất của tháng
    SELECT 
      p.period_tag, b.bond_code, b.listed_volume,
      DENSE_RANK() OVER(PARTITION BY p.period_tag ORDER BY MAKE_DATE(b.report_year, b.report_month, 1) DESC, b.ds_snpst_dt DESC) AS rk 
    FROM uat_hnx_stg.gov_bond_listed_list b
    JOIN params p ON MAKE_DATE(b.report_year, b.report_month, 1) BETWEEN p.period_startdate AND p.period_enddate
  ) t 
  WHERE rk = 1
  GROUP BY period_tag
)
-- III. TPDNRL
, private_corpbond_cum AS (
  SELECT 
    period_tag AS ky,
    'TPDNRL' AS loai_ck,
    COUNT(bond_code) AS so_ma_ny_dkgd,
    SUM(registered_trading_volume) AS kl_ny_dkgd,
    SUM(registered_trading_volume * par_value) AS gt_ny_dkgd
  FROM (
    SELECT
      p.period_tag, c.bond_code, c.registered_trading_volume, c.par_value,
      DENSE_RANK() OVER(PARTITION BY p.period_tag ORDER BY MAKE_DATE(c.report_year, c.report_month, 1) DESC, c.ds_snpst_dt DESC) AS rk
    FROM uat_hnx_stg.private_corp_bond_registration c
    JOIN params p ON MAKE_DATE(c.report_year, c.report_month, 1) BETWEEN p.period_startdate AND p.period_enddate
  ) t
  WHERE rk = 1
  GROUP BY period_tag
)
-- IV. TỔNG HỢP: gộp tất cả các loại chứng khoán
, all_cum AS (
  SELECT * FROM stock_cum
  UNION ALL
  SELECT * FROM govbond_cum
  UNION ALL
  SELECT * FROM private_corpbond_cum
)
-- TỔNG HỢP LÊN BIỂU ĐỒ: kỳ này + kỳ trước + % thay đổi
SELECT
  l.stt,
  l.loai_ck,
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
FROM (SELECT POSEXPLODE(ARRAY('CP', 'CCQ', 'ETF', 'CQ', 'TPCP', 'TPDNNY', 'TPDNRL')) AS (stt, loai_ck)) l -- Danh sách loại chứng khoán 
LEFT JOIN all_cum c ON l.loai_ck = c.loai_ck AND c.ky = 'cur'  -- Số liệu kỳ này
LEFT JOIN all_cum p ON l.loai_ck = p.loai_ck AND p.ky = 'prev' -- Số liệu kỳ trước
WHERE c.ky = 'cur'
ORDER BY l.stt
;