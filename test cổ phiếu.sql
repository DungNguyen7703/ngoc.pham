-- THỐNG KÊ THỊ TRƯỜNG >> CỔ PHIẾU
WITH 
-- Tham số tra cứu: Sàn, Loại kỳ, Từ kỳ, Đến kỳ
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
			:market_id   AS market_id, -- Sàn: HOSE / HNX / UPCOM / Toàn thị trường
			:period_type AS period_type, -- Loại kỳ: D/M/Q/Y
			:period_from AS period_from, -- Từ kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
			:period_to 	 AS period_to  	 -- Đến kỳ
	)
)
-- Chỉ số index
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
	SELECT tradingdate, symbol, symbolisin, floorcode, stocktype, fundtype 
	FROM (
  	SELECT 
  		s.tradingdate, 
  		s.symbol, 
  		s.symbolisin, 
  		s.floorcode, 
  		s.stocktype,
  		s.fundtype,
  		ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn 
  	FROM uat_mdds_stg.jad_stockinfor s 
  	CROSS JOIN params p
  	WHERE s.tradingdate BETWEEN p.period_from_startdate AND p.period_to_enddate
  		--AND s.stocktype = '4' -- Cổ phiếu
  ) 
  WHERE rn = 1
)
-- Giao dịch cổ phiếu của NĐTNN, Tự doanh
----- Tổng GTGD mua/bán theo ngày - Dữ liệu từ ngày đầu của "Từ kỳ" đến ngày cuối của "Đến kỳ"
, trade_daily AS (
	SELECT 
		market_id,
		trade_date,
		--board_type,
		floorcode, stocktype, fundtype,
		CASE 
			WHEN stocktype = '1' THEN 'TPDNNY'
			WHEN stocktype = '2' THEN 'Cổ phiếu'
			WHEN stocktype = '3' AND fundtype = 'E' THEN 'Chứng chỉ quỹ ETF'
			WHEN stocktype = '3' AND fundtype = 'M' THEN 'Chứng chỉ quỹ'
			WHEN stocktype = '6' THEN 'CCQ ETF'
			WHEN floorcode = '03' AND stocktype = '4' THEN 'Phái sinh - HĐTL'
			WHEN floorcode = '03' AND stocktype = '5' THEN 'Phái sinh - HĐQC'
			WHEN floorcode = '10' AND stocktype = '4' THEN 'Chứng quyền'
		END loai_chungkhoan,
		klgd,
		gtgd,
		ndtnn_mua_gt,
		ndtnn_ban_gt,
		ndtnn_mua_gt - ndtnn_ban_gt AS ndtnn_rong_gt,
		tudoanh_mua_gt,
		tudoanh_ban_gt,
		tudoanh_mua_gt - tudoanh_ban_gt AS tudoanh_rong_gt
	FROM (
	  	SELECT
		    h.market_id,
		    h.trade_date,
		    --h.board_type,
		    s.floorcode, s.stocktype, s.fundtype,
		    SUM(h.execution_volume) AS klgd,
		    SUM(h.execution_value) AS gtgd,
		    SUM(CASE WHEN SUBSTR(h.buy_acct_no,4,1) IN ('E','F') THEN h.execution_value END) AS ndtnn_mua_gt,
		    SUM(CASE WHEN SUBSTR(h.sell_acct_no,4,1) IN ('E','F') THEN h.execution_value END) AS ndtnn_ban_gt,
		    SUM(CASE WHEN SUBSTR(h.buy_acct_no,4,1) IN ('P','E') THEN h.execution_value END) AS tudoanh_mua_gt,
		    SUM(CASE WHEN SUBSTR(h.sell_acct_no,4,1) IN ('P','E') THEN h.execution_value END) AS tudoanh_ban_gt
		FROM uat_hose_stg.trade_book h
		JOIN stock_daily_eod s ON h.symbol = s.symbol AND h.trade_date = s.tradingdate
		CROSS JOIN params p
		WHERE h.market_id = 'STK'
			AND h.trade_date BETWEEN p.period_from_startdate AND p.period_to_enddate
		GROUP BY h.market_id, h.trade_date, s.floorcode, s.stocktype, s.fundtype--, h.board_type
		UNION ALL
		SELECT
	    	h.market_id,
		    TO_DATE(h.trade_date, 'yyyyMMdd') trade_date,
		    --h.board_id,
		    s.floorcode, s.stocktype, s.fundtype,
		    SUM(h.trade_quantity) AS klgd,
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
		GROUP BY h.market_id, h.trade_date, s.floorcode, s.stocktype, s.fundtype--, h.board_id
	)
)
SELECT * FROM trade_daily;