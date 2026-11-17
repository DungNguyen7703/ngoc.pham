-- 36. HOẠT ĐỘNG NĐTNN >> MUA BÁN RÒNG >> GIÁ TRỊ MUA/BÁN RÒNG NĐTNN - CỔ PHIẾU
/* Tham số tra cứu:
 * Loại kỳ: D/M/Q/Y
 * Từ kỳ - Đến kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH 
-- Tham số tra cứu: Sàn, Loại kỳ, Từ kỳ, Đến kỳ >> Lấy ra [ngày bắt đầu - ngày kết thúc]
params AS (
  SELECT
    period_type, 
    -- Ngày đầu của "Từ kỳ"
    CAST(CASE :period_type
      WHEN 'D' THEN :period_from
      WHEN 'M' THEN CONCAT(:period_from, '-01')
      WHEN 'Q' THEN CONCAT(SUBSTR(:period_from, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_from, 7, 1) AS int) * 3 - 2 AS string), 2, '0'), '-01')
      WHEN 'Y' THEN CONCAT(:period_from, '-01-01')
    END AS date) AS period_from_startdate,
    --Ngày cuối của "Đến kỳ"
    CAST(CASE :period_type
      WHEN 'D' THEN :period_to
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01'), 'yyyy-MM-dd'))
      WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01'), 'yyyy-MM-dd'), CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3),1)
      WHEN 'Y' THEN CONCAT(:period_to, '-12-31')
    END AS date) AS period_to_enddate
    FROM ( 
    SELECT -- Danh sách tham số tra cứu
      :period_type AS period_type, -- Loại kỳ
      :period_from AS period_from, -- Từ kỳ
      :period_to   AS period_to -- Đến kỳ
  )
)
-- Danh sách cổ phiếu: Lấy bản ghi cuối ngày -> Lấy danh sách cổ phiếu (chỉ cần bản ghi mới nhất để lọc điều kiện loại chứng khoán = Cổ phiếu)
, stock_portfolio AS (
  SELECT symbol, symbolisin, stocktype
  FROM (
    SELECT 
      s.tradingdate, 
      s.symbol, 
      s.symbolisin, 
      ROW_NUMBER() OVER(PARTITION BY s.symbol ORDER BY s.tradingdate DESC, s.tradingtime DESC, s.`sequence` DESC) rn 
    FROM uat_mdds_stg.jad_stockinfor s 
    CROSS JOIN params p
    WHERE s.tradingdate BETWEEN p.period_from_startdate AND p.period_to_enddate
      AND s.stocktype = '2' -- Cổ phiếu
  ) 
  WHERE rn = 1
)
-- Tổng GTGD Cổ phiếu theo kỳ
SELECT 
  loaiky, 
  ky,
  SUM(ndtnn_mua_gt) AS ndtnn_mua_gt,
  SUM(ndtnn_ban_gt) AS ndtnn_ban_gt
FROM (
  SELECT 
    :period_type loaiky,
    CASE :period_type
      WHEN 'D' THEN date_format(trade_date, 'yyyy-MM-dd')
      WHEN 'M' THEN date_format(trade_date, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(CAST(year(trade_date) AS string), '-Q', CAST(CAST(FLOOR((month(period_fromdate) - 1) / 3) + 1 AS int) AS string))
      WHEN 'Y' THEN CAST(YEAR(trade_date) AS string)
    END ky,
    ndtnn_mua_gt,
    ndtnn_ban_gt
  FROM (
    -- Tổng GTGD theo ngày - Dữ liệu từ ngày đầu của "Từ kỳ" đến ngày cuối của "Đến kỳ"
    SELECT
      t.trade_date,
      SUM(CASE WHEN SUBSTR(t.buy_acct_no,4,1) IN ('E','F') THEN t.execution_value END) AS ndtnn_mua_gt,
      SUM(CASE WHEN SUBSTR(t.sell_acct_no,4,1) IN ('E','F') THEN t.execution_value END) AS ndtnn_ban_gt
    FROM uat_hose_stg.trade_book t
    JOIN stock_portfolio s ON t.symbol = s.symbol
    CROSS JOIN params p
    WHERE t.market_id = 'STK'
      AND t.trade_date BETWEEN p.period_from_startdate AND p.period_to_enddate
    GROUP BY t.trade_date
    UNION ALL
    SELECT
      TO_DATE(h.trade_date, 'yyyyMMdd') trade_date,
      SUM(CASE WHEN SUBSTR(h.buy_account_number,4,1) IN ('E','F') THEN h.trade_quantity * h.trade_price END) AS ndtnn_mua_gt,
      SUM(CASE WHEN SUBSTR(h.sell_account_number,4,1) IN ('E','F') THEN h.trade_quantity * h.trade_price END) AS ndtnn_ban_gt
    FROM uat_hnx_stg.trade_book h 
    JOIN stock_portfolio s ON h.issue_code = s.symbolisin
    CROSS JOIN params p
    WHERE h.market_id IN ('STX', 'UPX') 
      AND h.trade_date BETWEEN DATE_FORMAT(p.period_from_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') -- Lọc trade_date kiểu string dạng yyyyMMdd
    GROUP BY h.trade_date
  ) 
)
GROUP BY loaiky, ky
ORDER BY ky
;