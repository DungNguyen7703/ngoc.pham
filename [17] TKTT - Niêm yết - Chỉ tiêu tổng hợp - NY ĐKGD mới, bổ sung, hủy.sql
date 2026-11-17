-- THỐNG KÊ NIÊM YẾT/ĐKGD >> NY/ĐKGD MỚI/BỔ SUNG, HỦY NY/ĐKGD: TÍNH TẠI 1 KỲ + % SO VỚI KỲ TRƯỚC
/* Tham số:
 *   :period_type  Loại kỳ: M/Q/Y
 *   :period_to    Kỳ tra cứu: Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * CHỈ TIÊU NY/ĐKGD MỚI/BỔ SUNG, HỦY NY/ĐKGD:
 *   CP, CCQ, ETF, CQ, TPDNNY: listing_status_change (HNX + HOSE, snapshot mới nhất), kỳ theo effective_date; phân loại theo jad_stockinfor
 *   TPCP  : gov_bond_additional_listing, kỳ theo listing_change_date; Niêm yết mới / Niêm yết bổ sung / Đáo hạn (= hủy)
 *   TPDNRL: registration_status_change, kỳ theo report_year/report_month; Đăng ký giao dịch / Hủy đăng ký giao dịch
 */
WITH 
-- 1a. THAM SỐ GỐC -> Ngày đầu + cuối kỳ tra cứu
params_base AS (
  SELECT
    :period_type AS period_type,
    CASE :period_type
      WHEN 'M' THEN TO_DATE(CONCAT(:period_to, '-01'))
      WHEN 'Q' THEN ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), (CAST(RIGHT(:period_to, 1) AS INT) - 1) * 3)
      WHEN 'Y' THEN MAKE_DATE(:period_to, 1, 1)
    END AS period_startdate,
    CASE :period_type
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), CAST(RIGHT(:period_to, 1) AS INT) * 3 - 1))
      WHEN 'Y' THEN MAKE_DATE(:period_to, 12, 31)
    END AS period_enddate
)
-- 1b. THAM SỐ 2 KỲ: cur = kỳ tra cứu, prev = kỳ liền trước
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
-- I. CP, CCQ, ETF, CQ, TPDNNY 
-- 2. Phân loại chứng khoán 
---- 2.1. Thông tin chứng khoán cuối mỗi ngày (Không lọc theo kỳ: mã hủy NY có thể đã ngừng giao dịch từ trước ngày hiệu lực)
, stock_eod AS (
  SELECT t.*
  FROM (
    SELECT
      s.tradingdate,
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
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s
    WHERE s.floorcode <> '03' -- Không lấy chứng khoán phái sinh
  ) t 
  WHERE rn = 1 
)
---- 2.2. Danh mục chứng khoán (thông tin không đổi) --> Lấy dữ liệu mới nhất
, stock_portfolio AS (
  SELECT symbol, loai_ck, par_value
  FROM (
  SELECT 
    symbol, loai_ck, par_value,
    ROW_NUMBER() OVER(PARTITION BY symbol ORDER BY tradingdate DESC) AS rn
  FROM stock_eod
  ) p 
  WHERE p.rn = 1
)
-- 3. TỔNG NY/ĐKGD MỚI/BỔ SUNG, HỦY NY/ĐKGD theo loại chứng khoán + kỳ
, stock_agg AS (
  SELECT
    p.period_tag,
    s.loai_ck,
    COUNT(IF(ls.new_listed_shares > 0, ls.ticker_symbol, NULL)) AS so_ma_ny_dkgd_moi,
    NVL(SUM(ls.new_listed_shares), 0) + NVL(SUM(ls.additional_listed_shares), 0) AS kl_ny_dkgd_moi_bosung,
    COUNT(IF(ls.delisted_shares > 0, ls.ticker_symbol, NULL)) AS so_ma_huy_ny_dkgd,
    NVL(SUM(ls.delisted_shares), 0) AS kl_huy_ny_dkgd
  FROM (
    -- HNX / UPCOM
    SELECT ticker_symbol, effective_date, first_trading_date, new_listed_shares, additional_listed_shares, delisted_shares, 
      dense_rank() over(PARTITION BY report_year, report_month ORDER BY ds_snpst_dt DESC) snapshotdate_rk
    FROM uat_hnx_stg.listing_status_change
    UNION ALL
    -- HOSE
    SELECT ticker_symbol, effective_date, first_trading_date, new_listed_shares, additional_listed_shares, delisted_shares, 
      dense_rank() over(PARTITION BY report_year, report_month ORDER BY ds_snpst_dt DESC) snapshotdate_rk
    FROM uat_hose_stg.listing_status_change
  ) ls
  JOIN params p ON ls.effective_date BETWEEN p.period_startdate AND p.period_enddate -- Thông tin NY/ĐKGD mới/bổ sung/hủy của kỳ này, kỳ trước
  JOIN stock_portfolio s ON ls.ticker_symbol = s.symbol 
  WHERE ls.snapshotdate_rk = 1 -- Lọc snapshot date mới nhất của báo cáo tháng
  GROUP BY p.period_tag, s.loai_ck
)
-- II. TPCP: dữ liệu phát sinh NY MỚI, NY BỔ SUNG, HỦY NY, kỳ theo listing_change_date
, govbond_agg AS (
  SELECT
    p.period_tag,
    'TPCP' AS loai_ck,
    COUNT(IF(g.status = 'Niêm yết mới', g.bond_code, NULL)) AS so_ma_ny_dkgd_moi,
    NVL(SUM(IF(g.status IN ('Niêm yết mới', 'Niêm yết bổ sung'), g.volume, 0)), 0) AS kl_ny_dkgd_moi_bosung,
    COUNT(IF(g.status = 'Đáo hạn', g.bond_code, NULL)) AS so_ma_huy_ny_dkgd,
    NVL(SUM(IF(g.status = 'Đáo hạn', g.volume, 0)), 0) AS kl_huy_ny_dkgd
  FROM (
    -- Mỗi tháng báo cáo chỉ lấy snapshot mới nhất
    SELECT *, DENSE_RANK() OVER (PARTITION BY report_year, report_month ORDER BY ds_snpst_dt DESC) AS rk
    FROM uat_hnx_stg.gov_bond_additional_listing
  ) g
  JOIN params p ON g.listing_change_date BETWEEN p.period_startdate AND p.period_enddate
  WHERE g.rk = 1
  GROUP BY p.period_tag
)
-- III. TPDNRL: dữ liệu phát sinh ĐKGD MỚI, HỦY ĐKGD, kỳ theo report_year/report_month
, private_corpbond_agg AS (
  SELECT
    p.period_tag,
    'TPDNRL' AS loai_ck,
    COUNT(IF(c.trading_registration_status = 'Đăng ký giao dịch', c.bond_code, NULL)) AS so_ma_ny_dkgd_moi,
    NVL(SUM(IF(c.trading_registration_status = 'Đăng ký giao dịch', c.currently_registered_trading_volume, 0)), 0) AS kl_ny_dkgd_moi_bosung,
    COUNT(IF(c.trading_registration_status = 'Hủy đăng ký giao dịch', c.bond_code, NULL)) AS so_ma_huy_ny_dkgd,
    NVL(SUM(IF(c.trading_registration_status = 'Hủy đăng ký giao dịch', c.currently_registered_trading_volume, 0)), 0) AS kl_huy_ny_dkgd
  FROM (
    -- Mỗi tháng báo cáo chỉ lấy snapshot mới nhất
    SELECT *, DENSE_RANK() OVER (PARTITION BY report_year, report_month ORDER BY ds_snpst_dt DESC) AS rk
    FROM uat_hnx_stg.registration_status_change
  ) c
  JOIN params p 
    ON MAKE_DATE(CAST(c.report_year AS INT), CAST(c.report_month AS INT), 1) BETWEEN p.period_startdate AND p.period_enddate
  WHERE c.rk = 1
  GROUP BY p.period_tag
)
-- IV. TỔNG HỢP: gộp các loại chứng khoán
, all_agg AS (
  SELECT * FROM stock_agg
  UNION ALL
  SELECT * FROM govbond_agg
  UNION ALL
  SELECT * FROM private_corpbond_agg
)
-- TỔNG HỢP LÊN BIỂU ĐỒ: kỳ này + kỳ trước + % thay đổi (kỳ trước = 0 -> NULL)
SELECT
  loai_ck,
  so_ma_ny_dkgd_moi, so_ma_ny_dkgd_moi_kytruoc,
  (so_ma_ny_dkgd_moi - so_ma_ny_dkgd_moi_kytruoc) / NULLIF(so_ma_ny_dkgd_moi_kytruoc, 0) * 100 AS so_ma_ny_dkgd_moi_sokytruoc_pct,
  kl_ny_dkgd_moi_bosung, kl_ny_dkgd_moi_bosung_kytruoc,
  (kl_ny_dkgd_moi_bosung - kl_ny_dkgd_moi_bosung_kytruoc) / NULLIF(kl_ny_dkgd_moi_bosung_kytruoc, 0) * 100 AS kl_ny_dkgd_moi_bosung_sokytruoc_pct,
  so_ma_huy_ny_dkgd, so_ma_huy_ny_dkgd_kytruoc,
  (so_ma_huy_ny_dkgd - so_ma_huy_ny_dkgd_kytruoc) / NULLIF(so_ma_huy_ny_dkgd_kytruoc, 0) * 100 AS so_ma_huy_ny_dkgd_sokytruoc_pct,
  kl_huy_ny_dkgd, kl_huy_ny_dkgd_kytruoc,
  (kl_huy_ny_dkgd - kl_huy_ny_dkgd_kytruoc) / NULLIF(kl_huy_ny_dkgd_kytruoc, 0) * 100 AS kl_huy_ny_dkgd_sokytruoc_pct
FROM (
  SELECT
    l.stt, 
    l.loai_ck,
    NVL(c.so_ma_ny_dkgd_moi, 0)     AS so_ma_ny_dkgd_moi,
    NVL(c.kl_ny_dkgd_moi_bosung, 0) AS kl_ny_dkgd_moi_bosung,
    NVL(c.so_ma_huy_ny_dkgd, 0)     AS so_ma_huy_ny_dkgd,
    NVL(c.kl_huy_ny_dkgd, 0)        AS kl_huy_ny_dkgd,
    NVL(p.so_ma_ny_dkgd_moi, 0)     AS so_ma_ny_dkgd_moi_kytruoc,
    NVL(p.kl_ny_dkgd_moi_bosung, 0) AS kl_ny_dkgd_moi_bosung_kytruoc,
    NVL(p.so_ma_huy_ny_dkgd, 0)     AS so_ma_huy_ny_dkgd_kytruoc,
    NVL(p.kl_huy_ny_dkgd, 0)        AS kl_huy_ny_dkgd_kytruoc
  FROM (SELECT POSEXPLODE(ARRAY('CP', 'CCQ', 'ETF', 'CQ', 'TPCP', 'TPDNNY', 'TPDNRL')) AS (stt, loai_ck)) l -- Danh sách loại chứng khoán
  LEFT JOIN all_agg c ON c.loai_ck = l.loai_ck AND c.period_tag = 'cur'  -- Số liệu kỳ này
  LEFT JOIN all_agg p ON p.loai_ck = l.loai_ck AND p.period_tag = 'prev' -- Số liệu kỳ trước
)
ORDER BY stt
;