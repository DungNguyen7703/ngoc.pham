-- [19] VỐN HÓA THỊ TRƯỜNG >> CHỈ TIÊU TỔNG HỢP
/* ==================================================================================
 * THAM SỐ TRA CỨU:
 *   :period_type  Loại kỳ: D (Ngày) | M (Tháng) | Q (Quý) | Y (Năm)
 *   :period_code  Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * ================================================================================== */
WITH
-- 1. XÁC ĐỊNH CÁC MỐC THỜI GIAN THEO THAM SỐ
params AS (
  SELECT
    q.period_type,
    q.period_code,
    q.period_start, -- Ngày đầu kỳ báo cáo
    q.period_end,   -- Ngày cuối kỳ báo cáo
    q.prev_start,   -- Ngày đầu kỳ trước
    DATE_SUB(q.period_start, 1) AS prev_end,                          -- Ngày cuối kỳ trước
    MAKE_DATE(YEAR(q.period_end) - 1, 12, 31)  AS py_end,             -- Ngày cuối năm trước
    YEAR(q.period_end) - 1 AS gdp_year_cur,                           -- Năm GDP cho kỳ báo cáo
    YEAR(DATE_SUB(q.period_start, 1)) - 1 AS gdp_year_prev,           -- Năm GDP cho kỳ trước
    YEAR(q.period_end) - 2 AS gdp_year_py                             -- Năm GDP cho cuối năm trước
  FROM (
    SELECT
      s.period_type,
      s.period_code,
      s.period_start,
      CASE s.period_type
        WHEN 'D' THEN s.period_start
        WHEN 'M' THEN LAST_DAY(s.period_start)
        WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(s.period_start, 2))
        WHEN 'Y' THEN LAST_DAY(ADD_MONTHS(s.period_start, 11))
      END AS period_end,
      CASE s.period_type
        WHEN 'D' THEN DATE_SUB(s.period_start, 1)
        WHEN 'M' THEN ADD_MONTHS(s.period_start, -1)
        WHEN 'Q' THEN ADD_MONTHS(s.period_start, -3)
        WHEN 'Y' THEN ADD_MONTHS(s.period_start, -12)
      END AS prev_start
    FROM (
      SELECT
        :period_type AS period_type,
        :period_code AS period_code,
        CASE :period_type
          WHEN 'D' THEN CAST(:period_code AS DATE)
          WHEN 'M' THEN CAST(CONCAT(:period_code, '-01') AS DATE)
          WHEN 'Q' THEN CAST(CONCAT(SUBSTR(:period_code, 1, 4), '-', LPAD(CAST((CAST(SUBSTR(:period_code, 7, 1) AS INT) - 1) * 3 + 1 AS STRING), 2, '0'), '-01') AS DATE)
          WHEN 'Y' THEN CAST(CONCAT(:period_code, '-01-01') AS DATE)
        END AS period_start
    ) s
  ) q
)
-- 2. XÁC ĐỊNH CÁC MỐC NGÀY GIAO DỊCH GẦN NHẤT VÀ NGÀY LIỀN SAU NGÀY CUỐI KỲ (T+1 để lấy VWAP tính vốn hóa UPCOM)
, key_dates AS (
  SELECT
    p.period_type,
    p.period_code,
    p.period_start,
    p.period_end,
    -- 2.1. Ngày giao dịch chốt kỳ (ngày gần nhất <= ngày kết thúc kỳ)
    MAX(CASE WHEN c.tradingdate <= p.period_end THEN c.tradingdate END) AS tradedate_cur,  -- Ngày GD cuối kỳ báo cáo
    MAX(CASE WHEN c.tradingdate <= p.prev_end   THEN c.tradingdate END) AS tradedate_prev, -- Ngày GD cuối kỳ trước
    MAX(CASE WHEN c.tradingdate <= p.py_end     THEN c.tradingdate END) AS tradedate_py,   -- Ngày GD cuối năm trước
    -- 2.2. Ngày giao dịch liền sau (chứa VWAP để tính vốn hóa UPCoM; nếu là phiên mới nhất thì NULL)
    MIN(CASE WHEN c.tradingdate > p.period_end THEN c.tradingdate END) AS t1_tradedate_cur,
    MIN(CASE WHEN c.tradingdate > p.prev_end   THEN c.tradingdate END) AS t1_tradedate_prev,
    MIN(CASE WHEN c.tradingdate > p.py_end     THEN c.tradingdate END) AS t1_tradedate_py
  FROM (
    -- LỊCH NGÀY GIAO DỊCH THỰC TẾ (Lấy từ sổ lệnh HNX và MDDS)
    SELECT DISTINCT TO_DATE(h.trade_date, 'yyyyMMdd') AS tradingdate
    FROM uat_hnx_stg.trade_book h
    CROSS JOIN params p
    WHERE h.trade_date >= DATE_FORMAT(ADD_MONTHS(p.py_end, -1), 'yyyyMMdd') AND h.trade_date <= DATE_FORMAT(ADD_MONTHS(p.period_end, 1), 'yyyyMMdd')
    UNION  
    SELECT DISTINCT m.tradingdate
    FROM uat_mdds_stg.jad_marketinfor m
    CROSS JOIN params p
    WHERE m.tradingdate >= ADD_MONTHS(p.py_end, -1) AND m.tradingdate <= ADD_MONTHS(p.period_end, 1)
  ) c
  CROSS JOIN params p -- Lọc theo ngày kết thúc kỳ này, kỳ trước, năm trước
  GROUP BY p.period_type, p.period_code, p.period_start, p.period_end, p.prev_end, p.py_end
)
-- 3. THÔNG TIN CỔ PHIẾU: DỮ LIỆU CUỐI NGÀY TẠI CÁC NGÀY CHỐT VÀ NGÀY LIỀN SAU
, stock_eod AS (
  SELECT s.tradingdate, s.symbol, s.floorcode, s.stocktype, s.closeprice, s.vwap, s.reference
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.floorcode, s.stocktype, s.closeprice, s.vwap, s.reference,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s
    CROSS JOIN key_dates kd
    WHERE s.tradingdate IN (kd.tradedate_cur, kd.t1_tradedate_cur, kd.tradedate_prev, kd.t1_tradedate_prev, kd.tradedate_py, kd.t1_tradedate_py)
      AND s.stocktype = '2' -- Cổ phiếu
  ) s
  WHERE s.rn = 1
)
-- 4. TÍNH VỐN HÓA THEO CỔ PHIẾU x SÀN GIAO DỊCH
, equity_data AS (
  SELECT
    x.*,
    os.outstanding_shares, -- KL lưu hành
    x.price * os.outstanding_shares AS marketcap
  FROM (
    SELECT
      t.period_tag,
      t.tradingdate,
      t.d_next,
      s.symbol,
      s.floorcode,
      -- Giá tính vốn hóa: Sàn UPCoM (04) lấy VWAP ngày T từ tín hiệu d Sở gửi ngày T+1 (n.vwap)
      CASE 
        WHEN s.floorcode = '04' THEN 
          (CASE 
            WHEN n.vwap IS NULL THEN NULL -- Chưa có T+1 -> chưa có VWAP
            ELSE COALESCE(NULLIF(n.vwap, 0), s.reference) -- VWAP=0 (mã trắng thanh khoản) thì lấy giá tham chiếu (reference) ngày T
          END)
        ELSE s.closeprice 
      END AS price
    FROM (
      SELECT 'CUR'  AS period_tag, tradedate_cur  AS tradedate, t1_tradedate_cur  AS t1_tradedate FROM key_dates -- Kỳ này
      UNION ALL
      SELECT 'PREV' AS period_tag, tradedate_prev AS tradedate, t1_tradedate_prev AS t1_tradedate FROM key_dates -- Kỳ trước
      UNION ALL
      SELECT 'PY'   AS period_tag, tradedate_py   AS tradedate, t1_tradedate_py   AS t1_tradedate FROM key_dates -- Năm trước
    ) t
    JOIN stock_eod s ON s.tradingdate = t.tradedate -- Lấy dữ liệu tại ngày giao dịch gần nhất <= ngày chốt kỳ
    LEFT JOIN stock_eod n ON n.symbol = s.symbol AND n.tradingdate = t.t1_tradedate -- Lấy dữ liệu tại ngày liền sau ngày chốt kỳ
  ) x
  LEFT JOIN uat_vsdc_stg.outstanding_shares os ON os.transaction_date = x.tradingdate AND os.ticker_symbol = x.symbol
)
-- 5. TỔNG HỢP VỐN HÓA THEO SÀN + TỔNG CÁC SÀN CỦA 3 MỐC THỜI GIAN
, equity_agg AS (
  SELECT floorcode, marketcap_cur, marketcap_prev, marketcap_py
  FROM (
    SELECT 
      e.period_tag,
      COALESCE(e.floorcode, 'TOTAL') AS floorcode,
      SUM(e.marketcap) AS marketcap 
    FROM equity_data e
    GROUP BY e.period_tag, e.floorcode GROUPING SETS ((e.period_tag, e.floorcode), (e.period_tag))
  )
  PIVOT (
    MAX(marketcap)
    FOR period_tag IN ('CUR' as marketcap_cur, 'PREV' as marketcap_prev, 'PY' as marketcap_py)
  )
)
-- 6. LẤY GDP NĂM THEO 3 MỐC THỜI GIAN CẦN TRA CỨU (kỳ này, kỳ trước, năm trước)
---- Quy tắc: Giá trị quy đổi về VND (3 = Tỷ, 8 = Đồng, 23 = Triệu); Ưu tiên Năm > Quý; Nếu lấy Quý thì phải có đủ 4 quý.
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
  WHERE rn = 1 
    AND (period_type = '4' OR (period_type = '3' AND sl_ky = 4)) -- Quý phải đủ 4 quý
)
-- 7. KẾT QUẢ: TÍNH TỶ LỆ VỐN HÓA / GDP VÀ SO SÁNH KỲ NÀY, KỲ TRƯỚC VÀ NĂM TRƯỚC
SELECT
  k.period_type,
  k.period_code,
  k.tradedate_cur,
  a.floorcode,
  MAP('02','HNX','04','UPCOM','10','HOSE','TOTAL','Tổng')[a.floorcode] exchange,
  -- Vốn hóa
  a.marketcap_cur, -- Vốn hóa kỳ này
  --a.marketcap_prev, -- Vốn hóa kỳ trước
  (a.marketcap_cur - a.marketcap_prev) / NULLIF(a.marketcap_prev, 0) * 100.0 AS marketcap_prev_pct, -- % so với kỳ trước
  --a.marketcap_py, -- Vốn hóa năm trước
  (a.marketcap_cur - a.marketcap_py) / NULLIF(a.marketcap_py, 0) * 100.0 AS marketcap_py_pct, -- % so với năm trước
  -- Tỷ lệ Vốn hóa / GDP (%) (Chỉ tính cho dòng TOTAL)
  CASE WHEN a.floorcode = 'TOTAL' THEN a.marketcap_cur / NULLIF(g.gdp_cur, 0) * 100.0 END AS marketcap_gdp_cur,
  CASE WHEN a.floorcode = 'TOTAL' THEN (a.marketcap_cur / NULLIF(g.gdp_cur, 0) * 100.0) - (a.marketcap_prev / NULLIF(g.gdp_prev, 0) * 100.0) END AS marketcap_gdp_prev_pct,
  CASE WHEN a.floorcode = 'TOTAL' THEN (a.marketcap_cur / NULLIF(g.gdp_cur, 0) * 100.0) - (a.marketcap_py / NULLIF(g.gdp_py, 0) * 100.0) END AS marketcap_gdp_py_pct
FROM equity_agg a
CROSS JOIN key_dates k
CROSS JOIN gdp_data g
ORDER BY a.floorcode
;