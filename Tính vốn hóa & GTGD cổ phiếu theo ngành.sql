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
		si.*,
		o.outstanding_shares, 
		o.free_float_shares
	FROM (
		SELECT 
			tradingdate, 
			symbol, 
			symbolisin,
			stocktype,
			closeprice
		FROM (
		  	SELECT
				s.tradingdate, s.symbol, s.symbolisin, s.closeprice, s.stocktype,
				ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) rn
			FROM uat_mdds_stg.jad_stockinfor s
			CROSS JOIN params p
			WHERE s.stocktype = '2' -- Cổ phiếu
		  		AND s.tradingdate BETWEEN p.period_to_startdate AND p.period_to_enddate
		) WHERE rn = 1 -- Lấy bản ghi cuối mỗi ngày
	) si
	-- Lấy thông tin ngành nghề kinh tế cấp 1 của mã TPDNNY theo phân ngành từ IDS
	LEFT JOIN (
		SELECT 
			equity_ticker, category_l1_id, business_reg_no
		FROM (
			SELECT 
				equity_ticker, category_l1_id, business_reg_no, company_name_vn,
				ROW_NUMBER() OVER(PARTITION BY equity_ticker ORDER BY id) rn -- Lấy bản ghi cũ hơn (lọc dữ liệu test bị trùng)
			FROM uat_ids_stg.company_profiles 
			WHERE ds_snpst_dt = '2026-10-17' 
			  AND delete_flg <> '1'
			  AND (approval_status_cd <> 'REJECTED' OR approval_status_cd IS NULL) -- Không lấy trạng thái bị từ chối; Dữ liệu migration trạng thái NULL
		) WHERE rn = 1
	) p ON si.symbol = p.equity_ticker -- Hồ sơ CTĐC
	LEFT JOIN (
		SELECT id, industry_cd, industry_name 
		FROM uat_ids_stg.categories 
		WHERE ds_snpst_dt = '2026-10-17'
	) c ON p.category_l1_id = c.id -- Mã/Tên ngành
	-- CTCK là CTĐC đã niêm yết/ĐKGD -> Xác định thuộc ngành Tài chính ngân hàng
	LEFT JOIN (
		SELECT securities_code, listing_exchange, code
		FROM uat_scms_stg.SC_FIRM_INFO 
		WHERE deleted = '0'
		  AND securities_code IS NOT NULL 
		  AND ds_snpst_dt = '2026-08-22'
	) sc ON si.symbol = sc.securities_code
	-- CTQLQ là CTĐC đã niêm yết/ĐKGD -> Xác định thuộc ngành Tài chính ngân hàng
	LEFT JOIN (
		SELECT stock_code, market, code 
		FROM uat_fms_stg.securities 
		WHERE deleted = 0
  		  AND stock_code IS NOT NULL
  		  AND ds_snpst_dt = '2026-10-21'
  	) f ON si.symbol = f.stock_code
  	LEFT JOIN ( 
  		SELECT transaction_date, ticker_symbol, outstanding_shares, free_float_shares
  		FROM uat_vsdc_stg.outstanding_shares os 
  	) o ON si.tradingdate = o.transaction_date AND si.symbol = o.ticker_symbol 
)
-- Tổng GTGD TPDN niêm yết trong kỳ nhóm theo [ngành + kỳ hạn phát hành]
, trade_period AS (
	SELECT 
		industry_cd, industry_name, SUM(gtgd) AS gtgd
	FROM (
		SELECT
			s.industry_cd, 
			s.industry_name,
		    SUM(h.trade_quantity * h.trade_price) AS gtgd
		FROM uat_hnx_stg.trade_book h 
		LEFT JOIN stockinfor_daily s ON h.issue_code = s.symbolisin AND to_date(h.trade_date, 'yyyyMMdd') = s.tradingdate 
		CROSS JOIN params p
		WHERE h.market_id IN ('STX', 'UPX') 
			AND s.stocktype = '2'
			AND h.trade_date BETWEEN DATE_FORMAT(p.period_to_startdate, 'yyyyMMdd') AND DATE_FORMAT(p.period_to_enddate, 'yyyyMMdd') -- Lọc trade_date kiểu string dạng yyyyMMdd
		GROUP BY s.industry_cd, s.industry_name
		UNION ALL
		SELECT 
			s.industry_cd, 
			s.industry_name,
		    SUM(h.execution_value) AS gtgd
		FROM uat_hose_stg.trade_book h 
		LEFT JOIN stockinfor_daily s ON h.symbol = s.symbol AND h.trade_date = s.tradingdate 
		CROSS JOIN params p
		WHERE h.market_id IN ('STK') 
			AND s.stocktype = '2'
			AND h.trade_date BETWEEN p.period_to_startdate AND p.period_to_enddate
		GROUP BY s.industry_cd, s.industry_name
	) GROUP BY industry_cd, industry_name
)
SELECT 
	industry_cd, 
	industry_name, 
	MAX(marketcap_outstanding_shares) marketcap_outstanding_shares, 
	MAX(marketcap_freefloat) marketcap_freefloat, 
	MAX(gtgd) gtgd
FROM (
	SELECT 
		s.industry_cd, 
		s.industry_name,
		--SUM(s.outstanding_shares) outstanding_shares, 
		--SUM(s.free_float_shares) free_float_shares,
		SUM(s.closeprice * s.outstanding_shares) marketcap_outstanding_shares,
		SUM(s.closeprice * s.free_float_shares) marketcap_freefloat,
		NULL gtgd
	FROM stockinfor_daily s
	GROUP BY 
		s.industry_cd, 
		s.industry_name
	UNION ALL 
	SELECT industry_cd, industry_name, /*outstanding_shares, free_float_shares,*/ NULL marketcap_outstanding_shares, NULL marketcap_freefloat, gtgd
	FROM trade_period
) 
GROUP BY industry_cd, industry_name
;