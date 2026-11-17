-- THỐNG KÊ THỊ TRƯỜNG >> GIÁ TRỊ NIÊM YẾT/ĐKGD TRÁI PHIẾU (TPCP, TPDNNY, TPDNRL, TỔNG TPDN): TÍNH TẠI 1 KỲ
/* Tham số tra cứu (Spark SQL named parameter):
 * :period_type  Loại kỳ: D/M/Q/Y
 * :period_code  Kỳ báo cáo: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 *
 * Kết quả: mỗi loại trái phiếu 1 dòng: TPCP, TPDNNY, TPDNRL, TP (= TPDNNY + TPDNRL)
 *   listedvalue_cur      : GT niêm yết/ĐKGD tại ngày giao dịch cuối cùng của kỳ báo cáo
 *   listedvalue_prev     : GT tại ngày giao dịch cuối cùng của kỳ trước (D-1 / M-1 / Q-1 / Y-1)
 *   listedvalue_py       : GT tại ngày giao dịch cuối cùng của năm trước (<= 31/12 năm trước của kỳ báo cáo)
 *   listedvalue_prev_pct : % thay đổi so với kỳ trước          = (cur - prev) / prev x 100
 *   listedvalue_py_pct   : % thay đổi so với cuối năm trước    = (cur - py) / py x 100
 *   report_month_cur/prev/py : Tháng báo cáo (yyyy-MM) của snapshot đã dùng cho TPCP, TPDNRL (TPDNNY, TP: NULL)
 *
 * GT niêm yết = Mệnh giá x KL niêm yết/ĐKGD (SỐ DƯ tại cuối kỳ, không phải phát sinh trong kỳ). Đơn vị: VND.
 *   - TPCP   : uat_hnx_stg.gov_bond_listed_list (snapshot tháng)         GT = listed_volume x 100.000
 *   - TPDNNY : uat_mdds_stg.jad_stockinfor (bản ghi cuối của ngày GD chốt kỳ)
 *              GT = listedshare x mệnh giá (mệnh giá suy từ reference, như thong_ke_nien_yet_dkgd.sql)
 *   - TPDNRL : uat_hnx_stg.private_corp_bond_registration (snapshot tháng) GT = registered_trading_volume x par_value
 *              (snapshot tháng chỉ chứa mã chưa đáo hạn -> không cần lọc đáo hạn)
 *
 * Ngày chốt (TPDNNY) = ngày giao dịch cuối cùng <= ngày cuối kỳ (lịch GD từ sổ lệnh HNX + jad_marketinfor).
 *
 * Tháng báo cáo cho snapshot tháng (TPCP, TPDNRL) - CHỈ lấy đúng tháng báo cáo của kỳ, không lùi sang tháng cũ hơn;
 * không có snapshot thì NULL (dòng TP cũng NULL nếu thiếu 1 trong 2 thành phần):
 *   - Kỳ D     : chỉ có số khi ngày chốt là phiên giao dịch cuối tháng -> snapshot đúng tháng của ngày chốt.
 *   - Kỳ M     : snapshot đúng tháng tra cứu.
 *   - Kỳ Q / Y : snapshot của tháng mới nhất có dữ liệu trong quý / năm đó.
 *   - Cuối năm trước (PY): snapshot tháng 12 năm trước (kỳ trước (PREV) theo cùng quy tắc của loại kỳ).
 *   - Một tháng có nhiều snapshot (ds_snpst_dt) -> lấy snapshot mới nhất của tháng đó.
 */
WITH
-- 1. Tham số tra cứu: Loại kỳ + Kỳ báo cáo -> ngày đầu/cuối kỳ này, kỳ trước, cuối năm trước (ngày lịch; chốt sang ngày giao dịch ở bước 2)
params AS (
	SELECT
		period_type,
		period_code,
		period_to_startdate AS cur_start, -- Ngày đầu kỳ này
		period_to_enddate AS cur_end, -- Ngày cuối kỳ này
		CASE period_type
			WHEN 'D' THEN DATE_SUB(period_to_startdate, 1)
			WHEN 'M' THEN ADD_MONTHS(period_to_startdate, -1)
			WHEN 'Q' THEN ADD_MONTHS(period_to_startdate, -3)
			WHEN 'Y' THEN ADD_MONTHS(period_to_startdate, -12)
		END AS prev_start, -- Ngày đầu kỳ trước
		DATE_SUB(period_to_startdate, 1) AS prev_end, -- Ngày cuối kỳ trước
		MAKE_DATE(YEAR(period_to_enddate) - 1, 12, 31) AS py_end -- Ngày cuối năm trước (31/12 năm trước của kỳ báo cáo)
	FROM (
		SELECT
			x.*,
			CASE period_type
				WHEN 'D' THEN period_to_startdate
				WHEN 'M' THEN LAST_DAY(period_to_startdate)
				WHEN 'Q' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 3), 1)
				WHEN 'Y' THEN DATE_SUB(ADD_MONTHS(period_to_startdate, 12), 1)
			END AS period_to_enddate
		FROM (
			SELECT
				:period_type AS period_type, -- Loại kỳ: D/M/Q/Y
				:period_code AS period_code, -- Kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
				CAST(CASE :period_type
					WHEN 'D' THEN :period_code
					WHEN 'M' THEN CONCAT(:period_code, '-01')
					WHEN 'Q' THEN CONCAT(SUBSTR(:period_code, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_code, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
					WHEN 'Y' THEN CONCAT(:period_code, '-01-01')
				END AS DATE) AS period_to_startdate -- Ngày đầu kỳ này
		) x
	)
)
-- 2. Mốc cần tính: CUR (kỳ này), PREV (kỳ trước), PY (cuối năm trước): ngày đầu - cuối kỳ của từng mốc
, period_ends AS (
	SELECT period_type, 'CUR'  AS period_key, cur_start  AS startdate, cur_end  AS enddate FROM params
	UNION ALL
	SELECT period_type, 'PREV' AS period_key, prev_start AS startdate, prev_end AS enddate FROM params
	UNION ALL
	SELECT period_type, 'PY'   AS period_key, DATE_TRUNC('MONTH', py_end) AS startdate, py_end AS enddate FROM params -- Cuối năm trước: tháng 12 năm trước
)
-- 2.1. Lịch ngày giao dịch thực tế (sổ lệnh HNX + MDDS): từ ngày đầu năm trước đến hết tháng của ngày cuối kỳ này
----   (lấy đến cuối tháng để biết ngày chốt có phải phiên giao dịch cuối tháng không)
, trading_calendar AS (
	SELECT DISTINCT TO_DATE(h.trade_date, 'yyyyMMdd') AS tradingdate
	FROM uat_hnx_stg.trade_book h
	CROSS JOIN params p
	WHERE h.trade_date >= DATE_FORMAT(DATE_TRUNC('YEAR', p.py_end), 'yyyyMMdd') AND h.trade_date <= DATE_FORMAT(LAST_DAY(p.cur_end), 'yyyyMMdd')
	UNION
	SELECT DISTINCT m.tradingdate
	FROM uat_mdds_stg.jad_marketinfor m
	CROSS JOIN params p
	WHERE m.tradingdate >= DATE_TRUNC('YEAR', p.py_end) AND m.tradingdate <= LAST_DAY(p.cur_end)
)
-- 2.2. Ngày giao dịch chốt kỳ (ngày GD gần nhất <= ngày cuối kỳ) + ngày GD liền sau
, trading_dates AS (
	SELECT
		e.period_type,
		e.period_key,
		e.startdate,
		e.enddate,
		MAX(CASE WHEN c.tradingdate <= e.enddate THEN c.tradingdate END) AS tradedate,
		MIN(CASE WHEN c.tradingdate >  e.enddate THEN c.tradingdate END) AS next_tradedate
	FROM period_ends e
	CROSS JOIN trading_calendar c
	GROUP BY e.period_type, e.period_key, e.startdate, e.enddate
)
-- 2.3. Khoảng tháng báo cáo (yyyyMM) được phép dùng cho snapshot tháng (TPCP, TPDNRL): ym_lo <= tháng báo cáo <= ym_hi
----   Kỳ D: chỉ khi ngày chốt là phiên giao dịch cuối tháng (phiên liền sau sang tháng khác, hoặc chưa có phiên liền sau) -> đúng tháng của ngày chốt;
----         ngày khác -> NULL. (Nếu tháng của ngày chốt chưa có snapshot thì kết quả cũng là NULL.)
----   Kỳ M/Q/Y và cuối năm trước: các tháng nằm trong kỳ của từng mốc
, periods AS (
	SELECT
		period_key,
		tradedate,
		CASE WHEN period_type = 'D'
			 THEN CASE WHEN COALESCE(DATE_FORMAT(next_tradedate, 'yyyyMM') <> DATE_FORMAT(tradedate, 'yyyyMM'), TRUE)
					   THEN YEAR(tradedate) * 100 + MONTH(tradedate) END
			 ELSE YEAR(startdate) * 100 + MONTH(startdate)
		END AS ym_lo,
		CASE WHEN period_type = 'D'
			 THEN CASE WHEN COALESCE(DATE_FORMAT(next_tradedate, 'yyyyMM') <> DATE_FORMAT(tradedate, 'yyyyMM'), TRUE)
					   THEN YEAR(tradedate) * 100 + MONTH(tradedate) END
			 ELSE YEAR(enddate) * 100 + MONTH(enddate)
		END AS ym_hi
	FROM trading_dates
)
-- 3. TPDNNY: bản ghi cuối của mỗi mã tại ngày giao dịch chốt kỳ của từng mốc (jad_stockinfor có nhiều dòng/mã)
, stock_eod AS (
	SELECT period_key, symbol, listedshare, reference
	FROM (
		SELECT
			t.period_key, s.symbol,
			CAST(s.listedshare AS DECIMAL(38, 0)) AS listedshare,
			CAST(s.reference AS DOUBLE) AS reference,
			ROW_NUMBER() OVER(PARTITION BY t.period_key, s.symbol ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn
		FROM uat_mdds_stg.jad_stockinfor s
		JOIN periods t ON s.tradingdate = t.tradedate
		WHERE s.stocktype = '1' AND s.floorcode <> '03' -- TPDN niêm yết (floorcode 03 là TPCP -> không tính)
	)
	WHERE rn = 1
)
-- 3.1. GT niêm yết TPDNNY = KL niêm yết x Mệnh giá (mệnh giá suy từ reference: 100.000 x 10^n)
, tpdnny_value AS (
	SELECT
		period_key,
		SUM(listedshare * 100000 * POWER(10, ROUND(LN(NULLIF(reference, 0) / 100000) / LN(10)))) AS gt
	FROM stock_eod
	GROUP BY period_key
)
-- 4. TPCP: danh sách TPCP niêm yết (snapshot tháng); mỗi tháng lấy snapshot mới nhất
, gov_src AS (
	SELECT ym, bond_code, listed_volume
	FROM (
		SELECT
			ym, bond_code, listed_volume, ds_snpst_dt,
			MAX(ds_snpst_dt) OVER(PARTITION BY ym) AS max_snpst_dt
		FROM (
			SELECT
				CAST(g.report_year AS INT) * 100 + CAST(RIGHT(CAST(g.report_month AS STRING), 2) AS INT) AS ym, -- report_month có thể là 'MM' hoặc 'yyyy-MM'
				g.bond_code,
				CAST(g.listed_volume AS DECIMAL(38, 2)) AS listed_volume,
				g.ds_snpst_dt
			FROM uat_hnx_stg.gov_bond_listed_list g
		)
	)
	WHERE ds_snpst_dt = max_snpst_dt
)
, gov_ym AS ( -- Tháng báo cáo mới nhất nằm trong khoảng được phép của từng mốc (không có -> không có dòng -> NULL)
	SELECT t.period_key, MAX(g.ym) AS ym
	FROM periods t
	JOIN (SELECT DISTINCT ym FROM gov_src) g ON g.ym BETWEEN t.ym_lo AND t.ym_hi
	GROUP BY t.period_key
)
, tpcp_value AS ( -- GT niêm yết TPCP = KL niêm yết x 100.000 (khử trùng lặp mã)
	SELECT period_key, SUM(listed_volume) * 100000 AS gt
	FROM (
		SELECT y.period_key, g.bond_code, MAX(g.listed_volume) AS listed_volume
		FROM gov_ym y
		JOIN gov_src g ON g.ym = y.ym
		GROUP BY y.period_key, g.bond_code
	)
	GROUP BY period_key
)
-- 5. TPDNRL: TPDN riêng lẻ đăng ký giao dịch (snapshot tháng); mỗi tháng lấy snapshot mới nhất
, reg_src AS (
	SELECT ym, registered_trading_volume, par_value
	FROM (
		SELECT
			ym, registered_trading_volume, par_value, ds_snpst_dt,
			MAX(ds_snpst_dt) OVER(PARTITION BY ym) AS max_snpst_dt
		FROM (
			SELECT
				CAST(r.report_year AS INT) * 100 + CAST(RIGHT(CAST(r.report_month AS STRING), 2) AS INT) AS ym,
				CAST(r.registered_trading_volume AS DECIMAL(38, 2)) AS registered_trading_volume,
				CAST(r.par_value AS DECIMAL(38, 2)) AS par_value,
				r.ds_snpst_dt
			FROM uat_hnx_stg.private_corp_bond_registration r
		)
	)
	WHERE ds_snpst_dt = max_snpst_dt
)
, reg_ym AS (
	SELECT t.period_key, MAX(r.ym) AS ym
	FROM periods t
	JOIN (SELECT DISTINCT ym FROM reg_src) r ON r.ym BETWEEN t.ym_lo AND t.ym_hi
	GROUP BY t.period_key
)
, tpdnrl_value AS ( -- GT ĐKGD TPDNRL = KL đăng ký giao dịch x Mệnh giá
	SELECT y.period_key, SUM(r.registered_trading_volume * r.par_value) AS gt
	FROM reg_ym y
	JOIN reg_src r ON r.ym = y.ym
	GROUP BY y.period_key
)
-- 6. Gộp 3 loại -> pivot theo kỳ (CUR / PREV / PY)
, listed_value AS (
	SELECT
		bond_type,
		MAX(CASE WHEN period_key = 'CUR'  THEN gt END) AS cur_gt,
		MAX(CASE WHEN period_key = 'PREV' THEN gt END) AS prev_gt,
		MAX(CASE WHEN period_key = 'PY'   THEN gt END) AS py_gt
	FROM (
		SELECT 'TPCP'   AS bond_type, period_key, gt FROM tpcp_value
		UNION ALL
		SELECT 'TPDNNY' AS bond_type, period_key, gt FROM tpdnny_value
		UNION ALL
		SELECT 'TPDNRL' AS bond_type, period_key, gt FROM tpdnrl_value
	)
	GROUP BY bond_type
)
-- 7. Thêm dòng tổng TP = TPDNNY + TPDNRL (NULL nếu thiếu 1 trong 2; muốn gồm cả TPCP: cộng thêm TPCP)
, listed_total AS (
	SELECT bond_type, cur_gt, prev_gt, py_gt FROM listed_value
	UNION ALL
	SELECT 'TP' AS bond_type, a.cur_gt + b.cur_gt, a.prev_gt + b.prev_gt, a.py_gt + b.py_gt
	FROM listed_value a
	JOIN listed_value b ON a.bond_type = 'TPDNNY' AND b.bond_type = 'TPDNRL'
)
-- 8. Tháng báo cáo của snapshot đã dùng (TPCP, TPDNRL)
, report_month AS (
	SELECT
		bond_type,
		MAX(CASE WHEN period_key = 'CUR'  THEN ym_label END) AS report_month_cur,
		MAX(CASE WHEN period_key = 'PREV' THEN ym_label END) AS report_month_prev,
		MAX(CASE WHEN period_key = 'PY'   THEN ym_label END) AS report_month_py
	FROM (
		SELECT 'TPCP' AS bond_type, period_key, CONCAT(CAST(ym DIV 100 AS STRING), '-', LPAD(CAST(ym % 100 AS STRING), 2, '0')) AS ym_label FROM gov_ym
		UNION ALL
		SELECT 'TPDNRL' AS bond_type, period_key, CONCAT(CAST(ym DIV 100 AS STRING), '-', LPAD(CAST(ym % 100 AS STRING), 2, '0')) AS ym_label FROM reg_ym
	)
	GROUP BY bond_type
)
-- 9. Danh mục dòng hiển thị (luôn đủ dòng kể cả khi không có dữ liệu)
, bond_dm AS (
	SELECT * FROM VALUES
		(1, 'TPCP'),
		(2, 'TPDNNY'),
		(3, 'TPDNRL'),
		(4, 'TP')
	AS t(bond_order, bond_type)
)
-- 10. Kết quả
SELECT
	p.period_type,
	p.period_code,
	d.bond_type,
	CAST(l.cur_gt  AS DECIMAL(38, 2)) AS listedvalue_cur,
	CAST(l.prev_gt AS DECIMAL(38, 2)) AS listedvalue_prev,
	CAST(l.py_gt   AS DECIMAL(38, 2)) AS listedvalue_py,
	(l.cur_gt - l.prev_gt) / NULLIF(ABS(l.prev_gt), 0) * 100 AS listedvalue_prev_pct,
	(l.cur_gt - l.py_gt)   / NULLIF(ABS(l.py_gt), 0)   * 100 AS listedvalue_py_pct,
	m.report_month_cur,
	m.report_month_prev,
	m.report_month_py
FROM bond_dm d
CROSS JOIN params p
LEFT JOIN listed_total l ON d.bond_type = l.bond_type
LEFT JOIN report_month m ON d.bond_type = m.bond_type
ORDER BY d.bond_order
;
