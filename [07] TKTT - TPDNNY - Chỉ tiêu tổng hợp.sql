-- THỐNG KÊ THỊ TRƯỜNG >> TPDNNY >> CHỈ TIÊU TỔNG HỢP: TÍNH TẠI 1 KỲ
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
	    END AS period_to_enddate, -- Ngày cuối kỳ này
	    -- Kỳ trước
	    CASE period_type
	        WHEN 'D' THEN DATE_SUB(period_to_startdate, 1)
	        WHEN 'M' THEN ADD_MONTHS(period_to_startdate, -1)
	        WHEN 'Q' THEN ADD_MONTHS(period_to_startdate, -3)
	        WHEN 'Y' THEN ADD_MONTHS(period_to_startdate, -12)
	    END AS period_prev_startdate
		FROM (
	  		SELECT
				:period_type AS period_type, -- Loại kỳ: D/M/Q/Y
				:period_to AS period_to, -- Kỳ: Ngày yyyy-MM-dd, Tháng yyyy-MM, Quý yyyy-Q[1-4], Năm yyyy
				CAST(CASE :period_type
					WHEN 'D' THEN :period_to
					WHEN 'M' THEN CONCAT(:period_to, '-01')
					WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-',LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
					WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
			    END AS DATE) AS period_to_startdate -- Ngày đầu kỳ này
		)
)
-- 2. Thông tin kỳ này, kỳ trước
, periods AS (
	SELECT -- Kỳ này
		'CURRENT' AS period_key, period_type, period_to AS period_code, period_to_startdate AS startdate, period_to_enddate AS enddate
	FROM params
	UNION ALL
	SELECT -- Kỳ trước
		'PREVIOUS' AS period_key, 
		period_type,
	  	CASE period_type
			WHEN 'D' THEN date_format(period_prev_startdate, 'yyyy-MM-dd')
			WHEN 'M' THEN date_format(period_prev_startdate, 'yyyy-MM')
			WHEN 'Q' THEN CONCAT(CAST(year(period_prev_startdate) AS string), '-Q', CAST(CAST(FLOOR((month(period_prev_startdate) - 1) / 3) + 1 AS int) AS string))
	    	WHEN 'Y' THEN CAST(YEAR(period_prev_startdate) AS string)
		END AS period_code, 
		period_prev_startdate AS startdate, 
		DATE_SUB(period_to_startdate, 1) AS enddate
	FROM params
)
-- 3. GTGD và KLGD từng ngày: đọc đủ dữ liệu YTD của cả hai kỳ
, trade_daily AS (
	SELECT
	    TO_DATE(h.trade_date, 'yyyyMMdd') AS tradingdate,
	    SUM(h.trade_quantity) AS klgd,
	    SUM(h.trade_quantity * h.trade_price) AS gtgd,
	    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price END) AS ndtnn_mua_gt,
	    SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price END) AS ndtnn_ban_gt,
	    SUM(CASE WHEN SUBSTR(h.buy_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) 
	    	- SUM(CASE WHEN SUBSTR(h.sell_account_number, 4, 1) IN ('E', 'F') THEN h.trade_quantity * h.trade_price ELSE 0 END) AS ndtnn_rong_gt
	FROM uat_hnx_stg.trade_book h
	CROSS JOIN params p
	WHERE h.market_id = 'HCX'
		AND h.trade_date BETWEEN DATE_FORMAT(DATE_TRUNC('YEAR', p.period_prev_startdate), 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') -- Tính từ ngày đầu năm của kỳ trước đến cuối kỳ này
	GROUP BY h.trade_date
)
-- 4. Đếm số mã trái phiếu theo ngày
, stock_daily AS (
  	SELECT
		js.tradingdate,
		COUNT(DISTINCT js.symbol) AS sl_ma_niemyet
	FROM uat_mdds_stg.jad_stockinfor js
	CROSS JOIN params p
	WHERE js.stocktype = '1' -- Trái phiếu
  		AND js.tradingdate BETWEEN CAST(DATE_TRUNC('YEAR', p.period_prev_startdate) AS DATE) AND p.period_to_enddate
	GROUP BY js.tradingdate
)
-- 5. Tổng hợp kỳ này và kỳ trước, ytd kỳ này và kỳ trước
, trade_period AS (
	SELECT
		p.period_key,
	    -- Số phiên từ đầu năm đến cuối kỳ
	    COUNT(t.tradingdate) AS so_phien_ytd,
	    -- KLGD, GTGD, GTGD NĐTNN kỳ này
		SUM(CASE WHEN t.tradingdate >= p.startdate THEN t.klgd ELSE 0 END) AS klgd,
	    SUM(CASE WHEN t.tradingdate >= p.startdate THEN t.gtgd ELSE 0 END) AS gtgd,
	    SUM(CASE WHEN t.tradingdate >= p.startdate THEN t.ndtnn_mua_gt ELSE 0 END) AS ndtnn_mua_gt,
	    SUM(CASE WHEN t.tradingdate >= p.startdate THEN t.ndtnn_ban_gt ELSE 0 END) AS ndtnn_ban_gt,
	    SUM(CASE WHEN t.tradingdate >= p.startdate THEN t.ndtnn_mua_gt ELSE 0 END) - SUM(CASE WHEN t.tradingdate >= p.startdate THEN t.ndtnn_ban_gt ELSE 0 END) AS ndtnn_rong_gt,
	    -- GTGD, GTGD bình quân tính từ đầu năm đến cuối kỳ
	    SUM(COALESCE(t.gtgd, 0)) AS gtgd_ytd,
	    SUM(COALESCE(t.gtgd, 0)) / COUNT(t.tradingdate) AS gtgd_bq_ytd
	FROM periods p
	LEFT JOIN trade_daily t ON t.tradingdate BETWEEN CAST(DATE_TRUNC('YEAR', p.enddate) AS DATE) AND p.enddate
	GROUP BY p.period_key
)
, stock_period AS (
  	SELECT
		p.period_key,
    	-- Số mã tại ngày dữ liệu cuối cùng trong kỳ
    	MAX_BY(CASE WHEN s.tradingdate >= p.startdate THEN s.sl_ma_niemyet END, s.tradingdate) AS sl_ma_niemyet
  	FROM periods p
  	LEFT JOIN stock_daily s ON s.tradingdate BETWEEN CAST(DATE_TRUNC('YEAR', p.enddate) AS DATE) AND p.enddate
  	GROUP BY p.period_key
)
-- 6. Chuyển chỉ tiêu thành hàng
, metric_list AS (
	SELECT 
		period_key, 
		metric,
		value
	FROM (
		SELECT period_key, klgd, gtgd, gtgd_ytd, gtgd_bq_ytd, ndtnn_mua_gt, ndtnn_ban_gt, ndtnn_rong_gt, NULL sl_ma_niemyet
		FROM trade_period
		UNION ALL 
		SELECT period_key, NULL klgd, NULL gtgd, NULL gtgd_ytd, NULL gtgd_bq_ytd, NULL ndtnn_mua_gt, NULL ndtnn_ban_gt, NULL ndtnn_rong_gt, sl_ma_niemyet
		FROM stock_period
	)
	UNPIVOT (
		value FOR metric IN (klgd, gtgd, gtgd_ytd, gtgd_bq_ytd, ndtnn_mua_gt, ndtnn_ban_gt, ndtnn_rong_gt, sl_ma_niemyet)
	)
) 
SELECT 
	p.period_type,
	p.period_to,
	d.metric,
	d.curr_value,
	d.prev_value,
	d.curr_value - d.prev_value AS change_value,
	(d.curr_value - d.prev_value) / NULLIF(d.prev_value, 0) * 100 AS change_percent
FROM params p 
CROSS JOIN (
	SELECT 
		metric,
		MAX(CASE WHEN period_key = 'CURRENT' THEN value END) AS curr_value,
		MAX(CASE WHEN period_key = 'PREVIOUS' THEN value END) AS prev_value
	FROM metric_list
	GROUP BY metric
) d
;