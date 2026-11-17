-- THỐNG KÊ THỊ TRƯỜNG >> TPCP >> CHỈ TIÊU TỔNG HỢP
/* Tham số tra cứu:
 * Loại kỳ: D/M/Q/Y
 * Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH
-- Từ tham số loại kỳ, kỳ báo cáo lấy ra Ngày đầu kỳ trước và ngày cuối kỳ này
period_bounds AS (
    SELECT
        *,
        CASE period_type
            WHEN 'D' THEN DATE_SUB(period_to_startdate, 1)
            WHEN 'M' THEN ADD_MONTHS(period_to_startdate, -1)
            WHEN 'Q' THEN ADD_MONTHS(period_to_startdate, -3)
            WHEN 'Y' THEN ADD_MONTHS(period_to_startdate, -12)
        END AS period_prev_startdate,
        CASE period_type
            WHEN 'D' THEN period_to_startdate
            WHEN 'M' THEN LAST_DAY(period_to_startdate)
            WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 3), 1)
            WHEN 'Y' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 12), 1)
        END AS period_to_enddate
    FROM (
    	SELECT
        :period_type AS period_type, -- Loại kỳ
        :period_to AS period_code, -- Kỳ báo cáo
        CAST(
            CASE :period_type
                WHEN 'D' THEN :period_to
                WHEN 'M' THEN CONCAT(:period_to, '-01')
                WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
                WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
            END AS DATE
        ) AS period_to_startdate -- Ngày đầu kỳ này
    )
)
-- Lấy ra ngày đầu năm của kỳ trước, ngày đầu năm và ngày cuối cùng của kỳ này
, params AS (
    SELECT
        p.*,
        DATE_SUB(period_to_startdate, 1) AS previous_end,
        CAST(DATE_TRUNC('YEAR', period_to_startdate) AS DATE) AS period_to_ytd_start,
        CAST(DATE_TRUNC('YEAR', period_prev_startdate) AS DATE) AS period_prev_ytd_start
    FROM period_bounds p
)
-- Thời gian Kỳ này, kỳ trước
, periods AS (
    SELECT
        'CURRENT' AS period_key, period_to_startdate AS period_start, period_to_enddate AS period_end, period_to_ytd_start AS ytd_start
    FROM params
    UNION ALL
    SELECT
        'PREVIOUS' AS period_key, period_prev_startdate AS period_start, previous_end AS period_end, period_prev_ytd_start AS ytd_start
    FROM params
)
-- Tính tổng giao dịch theo ngày: từ ngày đầu năm của kỳ trước đến ngày cuối của kỳ này
, daily_trade_data AS (
    SELECT 
		'OUTRIGHT' order_tool, 
		o.trading_date, 
		SUM(o.volume) AS klgd, 
		SUM(o.trading_value) AS gtgd,
		SUM(CASE WHEN SUBSTR(o.buying_account_no,4,1) IN ('E','F') THEN o.trading_value END) AS gtgd_ndtnn_mua,
		SUM(CASE WHEN SUBSTR(o.selling_account_no,4,1) IN ('E','F') THEN o.trading_value END) AS gtgd_ndtnn_ban
	FROM uat_hnx_stg.outright_order_book o 
	CROSS JOIN params p
	WHERE o.order_status = 'ĐTH'
	  AND o.trading_date BETWEEN p.period_prev_ytd_start AND p.period_to_enddate
	GROUP BY o.trading_date
	UNION ALL 
	SELECT 
		'REPO' order_tool, 
		r.trading_date, 
		SUM(r.volume) AS klgd, 
		SUM(r.first_settlement_value) AS gtgd,
		SUM(CASE WHEN SUBSTR(r.buying_account_no,4,1) IN ('E','F') THEN r.first_settlement_value END) AS gtgd_ndtnn_mua,
		SUM(CASE WHEN SUBSTR(r.selling_account_no,4,1) IN ('E','F') THEN r.first_settlement_value END) AS gtgd_ndtnn_ban
	FROM uat_hnx_stg.repo_order_book r 
	CROSS JOIN params p
	WHERE r.order_status = 'ĐTH'
	  AND r.trading_date BETWEEN p.period_prev_ytd_start AND p.period_to_enddate
	GROUP BY r.trading_date
)
, period_metrics AS (
	SELECT 
		m.period_key,
		m.klgd,
        m.gtgd,
        m.gtgd_ytd,
        m.gtgd_bq_ytd,
        m.gtgd_ndtnn_mua,
        m.gtgd_ndtnn_ban,
		COALESCE(gtgd_ndtnn_mua, 0) - COALESCE(gtgd_ndtnn_ban, 0) AS gtgd_ndtnn_rong
	FROM (
		-- Tổng giao dịch kỳ này và kỳ trước
	    SELECT
            c.period_key,
            SUM(CASE WHEN d.trading_date BETWEEN c.period_start AND c.period_end THEN d.klgd END) AS klgd,
            SUM(CASE WHEN d.trading_date BETWEEN c.period_start AND c.period_end THEN d.gtgd END) AS gtgd,
            SUM(d.gtgd) AS gtgd_ytd,
            -- AVG trên dữ liệu đã tổng theo ngày => tổng GTGD / số ngày có GTGD khác NULL
            AVG(d.gtgd) AS gtgd_bq_ytd, -- Hoặc dùng công thức SUM(d.gtgd) / COUNT(d.trading_date)
            SUM(CASE WHEN d.trading_date BETWEEN c.period_start AND c.period_end THEN d.gtgd_ndtnn_mua END) AS gtgd_ndtnn_mua,
            SUM(CASE WHEN d.trading_date BETWEEN c.period_start AND c.period_end THEN d.gtgd_ndtnn_ban END) AS gtgd_ndtnn_ban
	    FROM periods c
	    LEFT JOIN daily_trade_data d ON d.trading_date BETWEEN c.ytd_start AND c.period_end
	    GROUP BY c.period_key
    ) m
)
SELECT
    p.period_type AS loaiky,
    p.period_code AS ky,
    c.klgd,
    (c.klgd - b.klgd) AS klgd_pct_thaydoi,
    (c.klgd - b.klgd) / NULLIF(b.klgd, 0) * 100 AS klgd_pct_thaydoi_pt,
    c.gtgd,
    (c.gtgd - b.gtgd) AS gtgd_pct_thaydoi,
    (c.gtgd - b.gtgd) / NULLIF(b.gtgd, 0) * 100 AS gtgd_pct_thaydoi_pt,
    c.gtgd_bq_ytd,
    (c.gtgd_bq_ytd - b.gtgd_bq_ytd) AS gtgd_bq_ytd_thaydoi,
    (c.gtgd_bq_ytd - b.gtgd_bq_ytd) / NULLIF(b.gtgd_bq_ytd, 0) * 100 AS gtgd_bq_ytd_thaydoi_pt,
    c.gtgd_ndtnn_mua,
    (NVL(c.gtgd_ndtnn_mua, 0) - NVL(b.gtgd_ndtnn_mua, 0)) AS gtgd_ndtnn_mua_thaydoi,
    (NVL(c.gtgd_ndtnn_mua, 0) - NVL(b.gtgd_ndtnn_mua, 0)) / NULLIF(b.gtgd_ndtnn_mua, 0) * 100 AS gtgd_ndtnn_mua_thaydoi_pt,
    c.gtgd_ndtnn_ban,
    (NVL(c.gtgd_ndtnn_ban, 0) - NVL(b.gtgd_ndtnn_ban, 0)) AS gtgd_ndtnn_ban_thaydoi,
    (NVL(c.gtgd_ndtnn_ban, 0) - NVL(b.gtgd_ndtnn_ban, 0)) / NULLIF(b.gtgd_ndtnn_ban, 0) * 100 AS gtgd_ndtnn_ban_thaydoi_pt,
    c.gtgd_ndtnn_rong,
    (NVL(c.gtgd_ndtnn_rong, 0) - NVL(b.gtgd_ndtnn_rong, 0)) AS gtgd_ndtnn_rong_thaydoi,
    (NVL(c.gtgd_ndtnn_rong, 0) - NVL(b.gtgd_ndtnn_rong, 0)) / NULLIF(ABS(b.gtgd_ndtnn_rong), 0) * 100 AS gtgd_ndtnn_rong_thaydoi_pt
FROM params p
CROSS JOIN period_metrics c
CROSS JOIN period_metrics b
WHERE c.period_key = 'CURRENT'
  AND b.period_key = 'PREVIOUS'
;