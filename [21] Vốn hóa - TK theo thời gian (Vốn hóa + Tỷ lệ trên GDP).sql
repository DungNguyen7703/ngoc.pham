-- [21] VỐN HÓA THỊ TRƯỜNG - TK THEO THỜI GIAN (TỪNG SÀN (HOSE, HNX, UPCOM) VÀ TỶ LỆ VỐN HÓA / GDP)
/* ==================================================================================
 * THAM SỐ TRA CỨU:
 *   :period_type  Loại kỳ: D (Ngày) | M (Tháng) | Q (Quý) | Y (Năm)
 *   :period_from, :period_to  Từ kỳ, Đến kỳ:  Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 * QUY TẮC:
 *   - Vốn hóa tính tại ngày giao dịch gần nhất <= ngày cuối kỳ (kỳ D: chỉ lấy các ngày có giao dịch).
 *   - HOSE, HNX: giá đóng cửa. UPCoM: VWAP ngày T lấy từ tín hiệu Sở gửi ngày T+1; VWAP = 0 -> lấy giá tham chiếu ngày T; chưa có T+1 (phiên mới nhất) -> vốn hóa UPCoM NULL
 *   - Tỷ lệ vốn hóa/GDP (%) = Vốn hóa cuối kỳ / GDP năm
 * ================================================================================== */
WITH
/* ===== THAM SỐ ===== */
-- 1. DANH SÁCH CÁC KỲ TRONG KHOẢNG [TỪ KỲ, ĐẾN KỲ]
bounds AS (
  SELECT
    :period_type AS period_type,
    CASE :period_type
      WHEN 'D' THEN CAST(:period_from AS DATE)
      WHEN 'M' THEN CAST(CONCAT(:period_from, '-01') AS DATE)
      WHEN 'Q' THEN CAST(CONCAT(SUBSTR(:period_from, 1, 4), '-', LPAD(CAST((CAST(SUBSTR(:period_from, 7, 1) AS INT) - 1) * 3 + 1 AS STRING), 2, '0'), '-01') AS DATE)
      WHEN 'Y' THEN CAST(CONCAT(:period_from, '-01-01') AS DATE)
    END AS from_start,
    CASE :period_type
      WHEN 'D' THEN CAST(:period_to AS DATE)
      WHEN 'M' THEN CAST(CONCAT(:period_to, '-01') AS DATE)
      WHEN 'Q' THEN CAST(CONCAT(SUBSTR(:period_to, 1, 4), '-', LPAD(CAST((CAST(SUBSTR(:period_to, 7, 1) AS INT) - 1) * 3 + 1 AS STRING), 2, '0'), '-01') AS DATE)
      WHEN 'Y' THEN CAST(CONCAT(:period_to, '-01-01') AS DATE)
    END AS to_start
)
, periods AS (
  SELECT
    p.period_type,
    p.period_start,
    CASE p.period_type
      WHEN 'D' THEN p.period_start
      WHEN 'M' THEN LAST_DAY(p.period_start)
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(p.period_start, 2))
      WHEN 'Y' THEN LAST_DAY(ADD_MONTHS(p.period_start, 11))
    END AS period_end,
    CASE p.period_type
      WHEN 'D' THEN DATE_FORMAT(p.period_start, 'yyyy-MM-dd')
      WHEN 'M' THEN DATE_FORMAT(p.period_start, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(p.period_start), '-Q', QUARTER(p.period_start))
      WHEN 'Y' THEN CAST(YEAR(p.period_start) AS STRING)
    END AS period_code
  FROM (
    SELECT
      b.period_type,
      CASE b.period_type
        WHEN 'D' THEN DATE_ADD(b.from_start, i)
        ELSE ADD_MONTHS(b.from_start, i * MAP('M',1,'Q',3,'Y',12)[b.period_type])
      END AS period_start
    FROM bounds b
    LATERAL VIEW EXPLODE(SEQUENCE(0, CASE b.period_type
      WHEN 'D' THEN DATEDIFF(b.to_start, b.from_start)
      ELSE CAST(MONTHS_BETWEEN(b.to_start, b.from_start) AS INT) DIV MAP('M',1,'Q',3,'Y',12)[b.period_type]
    END)) t AS i
  ) p
)
-- 2. LỊCH NGÀY GIAO DỊCH THỰC TẾ (HNX trade_book + MDDS), lấy dư 1 tháng 2 đầu để tìm ngày chốt và ngày T+1
, cal AS (
  SELECT DISTINCT TO_DATE(h.trade_date, 'yyyyMMdd') AS tradingdate
  FROM uat_hnx_stg.trade_book h
  CROSS JOIN (SELECT MIN(period_start) AS d_min, MAX(period_end) AS d_max FROM periods) r
  WHERE h.trade_date >= DATE_FORMAT(ADD_MONTHS(r.d_min, -1), 'yyyyMMdd')  AND h.trade_date <= DATE_FORMAT(ADD_MONTHS(r.d_max, 1), 'yyyyMMdd')
  UNION
  SELECT DISTINCT m.tradingdate
  FROM uat_mdds_stg.jad_marketinfor m
  CROSS JOIN (SELECT MIN(period_start) AS d_min, MAX(period_end) AS d_max FROM periods) r
  WHERE m.tradingdate >= ADD_MONTHS(r.d_min, -1) AND m.tradingdate <= ADD_MONTHS(r.d_max, 1)
)
-- 3. NGÀY GIAO DỊCH CHỐT KỲ (tradedate) VÀ NGÀY GIAO DỊCH LIỀN SAU (t1_tradedate: chứa VWAP tính vốn hóa UPCoM)
, key_dates AS (
  SELECT
    p.period_type, p.period_code, p.period_start, p.period_end,
    MAX(CASE WHEN c.tradingdate <= p.period_end THEN c.tradingdate END) AS tradedate,
    MIN(CASE WHEN c.tradingdate >  p.period_end THEN c.tradingdate END) AS t1_tradedate,
    YEAR(p.period_end) - 1 AS gdp_year -- Năm GDP áp dụng cho kỳ
  FROM periods p
  CROSS JOIN cal c
  GROUP BY p.period_type, p.period_code, p.period_start, p.period_end
  HAVING p.period_type <> 'D' OR MAX(CASE WHEN c.tradingdate = p.period_end THEN 1 END) = 1 -- Kỳ ngày: chỉ lấy ngày giao dịch
)
-- 4. THÔNG TIN CỔ PHIẾU CUỐI NGÀY TẠI NGÀY GIAO DỊCH CHỐT KỲ VÀ NGÀY GIAO DỊCH LIỀN SAU
, stock_eod AS (
  SELECT tradingdate, symbol, floorcode, closeprice, vwap, reference
  FROM (
    SELECT
      s.tradingdate, s.symbol, s.floorcode, s.closeprice, s.vwap, s.reference,
      ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
    FROM uat_mdds_stg.jad_stockinfor s
    JOIN (
      SELECT tradedate FROM key_dates WHERE tradedate IS NOT NULL
      UNION
      SELECT t1_tradedate AS d FROM key_dates WHERE t1_tradedate IS NOT NULL
    ) d ON s.tradingdate = d.tradedate
    WHERE s.stocktype = '2' -- Cổ phiếu
  ) WHERE rn = 1
)
-- 5. VỐN HÓA THEO CỔ PHIẾU x KỲ
, equity_data AS (
  SELECT
    x.*,
    os.outstanding_shares,
    x.price * os.outstanding_shares AS marketcap
  FROM (
    SELECT
      k.period_type, k.period_code, k.period_start, k.period_end, k.tradedate, k.gdp_year,
      s.symbol, s.floorcode,
      CASE
        WHEN s.floorcode = '04' THEN
          (CASE WHEN n.vwap IS NULL THEN NULL                         -- Chưa có T+1 -> chưa có VWAP
                ELSE COALESCE(NULLIF(n.vwap, 0), s.reference) END)    -- VWAP = 0 -> giá tham chiếu ngày T
        ELSE s.closeprice
      END AS price
    FROM key_dates k
    JOIN stock_eod s ON s.tradingdate = k.tradedate
    LEFT JOIN stock_eod n ON n.symbol = s.symbol AND n.tradingdate = k.t1_tradedate
  ) x
  LEFT JOIN uat_vsdc_stg.outstanding_shares os ON os.transaction_date = x.tradedate AND os.ticker_symbol = x.symbol
)
-- 6. TỔNG HỢP VỐN HÓA THEO SÀN + TỔNG
, equity_agg AS (
  SELECT
    e.period_type, e.period_code, e.period_start, e.period_end, e.tradedate, e.gdp_year,
    COALESCE(e.floorcode, 'TOTAL') AS floorcode,
    SUM(e.marketcap) AS marketcap
  FROM equity_data e
  GROUP BY GROUPING SETS (
    (e.period_type, e.period_code, e.period_start, e.period_end, e.tradedate, e.gdp_year, e.floorcode), /*Vốn hóa theo sàn*/
    (e.period_type, e.period_code, e.period_start, e.period_end, e.tradedate, e.gdp_year) /*Vốn hóa tổng các sàn*/
  )
)
-- 7. GDP NĂM theo các năm cần dùng (quy đổi VND: 3 = Tỷ, 8 = Đồng, 23 = Triệu; Ưu tiên Năm > Quý, lấy Quý phải đủ 4 quý)
, gdp_data AS (
  SELECT period_year, gdp_val AS gdp
  FROM (
    SELECT
      v.period_year, v.period_type,
      SUM(CAST(v.value AS DOUBLE) * MAP('3', 1e9, '8', 1, '23', 1e6)[v.unit_code]) AS gdp_val,
      COUNT(1) AS sl_ky,
      ROW_NUMBER() OVER(PARTITION BY v.period_year ORDER BY v.period_type DESC) AS rn
    FROM uat_mrms_stg.risk_indicator_value v
    LEFT JOIN uat_mrms_stg.risk_indicator i ON i.id = v.indicator_id
    WHERE i.indicator_code = 'GDP_VN'
      AND v.period_type IN ('3', '4') -- 4: Năm, 3: Quý
      AND v.period_year IN (SELECT DISTINCT gdp_year FROM key_dates)
      AND v.deleted = '0'
      AND v.ds_snpst_dt = '2026-10-23'
      AND i.ds_snpst_dt = '2026-10-23'
    GROUP BY v.period_year, v.period_type
  ) t
  WHERE rn = 1 AND (period_type = '4' OR (period_type = '3' AND sl_ky = 4))
)
-- 8. KẾT QUẢ
SELECT
  a.period_type,
  a.period_code,
  a.period_end,
  a.tradedate, -- Ngày giao dịch chốt vốn hóa
  a.floorcode,
  MAP('02', 'HNX', '04', 'UPCOM', '10', 'HOSE', 'TOTAL', 'Tổng')[a.floorcode] AS exchange,
  a.marketcap,                                                       -- Vốn hóa cuối kỳ (VND)
  a.marketcap / 1e9 AS marketcap_ty_dong,                            -- Vốn hóa cuối kỳ (tỷ VND)
  a.gdp_year,
  g.gdp,                                                             -- GDP năm áp dụng (VND)
  a.marketcap / NULLIF(g.gdp, 0) * 100.0 AS marketcap_gdp_pct        -- Tỷ lệ vốn hóa/GDP (%)
FROM equity_agg a
LEFT JOIN gdp_data g ON g.period_year = a.gdp_year
ORDER BY a.period_start, MAP('10',1,'02',2,'04',3,'TOTAL',4)[a.floorcode]
;