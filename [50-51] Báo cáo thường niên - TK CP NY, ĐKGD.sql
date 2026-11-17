-- 50-51. BÁO CÁO THƯỜNG NIÊN >> TK CỔ PHIẾU NY/ĐKGD MỚI/BỔ SUNG, HỦY NY/ĐKGD
---- Tham số: :fromyear - :toyear  Từ năm - Đến năm (yyyy)
WITH 
-- Lấy thông tin SÀN của mã chứng khoán + LỌC CỔ PHIẾU 
----> Thông tin chứng khoán cuối ngày
stock_eod AS (
  SELECT 
    tradingdate, symbol, floorcode, stocktype, 
    LEAD(tradingdate) OVER (PARTITION BY symbol ORDER BY tradingdate) AS next_tradingdate --> Lấy thông tin ngày giao dịch tiếp theo để dùng làm đk join
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.stocktype, s.floorcode, s.stocktype, 
      ROW_NUMBER() OVER (PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn -- Lọc bản ghi cuối ngày của từng mã chứng khoán
    FROM uat_mdds_stg.jad_stockinfor s
    WHERE stocktype = '2' --> Chỉ lấy Cổ phiếu
    --AND DATE_FORMAT(s.tradingdate, 'yyyy') BETWEEN :fromyear AND :toyear --> Lọc theo kỳ báo cáo sẽ bị thiếu do có mã hiệu lực hủy NY năm n nhưng bị loại khỏi danh sách gd từ năm n-1
  ) WHERE rn = 1
)
-- Tổng hợp dữ liệu CP NY/ĐKGD theo năm, sàn
, listing_year_metrics AS (
  SELECT 
    CAST(DATE_FORMAT(ls.effective_date, 'yyyy') AS INT) AS nam,
    MAP('02', 'HNX', '04', 'UPCOM', '10', 'HOSE')[IF(ls.new_listed_shares > 0, s_new.floorcode, s_add.floorcode)] san,
    COUNT(IF(ls.new_listed_shares > 0, ls.ticker_symbol, NULL)) AS sl_cp_ny_moi,
    SUM(ls.new_listed_shares) AS kl_cp_ny_landau,
    SUM(ls.additional_listed_shares) AS kl_cp_ny_bosung,
    COUNT(IF(ls.delisted_shares > 0, ls.ticker_symbol, NULL)) AS sl_cp_ny_huy,
    SUM(ls.delisted_shares) kl_cp_ny_huy
  FROM (
    -- HNX / UPCOM
    SELECT ticker_symbol, effective_date, first_trading_date, last_trading_date, new_listed_shares, additional_listed_shares, delisted_shares
    FROM uat_hnx_stg.listing_status_change a
    WHERE CAST(DATE_FORMAT(a.effective_date, 'yyyy') AS INT) BETWEEN :fromyear AND :toyear
      AND a.ds_snpst_dt IN (SELECT MAX(ds_snpst_dt) FROM uat_hnx_stg.listing_status_change) --snapshot date
    UNION ALL
    -- HOSE
    SELECT ticker_symbol, effective_date, first_trading_date, last_trading_date, new_listed_shares, additional_listed_shares, delisted_shares
    FROM uat_hose_stg.listing_status_change b
    WHERE CAST(DATE_FORMAT(b.effective_date, 'yyyy') AS INT) BETWEEN :fromyear AND :toyear
      AND b.ds_snpst_dt IN (SELECT MAX(ds_snpst_dt) FROM uat_hose_stg.listing_status_change) --snapshot date
  ) ls
  -- Lấy thông tin sàn từ stockinfor
  ----> NY/ĐKGD lần đầu: Tại ngày gd đầu tiên (> ngày hiệu lực) thì mới có trong stockinfor
  LEFT JOIN stock_eod s_new 
    ON ls.ticker_symbol = s_new.symbol 
    AND ls.first_trading_date = s_new.tradingdate 
  ----> NY/ĐKGD bổ sung, Hủy NY/ĐKGD: map dữ liệu ngày gd gần nhất với ngày hiệu lực
  LEFT JOIN stock_eod s_add 
    ON ls.ticker_symbol = s_add.symbol 
    AND ls.effective_date >= s_add.tradingdate AND (ls.effective_date < s_add.next_tradingdate OR s_add.next_tradingdate IS NULL) 
  WHERE s_new.stocktype = '2' OR s_add.stocktype = '2' -- Chỉ lấy CP
  GROUP BY 
    CAST(DATE_FORMAT(ls.effective_date, 'yyyy') AS INT),
    MAP('02', 'HNX', '04', 'UPCOM', '10', 'HOSE')[IF(ls.new_listed_shares > 0, s_new.floorcode, s_add.floorcode)]
)
-- Dữ liệu lên biểu đồ: Lấy đủ các kỳ trong khoảng thời gian [Từ năm, Đến năm]
, full_periods AS (
  SELECT
    y.nam,
    m.san,
    NVL(m.sl_cp_ny_moi, 0) AS sl_cp_ny_moi,
    NVL(m.kl_cp_ny_landau, 0) AS kl_cp_ny_landau,
    NVL(m.kl_cp_ny_bosung, 0) AS kl_cp_ny_bosung,
    NVL(m.kl_cp_ny_landau, 0) + NVL(m.kl_cp_ny_bosung, 0) AS kl_cp_ny_tong,
    NVL(m.sl_cp_ny_huy, 0) AS sl_cp_ny_huy,
    NVL(m.kl_cp_ny_huy, 0) AS kl_cp_ny_huy
  FROM (SELECT EXPLODE(SEQUENCE(CAST(:fromyear AS INT),CAST(:toyear AS INT))) AS nam) y -- Danh sách năm
  LEFT JOIN listing_year_metrics m ON m.nam = y.nam
  UNION ALL
  SELECT
    y.nam,
    'TOTAL' san,
    NVL(SUM(m.sl_cp_ny_moi), 0) AS sl_cp_ny_moi,
    NVL(SUM(m.kl_cp_ny_landau), 0) AS kl_cp_ny_landau,
    NVL(SUM(m.kl_cp_ny_bosung), 0) AS kl_cp_ny_bosung,
    NVL(SUM(m.kl_cp_ny_landau), 0) + NVL(SUM(m.kl_cp_ny_bosung), 0) AS kl_cp_ny_tong,
    NVL(SUM(m.sl_cp_ny_huy), 0) AS sl_cp_ny_huy,
    NVL(SUM(m.kl_cp_ny_huy), 0) AS kl_cp_ny_huy
  FROM (SELECT EXPLODE(SEQUENCE(CAST(:fromyear AS INT),CAST(:toyear AS INT))) AS nam) y -- Danh sách năm
  LEFT JOIN listing_year_metrics m ON m.nam = y.nam
  GROUP BY y.nam
)
--> Lọc dòng NULL của các kỳ không có số liệu, chỉ để lại dòng Tổng (TOTAL)
SELECT * 
FROM full_periods
WHERE san IS NOT NULL
ORDER BY nam, san
;

-----------------------------*******************************-----------------------------
-- 50. BÁO CÁO THƯỜNG NIÊN >> TK CỔ PHIẾU NIÊM YẾT MỚI
---- Tham số: :fromyear - :toyear  Từ năm - Đến năm (yyyy)
WITH 
-- Lấy thông tin "SÀN" của mã chứng khoán (chỉ cần với HNX/UPCOM)
----> Thông tin chứng khoán cuối ngày
stock_eod AS (
  SELECT 
    tradingdate, symbol, floorcode, stocktype, 
    LEAD(tradingdate) OVER (PARTITION BY symbol ORDER BY tradingdate) AS next_tradingdate --> Lấy thông tin ngày giao dịch tiếp theo để dùng làm đk join
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.stocktype, s.floorcode, s.stocktype, 
      ROW_NUMBER() OVER (PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn -- Lọc bản ghi cuối ngày của từng mã chứng khoán
    FROM uat_mdds_stg.jad_stockinfor s
    WHERE stocktype = '2' --> Chỉ lấy Cổ phiếu
    --AND DATE_FORMAT(s.tradingdate, 'yyyy') BETWEEN :fromyear AND :toyear --> Lọc theo kỳ báo cáo sẽ bị thiếu do có mã hiệu lực hủy NY năm n nhưng bị loại khỏi danh sách gd từ năm n-1
  ) WHERE rn = 1
)
-- Tổng hợp dữ liệu CP NY/ĐKGD theo năm, sàn
, listing_year_metrics AS (
  SELECT 
    CAST(DATE_FORMAT(ls.effective_date, 'yyyy') AS INT) AS nam,
    /*CASE (CASE WHEN ls.new_listed_shares > 0 THEN s_new.floorcode ELSE s_add.floorcode END)
      WHEN '02' THEN 'HNX'
      WHEN '04' THEN 'UPCOM' 
      WHEN '10' THEN 'HOSE'
    END san, */
    ELEMENT_AT(
      MAP('02', 'HNX', '04', 'UPCOM', '10', 'HOSE'),
      IF(ls.new_listed_shares > 0, s_new.floorcode, s_add.floorcode)
    ) san,
    COUNT(IF(ls.new_listed_shares > 0, ls.ticker_symbol, NULL)) AS sl_cp_ny_moi,
    SUM(ls.new_listed_shares) AS kl_cp_ny_landau,
    SUM(ls.additional_listed_shares) AS kl_cp_ny_bosung  
  FROM (
    -- HNX / UPCOM
    SELECT ticker_symbol, effective_date, first_trading_date, last_trading_date, new_listed_shares, additional_listed_shares, delisted_shares
    FROM uat_hnx_stg.listing_status_change a
    WHERE CAST(DATE_FORMAT(a.effective_date, 'yyyy') AS INT) BETWEEN :fromyear AND :toyear
      AND (NVL(a.new_listed_shares, 0) + NVL(a.additional_listed_value, 0)) > 0 -- Chỉ lấy NY/ĐKGD mới và bổ sung
      AND a.ds_snpst_dt IN (SELECT MAX(ds_snpst_dt) FROM uat_hnx_stg.listing_status_change) --snapshot date
    --GROUP BY CAST(DATE_FORMAT(a.effective_date, 'yyyy') AS INT), MAP('02','HNX','04','UPCOM')[s.floorcode]
    UNION ALL
    -- HOSE
    SELECT ticker_symbol, effective_date, first_trading_date, last_trading_date, new_listed_shares, additional_listed_shares, delisted_shares
    FROM uat_hose_stg.listing_status_change b
    WHERE DATE_FORMAT(b.effective_date, 'yyyy') BETWEEN :fromyear AND :toyear
      AND (NVL(b.new_listed_shares, 0) + NVL(b.additional_listed_value, 0)) > 0 -- Chỉ lấy NY/ĐKGD mới và bổ sung
      AND b.ds_snpst_dt IN (SELECT MAX(ds_snpst_dt) FROM uat_hose_stg.listing_status_change) --snapshot date
  ) ls
  LEFT JOIN stock_eod s_new 
    ON ls.ticker_symbol = s_new.symbol 
    AND ls.first_trading_date = s_new.tradingdate -- Với NY/ĐKGD lần đầu: Tại ngày gd đầu tiên (> ngày hiệu lực) thì mới có trong stockinfor
  LEFT JOIN stock_eod s_add 
    ON ls.ticker_symbol = s_add.symbol 
    AND ls.effective_date >= s_add.tradingdate AND (ls.effective_date < s_add.next_tradingdate OR s_add.next_tradingdate IS NULL) -- Với NY/ĐKGD bổ sung: map dữ liệu ngày gd gần nhất <= ngày hiệu lực
  WHERE s_new.stocktype = '2' OR s_add.stocktype = '2' -- Chỉ lấy CP
  GROUP BY 
    CAST(DATE_FORMAT(ls.effective_date, 'yyyy') AS INT),
    ELEMENT_AT(
      MAP('02', 'HNX', '04', 'UPCOM', '10', 'HOSE'),
      IF(ls.new_listed_shares > 0, s_new.floorcode, s_add.floorcode)
    )
)
-- Dữ liệu lên biểu đồ: Lấy đủ các kỳ trong khoảng thời gian [Từ năm, Đến năm]
, full_periods AS (
  SELECT
    y.nam,
    m.san,
    NVL(m.sl_cp_ny_moi, 0) AS sl_cp_ny_moi,
    NVL(m.kl_cp_ny_landau, 0) AS kl_cp_ny_landau,
    NVL(m.kl_cp_ny_bosung, 0) AS kl_cp_ny_bosung
  FROM (SELECT EXPLODE(SEQUENCE(CAST(:fromyear AS INT),CAST(:toyear AS INT))) AS nam) y -- Danh sách năm
  LEFT JOIN listing_year_metrics m ON m.nam = y.nam
  UNION ALL
  SELECT
    y.nam,
    'TOTAL' san,
    NVL(SUM(m.sl_cp_ny_moi), 0) AS sl_cp_ny_moi,
    NVL(SUM(m.kl_cp_ny_landau), 0) AS kl_cp_ny_landau,
    NVL(SUM(m.kl_cp_ny_bosung), 0) AS kl_cp_ny_bosung
  FROM (SELECT EXPLODE(SEQUENCE(CAST(:fromyear AS INT),CAST(:toyear AS INT))) AS nam) y -- Danh sách năm
  LEFT JOIN listing_year_metrics m ON m.nam = y.nam
  GROUP BY y.nam
)
--> Lọc dòng NULL của các kỳ không có số liệu, chỉ để lại dòng Tổng (TOTAL)
SELECT * 
FROM full_periods
WHERE san IS NOT NULL
ORDER BY nam, san
;