-- THỐNG KÊ THỊ TRƯỜNG >> CỔ PHIẾU >> CHỈ LẤY CỔ PHIẾU
/* Tham số tra cứu:
 * Sàn: HOSE / HNX / UPCOM / Toàn thị trường
 * Loại kỳ: D/M/Q/Y
 * Từ kỳ - Đến kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH 
-- Tham số tra cứu: Sàn, Loại kỳ, Từ kỳ, Đến kỳ >> Lấy ra [ngày bắt đầu - ngày kết thúc]
params AS (
  	SELECT
  		market_id, 
	  	period_type, 
		MAP('D','DAY','M','MONTH','Q','QUARTER','Y','YEAR')[period_type] AS period_unit, -- Đơn vị kỳ
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
			:market_id   AS market_id, -- Sàn
			:period_type AS period_type, -- Loại kỳ
			:period_from AS period_from, -- Từ kỳ
			:period_to 	 AS period_to  	 -- Đến kỳ
	)
)

----- Chỉ số index: Giá đóng cửa lấy bản ghi cuối mỗi ngày - Dữ liệu từ ngày đầu của "Từ kỳ" đến ngày cuối của "Đến kỳ"
, index_daily_filtered AS (
	SELECT exchangecode, marketcode, indexname, marketindex, tradingdate
	FROM (
	  	SELECT
			m.exchangecode,
			m.marketcode,
			m.indexname,
			m.marketindex,
			m.tradingdate,
			ROW_NUMBER() OVER(PARTITION BY m.marketcode, m.tradingdate ORDER BY m.indextime DESC, m.`sequence` DESC) AS rn_eod
	  	FROM uat_mdds_stg.jad_marketinfor m
	  	CROSS JOIN params p
	 	WHERE m.tradingdate BETWEEN p.period_from_startdate AND p.period_to_enddate
	    AND m.marketcode IN ('HOSE', 'HNX', 'UPCOM') -- Mã chỉ số của VN-Index, HNX-Index, UPCoM-Index
	) 
	WHERE rn_eod = 1
)
-- Chỉ số index theo kỳ: Lấy giá đóng cửa tại ngày cuối mỗi kỳ
, index_period AS (
	SELECT exchangecode, marketcode, indexname, marketindex, tradingdate, period_fromdate
	FROM (
		SELECT 
			i.exchangecode, i.marketcode, i.indexname, i.marketindex, i.tradingdate,
			CAST(DATE_TRUNC(p.period_unit, i.tradingdate) AS DATE) AS period_fromdate, -- Ngày đầu mỗi kỳ
			ROW_NUMBER() over(PARTITION BY i.marketcode, CAST(DATE_TRUNC(p.period_unit, i.tradingdate) AS DATE) ORDER BY i.tradingdate DESC) AS rn_eop -- rownum theo kỳ để lấy ngày cuối mỗi kỳ
		FROM index_daily_filtered i
		CROSS JOIN params p
	) 
	WHERE rn_eop = 1
)
-- Danh sách cổ phiếu: Lấy bản ghi cuối ngày 
, stock_daily_eod AS (
	SELECT tradingdate, symbol, symbolisin
	FROM (
  	SELECT 
  		s.tradingdate, 
  		s.symbol, 
  		s.symbolisin, 
  		ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn 
  	FROM uat_mdds_stg.jad_stockinfor s 
  	CROSS JOIN params p
  	WHERE s.tradingdate BETWEEN p.period_from_startdate AND p.period_to_enddate
  		AND s.stocktype = '2' -- Cổ phiếu
  ) 
  WHERE rn = 1
)
-- Giao dịch cổ phiếu của NĐTNN, Tự doanh
----- Tổng GTGD mua/bán theo ngày - Dữ liệu từ ngày đầu của "Từ kỳ" đến ngày cuối của "Đến kỳ"
, trade_daily AS (
	SELECT 
		market_id,
		trade_date,
		gtgd,
		ndtnn_mua_gt,
		ndtnn_ban_gt,
		ndtnn_mua_gt - ndtnn_ban_gt AS ndtnn_rong_gt,
		tudoanh_mua_gt,
		tudoanh_ban_gt,
		tudoanh_mua_gt - tudoanh_ban_gt AS tudoanh_rong_gt
	FROM (
	  	SELECT
		    t.market_id,
		    t.trade_date,
		    SUM(t.execution_value) AS gtgd,
		    SUM(CASE WHEN SUBSTR(t.buy_acct_no,4,1) IN ('E','F') THEN t.execution_value END) AS ndtnn_mua_gt,
		    SUM(CASE WHEN SUBSTR(t.sell_acct_no,4,1) IN ('E','F') THEN t.execution_value END) AS ndtnn_ban_gt,
		    SUM(CASE WHEN SUBSTR(t.buy_acct_no,4,1) IN ('P','E') THEN t.execution_value END) AS tudoanh_mua_gt,
		    SUM(CASE WHEN SUBSTR(t.sell_acct_no,4,1) IN ('P','E') THEN t.execution_value END) AS tudoanh_ban_gt
		FROM uat_hose_stg.trade_book t 
		JOIN stock_daily_eod s ON t.symbol = s.symbol AND t.trade_date = s.tradingdate
		CROSS JOIN params p
		WHERE t.market_id = 'STK'
			AND t.trade_date BETWEEN p.period_from_startdate AND p.period_to_enddate
		GROUP BY t.market_id, t.trade_date
		UNION ALL
		SELECT
	    	h.market_id,
		    TO_DATE(h.trade_date, 'yyyyMMdd') trade_date,
		    SUM(h.trade_quantity * h.trade_price) AS gtgd,
		    SUM(CASE WHEN SUBSTR(h.buy_account_number,4,1) IN ('E','F') THEN h.trade_quantity * h.trade_price END) AS ndtnn_mua_gt,
		    SUM(CASE WHEN SUBSTR(h.sell_account_number,4,1) IN ('E','F') THEN h.trade_quantity * h.trade_price END) AS ndtnn_ban_gt,
		    SUM(CASE WHEN SUBSTR(h.buy_account_number,4,1) IN ('P','E') THEN h.trade_quantity * h.trade_price END) AS tudoanh_mua_gt,
		    SUM(CASE WHEN SUBSTR(h.sell_account_number,4,1) IN ('P','E') THEN h.trade_quantity * h.trade_price END) AS tudoanh_ban_gt
		FROM uat_hnx_stg.trade_book h  
		JOIN stock_daily_eod s ON h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate
		CROSS JOIN params p
		WHERE h.market_id IN ('STX', 'UPX')
			AND h.trade_date BETWEEN DATE_FORMAT(p.period_from_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') -- Lọc trade_date kiểu string dạng yyyyMMdd
		GROUP BY h.market_id, h.trade_date
	)
)
-- Tổng GTGD theo kỳ, sàn
, trade_period AS ( 
	SELECT 
		h.market_id,
		CAST(DATE_TRUNC(p.period_unit, h.trade_date) AS DATE) AS period_fromdate, -- Ngày đầu mỗi kỳ
		SUM(ndtnn_rong_gt) AS ndtnn_rong_gt,
		SUM(tudoanh_rong_gt) AS tudoanh_rong_gt
	FROM trade_daily h
	CROSS JOIN params p
	GROUP BY h.market_id, CAST(DATE_TRUNC(p.period_unit, h.trade_date) AS DATE)
)
-- Dữ liệu dashboard >> Xoay chỉ tiêu index từ hàng thành cột để khi filter sàn sẽ để null chỉ số index của sàn không được chọn, khi chọn 'Toàn thị trường' thì hiển thị đủ cả 3 chỉ số
SELECT 
	period_fromdate, 
	CASE :period_type
		WHEN 'D' THEN date_format(period_fromdate, 'yyyy-MM-dd')
		WHEN 'M' THEN date_format(period_fromdate, 'yyyy-MM')
		WHEN 'Q' THEN CONCAT(CAST(year(period_fromdate) AS string), '-Q', CAST(CAST(FLOOR((month(period_fromdate) - 1) / 3) + 1 AS int) AS string))
    	WHEN 'Y' THEN CAST(YEAR(period_fromdate) AS string)
	END period_code, 
	MAX(vnindex) vnindex, 
	MAX(hnxindex) hnxindex, 
	MAX(upcomindex) upcomindex, 
	SUM(ndtnn_rong_gt) ndtnn_rong_gt, 
	SUM(tudoanh_rong_gt) tudoanh_rong_gt
FROM (
	SELECT period_fromdate, vnindex, hnxindex, upcomindex, 0 ndtnn_rong_gt, 0 tudoanh_rong_gt
	FROM (
		SELECT period_fromdate, marketcode, marketindex 
		FROM index_period ip
		WHERE ip.marketcode = :market_id OR :market_id = 'Toàn thị trường'
	) 
	PIVOT (
		MAX(marketindex) FOR marketcode IN ('HOSE' AS vnindex, 'HNX' AS hnxindex, 'UPCOM' AS upcomindex)
	)
	UNION ALL
	SELECT 
		tp.period_fromdate, 
		NULL vnindex, NULL hnxindex, NULL upcomindex,
		SUM(tp.ndtnn_rong_gt) AS ndtnn_rong_gt, 
		SUM(tp.tudoanh_rong_gt) AS tudoanh_rong_gt
	FROM trade_period tp
	WHERE :market_id = MAP('STX','HNX', 'UPX','UPCOM', 'STK','HOSE')[tp.market_id] OR :market_id = 'Toàn thị trường'
	GROUP BY tp.period_fromdate
) x
GROUP BY period_fromdate
;

-- Dữ liệu biểu đồ --> Cách lấy khác 
SELECT 
	p.market_id,
	CASE p.period_type
		WHEN 'D' THEN date_format(COALESCE(t.period_fromdate, i.period_fromdate), 'yyyy-MM-dd')
		WHEN 'M' THEN date_format(COALESCE(t.period_fromdate, i.period_fromdate), 'yyyy-MM')
		WHEN 'Q' THEN CONCAT(CAST(year(COALESCE(t.period_fromdate, i.period_fromdate)) AS string), '-Q', CAST(CAST(FLOOR((month(COALESCE(t.period_fromdate, i.period_fromdate)) - 1) / 3) + 1 AS int) AS string))
    WHEN 'Y' THEN CAST(year(COALESCE(t.period_fromdate, i.period_fromdate)) AS string)
	END period_code, 	
	COALESCE(t.period_fromdate, i.period_fromdate) AS period_fromdate,
	t.ndtnn_rong_gt, 
	t.tudoanh_rong_gt,
	i.vnindex, 
	i.hnxindex,
	i.upcomindex
FROM (
	SELECT 
		tp.period_fromdate, 
		SUM(tp.ndtnn_rong_gt) AS ndtnn_rong_gt, 
		SUM(tp.tudoanh_rong_gt) AS tudoanh_rong_gt
	FROM trade_period tp
	WHERE :market_id = MAP('STX','HNX', 'UPX','UPCOM', 'STK','HOSE')[tp.market_id] OR :market_id = 'Toàn thị trường'
	GROUP BY tp.period_fromdate
) t 
FULL OUTER JOIN (
	SELECT * 
	FROM (
		SELECT period_fromdate, marketcode, marketindex 
		FROM index_period ip
		WHERE ip.marketcode = :market_id OR :market_id = 'Toàn thị trường'
	)  
	PIVOT (
		MAX(marketindex) FOR marketcode IN ('HOSE' AS vnindex, 'HNX' AS hnxindex, 'UPCOM' AS upcomindex)
	)
) i ON t.period_fromdate = i.period_fromdate
CROSS JOIN params p
;