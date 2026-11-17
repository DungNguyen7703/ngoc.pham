-- 17. THỐNG KÊ NIÊM YẾT/ĐKGD >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ + % SO VỚI KỲ TRƯỚC
/* Tham số:
 *   :period_type  Loại kỳ: M/Q/Y
 *   :period_to    Kỳ tra cứu: Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * % so với kỳ trước = (kỳ này - kỳ trước) / kỳ trước * 100. Kỳ trước = 0 hoặc NULL -> NULL.
 * CHỈ TIÊU SỐ MÃ, KL, GT NIÊM YẾT/ĐKGD TÍNH ĐẾN KỲ TRA CỨU:
 *   CP, CCQ, ETF, CQ, TPDNNY: jad_stockinfor Lấy dữ liệu ngày mới nhất
 *   TPCP: Nguồn (snapshot tháng, danh sách TP chưa đáo hạn/hủy ĐKGD tính đến cuối tháng):
 *     - Chỉ lấy đúng các tháng của kỳ (đầu tháng >= đầu kỳ và <= cuối kỳ), không lùi sang tháng cũ hơn;
 *     - Lấy tháng mới nhất có dữ liệu trong kỳ, snapshot mới nhất của tháng
 *   TPDNRL: registration_status_change (lũy kế từ đầu năm). Số dư = HNX01 tháng 12 năm trước + ĐKGD mới lũy kế - Hủy ĐKGD lũy kế (tháng 12 có HNX01 -> dùng HNX01); GT = KL x par_value
 * CHỈ TIÊU NY/ĐKGD MỚI/BỔ SUNG, HỦY NY/ĐKGD:
 *   CP, CCQ, ETF, CQ, TPDNNY: listing_status_change (HNX + HOSE, snapshot mới nhất), kỳ theo effective_date; phân loại theo jad_stockinfor
 *   TPCP  : gov_bond_additional_listing, kỳ theo listing_change_date; Niêm yết mới / Niêm yết bổ sung / Đáo hạn (= hủy)
 *   TPDNRL: registration_status_change (lũy kế từ đầu năm -> phát sinh tháng = tháng này - tháng liền trước cùng năm, rồi cộng các tháng trong kỳ); Đăng ký giao dịch / Hủy đăng ký giao dịch
 */
WITH 
/* ===== A. THAM SỐ LỌC KỲ ===== */
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
/* ===== B. CỔ PHIẾU, CHỨNG CHỈ QUỸ, ETF, CHỨNG QUYỀN, TPDNNY: Tổng hợp theo loại chứng khoán + kỳ ===== */
-- 3.1. Dữ liệu cuối ngày của từng mã (Không lọc thời gian để lấy danh mục CK bên dưới)
, stock_eod AS (
  SELECT tradingdate, symbol, loai_ck, listedshare, par_value
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
      CAST(s.listedshare AS DECIMAL(38,2)) AS listedshare,
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
-- 3.2. Danh mục chứng khoán (thông tin không đổi) --> Lấy dữ liệu mới nhất
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
-- 4. TỔNG THEO LOẠI CHỨNG KHOÁN
---- 4.1. SỐ MÃ, KL, GT NY/ĐKGD TÍNH ĐẾN CUỐI KỲ TRA CỨU
, stock_cum AS (
  SELECT 
    period_tag,
    loai_ck,
    COUNT(symbol) AS so_ma_ny_dkgd,            -- Số lượng mã niêm yết/ĐKGD
    SUM(listedshare) AS kl_ny_dkgd,            -- KL niêm yết/ĐKGD
    SUM(listedshare * par_value) AS gt_ny_dkgd -- GT niêm yết/ĐKGD = KL x Mệnh giá
  FROM stock_eod s
  JOIN (
    -- LỌC DỮ LIỆU: Ngày giao dịch gần nhất <= ngày cuối kỳ này, kỳ trước
    SELECT p.period_tag, MAX(e.tradingdate) AS tradingdate
    FROM stock_eod e
    CROSS JOIN params p
    WHERE e.tradingdate <= p.period_enddate
    GROUP BY p.period_tag
  ) d ON s.tradingdate = d.tradingdate 
  GROUP BY period_tag, loai_ck
)
---- 4.2. TỔNG NY/ĐKGD MỚI/BỔ SUNG, HỦY NY/ĐKGD theo loại chứng khoán + kỳ
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
/* ===== C. TPCP ===== */
-- 5. TPCP: SỐ MÃ, KL, GT NY/ĐKGD TÍNH ĐẾN CUỐI KỲ TRA CỨU
, govbond_cum AS (
  SELECT 
    period_tag,
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
-- 6. TPCP: Dữ liệu phát sinh NY MỚI, NY BỔ SUNG, HỦY NY (kỳ theo listing_change_date)
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
/* ===== D. TPDNRL ===== */
/* Báo cáo nguồn registration_status_change là số LŨY KẾ TỪ ĐẦU NĂM đến cuối tháng báo cáo.
 * - Số dư ĐKGD cuối tháng M (năm Y) = Số dư HNX01 tháng 12 năm Y-1 + ĐKGD mới lũy kế (đầu năm -> M) - Hủy ĐKGD lũy kế (đầu năm -> M).
 *   Tháng 12 có HNX01 -> dùng luôn số HNX01. Không có HNX01 tháng 12 năm Y-1 -> NULL.
 * - Phát sinh trong kỳ: phát sinh từng tháng = lũy kế tháng này - lũy kế tháng liền trước cùng năm, sau đó cộng các tháng trong kỳ.
 * - GT = KL x par_value (mệnh giá lấy trực tiếp từ registration_status_change).
 * - Chưa tính loại 'Thay đổi đăng ký giao dịch (mua lại/hoán đổi)' (xem ghi chú ở tpdnrl_status_ytd).
 */
-- 7.0. TPDNRL: SỐ DƯ ĐKGD HNX01 TẠI THÁNG 12 CÁC NĂM (thời điểm cuối tháng) -> mốc khởi tạo cho năm sau
, tpdnrl_init AS (
  SELECT
    MAKE_DATE(CAST(report_year AS INT), 12, 1) AS init_month, -- Tháng 12 của năm làm mốc
    so_ma_dkgd_dauky, gt_dkgd_dauky
  FROM (
    SELECT
      report_year,
      SUM(CAST(IF(row_path = 'ĐĂNG KÝ GIAO DỊCH THỜI ĐIỂM CUỐI THÁNG - SỐ MÃ TPDN ĐĂNG KÝ GIAO DỊCH',   field_value, NULL) AS DECIMAL(38,12))) AS so_ma_dkgd_dauky,
      SUM(CAST(IF(row_path = 'ĐĂNG KÝ GIAO DỊCH THỜI ĐIỂM CUỐI THÁNG - GIÁ TRỊ TPDN ĐĂNG KÝ GIAO DỊCH', field_value, NULL) AS DECIMAL(38,12))) AS gt_dkgd_dauky
    FROM (
      -- Lấy snapshot date gần nhất
      SELECT f.report_year, f.report_month, f.row_num, f.column_path, f.row_path, f.field_value,
        DENSE_RANK() OVER(PARTITION BY f.report_year, f.report_month ORDER BY f.ds_snpst_dt DESC) AS snapshotdate_rk
      FROM uat_iss_ods.flat_report f
      WHERE f.report_code = 'HNX01'
        AND f.submit_source = 'ICP'
        AND f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
        AND f.row_path IN ('ĐĂNG KÝ GIAO DỊCH THỜI ĐIỂM CUỐI THÁNG - SỐ MÃ TPDN ĐĂNG KÝ GIAO DỊCH', 'ĐĂNG KÝ GIAO DỊCH THỜI ĐIỂM CUỐI THÁNG - GIÁ TRỊ TPDN ĐĂNG KÝ GIAO DỊCH')
        AND f.date_type = 'MONTHLY'
        AND CAST(f.report_month AS INT) = 12 -- Chỉ lấy báo cáo tháng 12 làm mốc khởi tạo
    ) t
    WHERE snapshotdate_rk = 1
    GROUP BY report_year
  ) i
)
-- 7.1. TPDNRL: Số LŨY KẾ từ đầu năm của ĐKGD mới / Hủy ĐKGD theo từng tháng báo cáo (snapshot mới nhất của tháng)
----  Ghi chú: loại 'Thay đổi đăng ký giao dịch (mua lại/hoán đổi)' chưa tính -> bổ sung thêm cột KL/GT giảm nếu cần trừ vào số dư
, tpdnrl_status_ytd AS (
  SELECT
    MAKE_DATE(CAST(report_year AS INT), CAST(report_month AS INT), 1) AS report_month_startdate, -- Ngày đầu tháng báo cáo
    COUNT(IF(st = 'Đăng ký giao dịch', bond_code, NULL)) AS moi_so_ma_ytd,
    NVL(SUM(IF(st = 'Đăng ký giao dịch', vol, 0)), 0) AS moi_kl_ytd,
    NVL(SUM(IF(st = 'Đăng ký giao dịch', vol * par_value, 0)), 0) AS moi_gt_ytd,
    COUNT(IF(st = 'Hủy đăng ký giao dịch', bond_code, NULL)) AS huy_so_ma_ytd,
    NVL(SUM(IF(st = 'Hủy đăng ký giao dịch', vol, 0)), 0) AS huy_kl_ytd,
    NVL(SUM(IF(st = 'Hủy đăng ký giao dịch', vol * par_value, 0)), 0) AS huy_gt_ytd
  FROM (
    SELECT report_year, report_month, bond_code,
      trading_registration_status AS st,
      currently_registered_trading_volume AS vol,
      par_value,
      DENSE_RANK() OVER(PARTITION BY report_year, report_month ORDER BY ds_snpst_dt DESC) AS rk
    FROM uat_hnx_stg.registration_status_change
  ) c
  WHERE c.rk = 1
  GROUP BY report_year, report_month
)
-- 7.2. TPDNRL: Số ĐKGD MỚI / HỦY ĐKGD của riêng từng tháng = lũy kế tháng này - lũy kế tháng liền trước cùng năm (tháng đầu: trừ 0)
, tpdnrl_status_monthly AS (
  SELECT
    report_month_startdate,
    moi_so_ma_ytd - COALESCE(LAG(moi_so_ma_ytd) OVER w, 0) AS moi_so_ma,
    moi_kl_ytd    - COALESCE(LAG(moi_kl_ytd)    OVER w, 0) AS moi_kl,
    huy_so_ma_ytd - COALESCE(LAG(huy_so_ma_ytd) OVER w, 0) AS huy_so_ma,
    huy_kl_ytd    - COALESCE(LAG(huy_kl_ytd)    OVER w, 0) AS huy_kl
  FROM tpdnrl_status_ytd
  WINDOW w AS (PARTITION BY YEAR(report_month_startdate) ORDER BY report_month_startdate)
)
-- 7.3. TPDNRL: Số dư ĐKGD cuối từng tháng
----  Tháng 12 có HNX01 -> dùng số HNX01; còn lại = HNX01 tháng 12 năm trước + ĐKGD mới lũy kế - Hủy ĐKGD lũy kế. KL: không có số dư khởi tạo -> NULL
, tpdnrl_stock_month AS (
  SELECT report_month_startdate, so_ma, kl, gt
  FROM (
    SELECT u.*, ROW_NUMBER() OVER(PARTITION BY report_month_startdate ORDER BY src_priority) AS rn
    FROM (
      SELECT init_month AS report_month_startdate, so_ma_dkgd_dauky AS so_ma, CAST(NULL AS DECIMAL(38,12)) AS kl, gt_dkgd_dauky AS gt, 1 AS src_priority
      FROM tpdnrl_init
      UNION ALL
      SELECT s.report_month_startdate,
        i.so_ma_dkgd_dauky + s.moi_so_ma_ytd - s.huy_so_ma_ytd AS so_ma,
        CAST(NULL AS DECIMAL(38,12)) AS kl,
        i.gt_dkgd_dauky + s.moi_gt_ytd - s.huy_gt_ytd AS gt,
        2 AS src_priority
      FROM tpdnrl_status_ytd s
      JOIN tpdnrl_init i ON i.init_month = MAKE_DATE(YEAR(s.report_month_startdate) - 1, 12, 1) -- Mốc: tháng 12 năm trước
    ) u
  ) t
  WHERE rn = 1
)
-- 7. TPDNRL: SỐ MÃ, KL, GT NY/ĐKGD TÍNH ĐẾN CUỐI KỲ TRA CỨU = số dư tháng mới nhất có dữ liệu trong kỳ (chỉ trong các tháng của kỳ, không lùi sang tháng cũ hơn)
, private_corpbond_cum AS (
  SELECT
    period_tag,
    'TPDNRL' AS loai_ck,
    CAST(so_ma AS BIGINT) AS so_ma_ny_dkgd,
    kl AS kl_ny_dkgd,
    gt AS gt_ny_dkgd
  FROM (
    SELECT
      p.period_tag, m.so_ma, m.kl, m.gt,
      ROW_NUMBER() OVER(PARTITION BY p.period_tag ORDER BY m.report_month_startdate DESC) AS rn
    FROM params p
    JOIN tpdnrl_stock_month m ON m.report_month_startdate BETWEEN TRUNC(p.period_startdate, 'MM') AND TRUNC(p.period_enddate, 'MM')
  ) t
  WHERE rn = 1
)
-- 8. TPDNRL: Dữ liệu phát sinh ĐKGD MỚI, HỦY ĐKGD của kỳ = Σ phát sinh riêng từng tháng báo cáo trong kỳ
, private_corpbond_agg AS (
  SELECT
    p.period_tag,
    'TPDNRL' AS loai_ck,
    NVL(SUM(m.moi_so_ma), 0) AS so_ma_ny_dkgd_moi,
    NVL(SUM(m.moi_kl), 0)    AS kl_ny_dkgd_moi_bosung,
    NVL(SUM(m.huy_so_ma), 0) AS so_ma_huy_ny_dkgd,
    NVL(SUM(m.huy_kl), 0)    AS kl_huy_ny_dkgd
  FROM tpdnrl_status_monthly m
  JOIN params p ON m.report_month_startdate BETWEEN TRUNC(p.period_startdate, 'MM') AND TRUNC(p.period_enddate, 'MM')
  GROUP BY p.period_tag
)
/* ===== E. TỔNG HỢP TẤT CẢ CHỈ TIÊU ===== */
---- Số mã, KL, GT NY/ĐKGD tính đến cuối kỳ tra cứu
, all_cum AS (
  SELECT * FROM stock_cum
  UNION ALL
  SELECT * FROM govbond_cum
  UNION ALL
  SELECT * FROM private_corpbond_cum
)
---- Phát sinh trong kỳ (NY/ĐKGD mới, bổ sung, Hủy NY/ĐKGD)
, all_agg AS (
  SELECT * FROM stock_agg
  UNION ALL
  SELECT * FROM govbond_agg
  UNION ALL
  SELECT * FROM private_corpbond_agg
)
-- TỔNG HỢP LÊN BIỂU ĐỒ: kỳ này + kỳ trước + % thay đổi
SELECT
  l.stt,
  l.loai_ck,
  -- Số mã, KL, GT NY/ĐKGD tính đến cuối kỳ tra cứu
  c1.so_ma_ny_dkgd,
  c1.kl_ny_dkgd,
  c1.gt_ny_dkgd,
  p1.so_ma_ny_dkgd AS so_ma_ny_dkgd_kytruoc,
  p1.kl_ny_dkgd    AS kl_ny_dkgd_kytruoc,
  p1.gt_ny_dkgd    AS gt_ny_dkgd_kytruoc,
  ROUND((c1.so_ma_ny_dkgd - p1.so_ma_ny_dkgd) / NULLIF(p1.so_ma_ny_dkgd, 0) * 100, 2) AS so_ma_ny_dkgd_pct,
  ROUND((c1.kl_ny_dkgd    - p1.kl_ny_dkgd)    / NULLIF(p1.kl_ny_dkgd, 0)    * 100, 2) AS kl_ny_dkgd_pct,
  ROUND((c1.gt_ny_dkgd    - p1.gt_ny_dkgd)    / NULLIF(p1.gt_ny_dkgd, 0)    * 100, 2) AS gt_ny_dkgd_pct,
  -- Phát sinh trong kỳ (NY/ĐKGD mới, bổ sung, Hủy NY/ĐKGD)
  c2.so_ma_ny_dkgd_moi, 
  p2.so_ma_ny_dkgd_moi AS so_ma_ny_dkgd_moi_kytruoc,
  (c2.so_ma_ny_dkgd_moi - p2.so_ma_ny_dkgd_moi) / NULLIF(p2.so_ma_ny_dkgd_moi, 0) * 100 AS so_ma_ny_dkgd_moi_sskytruoc_pct,
  c2.kl_ny_dkgd_moi_bosung, 
  p2.kl_ny_dkgd_moi_bosung AS kl_ny_dkgd_moi_bosung_kytruoc,
  (c2.kl_ny_dkgd_moi_bosung - p2.kl_ny_dkgd_moi_bosung) / NULLIF(p2.kl_ny_dkgd_moi_bosung, 0) * 100 AS kl_ny_dkgd_moi_bosung_sskytruoc_pct,
  c2.so_ma_huy_ny_dkgd, 
  p2.so_ma_huy_ny_dkgd AS so_ma_huy_ny_dkgd_kytruoc,
  (c2.so_ma_huy_ny_dkgd - p2.so_ma_huy_ny_dkgd) / NULLIF(p2.so_ma_huy_ny_dkgd, 0) * 100 AS so_ma_huy_ny_dkgd_sskytruoc_pct,
  c2.kl_huy_ny_dkgd, 
  p2.kl_huy_ny_dkgd AS kl_huy_ny_dkgd_kytruoc,
  (c2.kl_huy_ny_dkgd - p2.kl_huy_ny_dkgd) / NULLIF(p2.kl_huy_ny_dkgd, 0) * 100 AS kl_huy_ny_dkgd_sskytruoc_pct
FROM (SELECT POSEXPLODE(ARRAY('CP', 'CCQ', 'ETF', 'CQ', 'TPCP', 'TPDNNY', 'TPDNRL')) AS (stt, loai_ck)) l -- Danh sách loại chứng khoán 
-- Số mã, KL, GT NY/ĐKGD tính đến cuối kỳ tra cứu
LEFT JOIN all_cum c1 ON l.loai_ck = c1.loai_ck AND c1.period_tag = 'cur'  -- Số liệu kỳ này
LEFT JOIN all_cum p1 ON l.loai_ck = p1.loai_ck AND p1.period_tag = 'prev' -- Số liệu kỳ trước
-- Phát sinh trong kỳ (NY/ĐKGD mới, bổ sung, Hủy NY/ĐKGD)
LEFT JOIN all_agg c2 ON l.loai_ck = c2.loai_ck AND c2.period_tag = 'cur'  -- Số liệu kỳ này
LEFT JOIN all_agg p2 ON l.loai_ck = p2.loai_ck AND p2.period_tag = 'prev' -- Số liệu kỳ trước
ORDER BY l.stt
;