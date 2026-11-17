-- [08] THỐNG KÊ THỊ TRƯỜNG >> TPDNNY >> THỐNG KÊ THEO NGÀNH TẠI KỲ
/* Tham số tra cứu: 
 * Loại kỳ: D/M/Q/Y
 * Kỳ: Ngày yyyy-MM-dd, Tháng yyyy-MM, Quý yyyy-Q[1-4], Năm yyyy
 */
WITH
-- 1. Tham số tra cứu -> Ngày đầu kỳ 
params AS (
  SELECT 
    period_type,
    -- Kỳ này
    period_to, 
    period_to_startdate, -- Ngày đầu kỳ này
    CASE period_type
      WHEN 'D' THEN period_to_startdate
      WHEN 'M' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 1), 1)
      WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 3), 1)
      WHEN 'Y' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 12), 1)
    END AS period_to_enddate -- Ngày cuối kỳ này
  FROM (
    SELECT
      :period_type AS period_type, -- Loại kỳ
      :period_to AS period_to, -- Kỳ
      CAST(CASE :period_type
        WHEN 'D' THEN :period_to
        WHEN 'M' THEN CONCAT(:period_to, '-01')
        WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-',LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
        WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
      END AS DATE) AS period_to_startdate -- Ngày đầu kỳ này
  )
)
-- 2. Danh sách TP: Thông tin TPDN niêm yết Lấy bản ghi cuối ngày trong bảng stockinfor + Lấy thông tin ngành nghề từ IDS/SCMS/FMS
, stockinfor_daily AS (
  SELECT 
    CASE 
      WHEN sc.securities_code IS NOT NULL OR f.stock_code IS NOT NULL THEN '07000' -- CTCK/CTQLQ là CTĐC -> Mặc định ngành = 07000 (Tài chính ngân hàng)
      ELSE c.industry_cd
    END industry_cd,
    CASE 
      WHEN sc.securities_code IS NOT NULL OR f.stock_code IS NOT NULL 
        THEN (SELECT DISTINCT industry_name FROM uat_ids_stg.categories WHERE industry_cd = '07000' AND active_flg = '1' AND ds_snpst_dt = '2026-10-17')
      ELSE c.industry_name
    END industry_name,
    si.*
  FROM (
    SELECT 
      tradingdate, 
      symbol, 
      symbolisin,
      issuedate, 
      maturitydate, 
      reference, 
      listedshare,
      substr(symbol,1,3) AS tickercode, -- 3 ký tự đầu = mã cổ phiếu nếu TCPH đã niêm yết/đăng ký giao dịch
      -- Mệnh giá TPDN niêm yết: tính ngược từ giá tham chiếu theo nguyên tắc MG TP là bội số của 100000 và bước giá nhảy từ 100000 -> 1000000 -> 10000000 -> 100000000...
         --> Công thức: MG TP = 100000 * 10^ROUND(LOG10(Giá tham chiếu / 100000),0)
      100000 * POWER(10, ROUND(LN(NULLIF(reference, 0) / 100000) / LN(10))) AS parvalue,
      ROUND(MONTHS_BETWEEN(TO_DATE(maturitydate,'yyyyMMdd'), TO_DATE(issuedate,'yyyyMMdd')) / 12, 2) AS kyhanphathanh_nam
    FROM (
      SELECT
        s.tradingdate, s.symbol, s.symbolisin, s.issuedate, s.maturitydate, s.reference, s.listedshare,
        ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn
      FROM uat_mdds_stg.jad_stockinfor s
      CROSS JOIN params p
      WHERE s.stocktype = '1' -- Trái phiếu
        AND s.tradingdate BETWEEN p.period_to_startdate AND p.period_to_enddate
    ) WHERE rn = 1 -- Lấy bản ghi cuối mỗi ngày
  ) si
  -- Lấy thông tin ngành nghề kinh tế cấp 1 của mã TPDNNY theo phân ngành từ IDS
  LEFT JOIN (
    SELECT equity_ticker, category_l1_id, business_reg_no
    FROM (
      SELECT 
        equity_ticker, category_l1_id, business_reg_no, company_name_vn,
        ROW_NUMBER() OVER(PARTITION BY equity_ticker ORDER BY id) rn -- Lấy bản ghi cũ hơn (lọc dữ liệu test bị trùng)
      FROM uat_ids_stg.company_profiles 
      WHERE ds_snpst_dt = '2026-10-17' 
        AND delete_flg <> '1'
        AND (approval_status_cd <> 'REJECTED' OR approval_status_cd IS NULL) -- Không lấy trạng thái bị từ chối; Dữ liệu migration trạng thái NULL
    ) WHERE rn = 1
  ) cp ON si.tickercode = cp.equity_ticker -- Hồ sơ CTĐC
  LEFT JOIN (
    SELECT id, industry_cd, industry_name 
    FROM uat_ids_stg.categories 
    WHERE ds_snpst_dt = '2026-10-17'
  ) c ON cp.category_l1_id = c.id -- Mã/Tên ngành
  -- CTCK là CTĐC đã niêm yết/ĐKGD -> Xác định thuộc ngành Tài chính ngân hàng
  LEFT JOIN (
    SELECT securities_code, listing_exchange, code
    FROM uat_scms_stg.SC_FIRM_INFO 
    WHERE deleted = '0'
      AND securities_code IS NOT NULL 
      AND ds_snpst_dt = '2026-08-22'
  ) sc ON si.tickercode = sc.securities_code
  -- CTQLQ là CTĐC đã niêm yết/ĐKGD -> Xác định thuộc ngành Tài chính ngân hàng
  LEFT JOIN (
    SELECT stock_code, market, code 
    FROM uat_fms_stg.securities 
    WHERE deleted = 0
        AND stock_code IS NOT NULL
        AND ds_snpst_dt = '2026-10-21'
    ) f ON si.tickercode = f.stock_code 
)
-- Lấy ngày cuối cùng trong kỳ
, stockinfor_maxdate AS (
  SELECT 
    MAX(tradingdate) max_tradingdate
  FROM stockinfor_daily
)
-- Tổng GTGD TPDN niêm yết trong kỳ nhóm theo [ngành + kỳ hạn phát hành]
, trade_period AS (
  SELECT
    s.industry_cd, 
    s.industry_name,
    s.kyhanphathanh_nam,
    SUM(h.trade_quantity * h.trade_price) AS gtgd
  FROM uat_hnx_stg.trade_book h 
  LEFT JOIN stockinfor_daily s ON h.issue_code = s.symbolisin AND to_date(h.trade_date, 'yyyyMMdd') = s.tradingdate 
  CROSS JOIN params p
  WHERE h.market_id IN ('HCX') -- TPDN niêm yết
    AND h.trade_date BETWEEN DATE_FORMAT(p.period_to_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') -- Lọc trade_date kiểu string dạng yyyyMMdd
  GROUP BY s.industry_cd, s.industry_name, s.kyhanphathanh_nam
)
-- Tổng hợp số liệu thống kê theo ngành 
SELECT 
  COALESCE(ma_nganh, 'NA') AS ma_nganh,
  COALESCE(ten_nganh, 'Chưa phân ngành') AS ten_nganh,
  kyhanphathanh_nam,
  MAX(gtgd) AS gtgd, 
  MAX(so_ma_ny) AS so_ma_ny, 
  MAX(kl_luuhanh) AS kl_luuhanh, 
  MAX(duno) AS duno, 
  MAX(kyhanconlai_nam_bq) AS kyhanconlai_nam_bq
FROM (
  -- Tính các thông tin Số mã TP niêm yết, Kỳ hạn còn lại bình quân, KL TP lưu hành nhóm theo ngành và kỳ hạn phát hành
  SELECT 
    industry_cd AS ma_nganh,
    industry_name AS ten_nganh,
    kyhanphathanh_nam,
    NULL gtgd,
    COUNT(symbol) AS so_ma_ny,
    SUM(outstanding_shares) kl_luuhanh,
    SUM(duno) duno,
    ROUND(SUM(kyhanconlai_nam * duno) / NULLIF(SUM(duno), 0), 2) AS kyhanconlai_nam_bq
  FROM (
    SELECT 
      s.tradingdate,
      s.symbol,
      s.industry_cd, 
      s.industry_name,
      s.kyhanphathanh_nam,
      ls.outstanding_shares,
      (MONTHS_BETWEEN(TO_DATE(maturitydate,'yyyyMMdd'), TO_DATE(tradingdate,'dd/MM/yyyy')) / 12) AS kyhanconlai_nam, -- Không làm tròn
      ls.outstanding_shares * s.parvalue AS duno
    FROM stockinfor_daily s
    JOIN uat_hnx_stg.listed_securities_list ls ON s.tradingdate = MAKE_DATE(ls.report_year,ls.report_month,ls.report_day) AND s.symbol = ls.ticker_symbol -- Danh sách TP niêm yết 
    JOIN stockinfor_maxdate m ON s.tradingdate = m.max_tradingdate -- Dữ liệu tính tại ngày cuối cùng trong kỳ
  )
  GROUP BY industry_cd, industry_name, kyhanphathanh_nam
  UNION ALL
  -- Tổng GTGD trong kỳ
  SELECT 
    industry_cd AS ma_nganh,
    industry_name AS ten_nganh,
    kyhanphathanh_nam, 
    gtgd, 
    NULL so_ma_ny, NULL kl_luuhanh, NULL duno, NULL kyhanconlai_nam_bq
  FROM trade_period
) d
GROUP BY ma_nganh, ten_nganh, kyhanphathanh_nam
ORDER BY ma_nganh, kyhanphathanh_nam
;