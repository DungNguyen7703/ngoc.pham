-- THỐNG KÊ THỊ TRƯỜNG >> TPCP >> CHỈ TIÊU TỔNG HỢP
-- Bản clone: GTGD bình quân YTD so sánh với CẢ NĂM TRƯỚC (01/01 - 31/12 năm trước); các chỉ tiêu còn lại vẫn so với kỳ trước
-- Phần tính theo kỳ (period_metrics) và phần tính YTD (ytd_metrics) được tách riêng thành 2 CTE độc lập
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
-- Lấy ra ngày cuối kỳ trước, ngày đầu năm của kỳ này, ngày đầu năm và ngày cuối năm của năm trước (để tính YTD so với năm trước)
, params AS (
    SELECT
        p.*,
        DATE_SUB(period_to_startdate, 1) AS previous_end,
        CAST(DATE_TRUNC('YEAR', period_to_startdate) AS DATE) AS period_to_ytd_start, -- 01/01 năm của kỳ này
        ADD_MONTHS(CAST(DATE_TRUNC('YEAR', period_to_startdate) AS DATE), -12) AS period_py_ytd_start, -- 01/01 năm trước
        DATE_SUB(CAST(DATE_TRUNC('YEAR', period_to_startdate) AS DATE), 1) AS period_py_ytd_end -- 31/12 năm trước
    FROM period_bounds p
)
-- Thời gian Kỳ này, kỳ trước (dùng cho KLGD, GTGD, GTGD NĐTNN mua/bán/ròng)
, periods AS (
    SELECT
        'CURRENT' AS period_key, period_to_startdate AS period_start, period_to_enddate AS period_end
    FROM params
    UNION ALL
    SELECT
        'PREVIOUS' AS period_key, period_prev_startdate AS period_start, previous_end AS period_end
    FROM params
)
-- Thời gian YTD (dùng cho GTGD bình quân YTD): kỳ này = 01/01 năm nay -> ngày cuối kỳ; năm trước = cả năm trước 01/01 - 31/12
, ytd_periods AS (
    SELECT
        'CURRENT' AS ytd_key, period_to_ytd_start AS ytd_start, period_to_enddate AS ytd_end
    FROM params
    UNION ALL
    SELECT
        'PREVIOUS_YEAR' AS ytd_key, period_py_ytd_start AS ytd_start, period_py_ytd_end AS ytd_end
    -- Nếu muốn so với CÙNG KỲ năm trước (01/01 đến cùng ngày cuối kỳ năm trước) thay period_py_ytd_end bằng:
    --   CASE WHEN period_type = 'D' THEN ADD_MONTHS(period_to_enddate, -12) ELSE LAST_DAY(ADD_MONTHS(period_to_enddate, -12)) END
    FROM params
)
-- Tính tổng giao dịch theo ngày: từ ngày đầu năm trước đến ngày cuối của kỳ này (kỳ trước luôn nằm trong khoảng này)
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
	  AND o.trading_date BETWEEN p.period_py_ytd_start AND p.period_to_enddate
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
	  AND r.trading_date BETWEEN p.period_py_ytd_start AND p.period_to_enddate
	GROUP BY r.trading_date
)
-- Chỉ tiêu theo kỳ (kỳ này, đúng kỳ trước): KLGD, GTGD, GTGD NĐTNN mua/bán/ròng
, period_metrics AS (
	SELECT
		c.period_key,
		SUM(d.klgd) AS klgd,
		SUM(d.gtgd) AS gtgd,
		SUM(d.gtgd_ndtnn_mua) AS gtgd_ndtnn_mua,
		SUM(d.gtgd_ndtnn_ban) AS gtgd_ndtnn_ban,
		COALESCE(SUM(d.gtgd_ndtnn_mua), 0) - COALESCE(SUM(d.gtgd_ndtnn_ban), 0) AS gtgd_ndtnn_rong
	FROM periods c
	LEFT JOIN daily_trade_data d ON d.trading_date BETWEEN c.period_start AND c.period_end
	GROUP BY c.period_key
)
-- Chỉ tiêu YTD: GTGD YTD và GTGD bình quân/ngày YTD (kỳ này và năm trước)
-- daily_trade_data tách theo order_tool (OUTRIGHT, REPO) nên 1 ngày có thể có 2 dòng
-- => GTGD bình quân = SUM(GTGD) / số ngày giao dịch khác nhau (COUNT DISTINCT), không dùng AVG trên các dòng này
, ytd_metrics AS (
	SELECT
		y.ytd_key,
		SUM(d.gtgd) AS gtgd_ytd,
		COUNT(DISTINCT d.trading_date) AS so_ngay_ytd,
		SUM(d.gtgd) / NULLIF(COUNT(DISTINCT d.trading_date), 0) AS gtgd_bq_ytd
	FROM ytd_periods y
	LEFT JOIN daily_trade_data d ON d.trading_date BETWEEN y.ytd_start AND y.ytd_end
	GROUP BY y.ytd_key
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
    yc.gtgd_bq_ytd,
    yb.gtgd_bq_ytd AS gtgd_bq_ytd_namtruoc, -- GTGD bình quân/ngày cả năm trước (01/01 - 31/12)
    (yc.gtgd_bq_ytd - yb.gtgd_bq_ytd) AS gtgd_bq_ytd_thaydoi,
    (yc.gtgd_bq_ytd - yb.gtgd_bq_ytd) / NULLIF(yb.gtgd_bq_ytd, 0) * 100 AS gtgd_bq_ytd_thaydoi_pt,
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
CROSS JOIN period_metrics c -- Kỳ này
CROSS JOIN period_metrics b -- Kỳ trước
CROSS JOIN ytd_metrics yc -- YTD kỳ này
CROSS JOIN ytd_metrics yb -- YTD năm trước
WHERE c.period_key = 'CURRENT'
  AND b.period_key = 'PREVIOUS'
  AND yc.ytd_key = 'CURRENT'
  AND yb.ytd_key = 'PREVIOUS_YEAR'
;
