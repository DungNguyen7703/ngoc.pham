-- THỐNG KÊ NIÊM YẾT/ĐKGD >> KL NIÊM YẾT/ĐKGD THEO TỪNG KỲ TRONG KHOẢNG [:period_from, :period_to]
/* Tham số:
 *   :period_type  Loại kỳ: M/Q/Y
 *   :period_from, :period_to  Kỳ bắt đầu/kết thúc: yyyy-MM / yyyy-Q[1-4] / yyyy
 * Cổ phiếu/CCQ/ETF/CQ/TPDNNY: lọc tradingdate trong [ngày đầu Từ kỳ, ngày cuối Đến kỳ] -> gán kỳ cho từng tradingdate -> lấy ngày giao dịch cuối của từng kỳ.
 * TPCP, TPDNRL: lọc các tháng thuộc [Từ kỳ, Đến kỳ] -> lấy tháng mới nhất có snapshot của từng kỳ.
 */
WITH
-- 1. NGÀY ĐẦU CỦA "TỪ KỲ" VÀ NGÀY CUỐI CỦA "ĐẾN KỲ"
params AS (
  SELECT
    CASE :period_type
      WHEN 'M' THEN TO_DATE(CONCAT(:period_from, '-01'))
      WHEN 'Q' THEN ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_from, 1, 4), '-01-01')), (CAST(RIGHT(:period_from, 1) AS INT) - 1) * 3)
      WHEN 'Y' THEN TO_DATE(CONCAT(:period_from, '-01-01'))
    END AS start_date,
    CASE :period_type
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_to, 1, 4), '-01-01')), CAST(RIGHT(:period_to, 1) AS INT) * 3 - 1))
      WHEN 'Y' THEN TO_DATE(CONCAT(:period_to, '-12-31'))
    END AS end_date
)
-- 2. Ngày đầu tháng của từng tháng trong khoảng [Từ kỳ, Đến kỳ]
, months AS (
  SELECT
    month_startdate,
    CASE :period_type
      WHEN 'M' THEN DATE_FORMAT(month_startdate, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(month_startdate), '-Q', QUARTER(month_startdate))
      WHEN 'Y' THEN CAST(YEAR(month_startdate) AS STRING)
    END AS period_code
  FROM (SELECT EXPLODE(SEQUENCE(TRUNC(start_date, 'MM'), TRUNC(end_date, 'MM'), INTERVAL 1 MONTH)) AS month_startdate FROM params) t
)
-- 3. CP, CCQ, ETF, CQ, TPDNNY: dữ liệu cuối ngày của từng mã tại ngày giao dịch cuối kỳ
, stock_agg AS (
  SELECT 
    period_code AS ky, 
    loai_ck, 
    MAP('02','HNX','04','UPCOM','10','HOSE')[floorcode] AS san,
    SUM(listedshare) AS kl_ny_dkgd
  FROM (
    SELECT
      d.period_code,
      s.tradingdate,
      s.symbol,
      s.floorcode,
      CASE
        WHEN s.stocktype = '1' THEN 'TPDNNY'
        WHEN s.stocktype = '2' THEN 'CP'
        WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'M' THEN 'CCQ'
        WHEN s.stocktype IN ('3', '6') AND s.fundtype = 'E' THEN 'ETF'
        WHEN s.stocktype = '4' THEN 'CQ' -- Không cần điều kiện floorcode do đã có WHERE s.floorcode <> '03'
        --WHEN SUBSTR(s.productid, 6, 2) = 'EW' THEN 'CQ'
      END AS loai_ck,
      CAST(s.listedshare AS DECIMAL(38,2)) AS listedshare,
      ROW_NUMBER() OVER(PARTITION BY d.period_code, s.tradingdate, s.symbol ORDER BY s.tradingtime DESC, s.`sequence` DESC) AS rn -- Lấy bản ghi cuối ngày
    FROM uat_mdds_stg.jad_stockinfor s
    JOIN (
      -- NGÀY GIAO DỊCH CUỐI CỦA TỪNG KỲ (chỉ xét tradingdate trong khoảng)
      SELECT m.period_code, MAX(d.tradingdate) AS tradingdate
      FROM (
        SELECT DISTINCT s.tradingdate
        FROM uat_mdds_stg.jad_stockinfor s
        CROSS JOIN params p
        WHERE s.tradingdate BETWEEN p.start_date AND p.end_date
      ) d
      JOIN months m ON TRUNC(d.tradingdate, 'MM') = m.month_startdate
      GROUP BY m.period_code
    ) d ON s.tradingdate = d.tradingdate
    WHERE s.floorcode <> '03' -- Không lấy chứng khoán phái sinh
  ) t
  WHERE rn = 1
  GROUP BY period_code, loai_ck, floorcode
)
-- 4. TPCP: tháng mới nhất của kỳ + snapshot mới nhất của tháng
, govbond_agg AS (
  SELECT 
    period_code AS ky, 
    'TPCP' loai_ck,
    SUM(listed_volume) AS kl_ny_dkgd
  FROM (
    SELECT m.period_code, g.bond_code, g.listed_volume,
      DENSE_RANK() OVER(PARTITION BY m.period_code ORDER BY m.month_startdate DESC, g.ds_snpst_dt DESC) AS rk -- Lấy tháng báo cáo mới nhất của mỗi kỳ + Lọc snapshot date mới nhất
    FROM uat_hnx_stg.gov_bond_listed_list g
    JOIN months m ON MAKE_DATE(g.report_year, g.report_month, 1) = m.month_startdate -- Lọc báo cáo tháng trong khoảng [Từ kỳ, Đến kỳ]
  ) t
  WHERE rk = 1
  GROUP BY period_code
)
-- 5. TPDNRL: tháng mới nhất của kỳ + snapshot mới nhất của tháng
, corpbond_agg AS (
  SELECT 
    period_code AS ky, 
    'TPDNRL' loai_ck,
    SUM(registered_trading_volume) AS kl_ny_dkgd
  FROM (
    SELECT m.period_code, c.bond_code, c.registered_trading_volume,
      DENSE_RANK() OVER(PARTITION BY m.period_code ORDER BY m.month_startdate DESC, c.ds_snpst_dt DESC) AS rk -- Lấy tháng báo cáo mới nhất của mỗi kỳ + Lọc snapshot date mới nhất
    FROM uat_hnx_stg.private_corp_bond_registration c
    JOIN months m ON MAKE_DATE(c.report_year, c.report_month, 1) = m.month_startdate -- Lọc báo cáo tháng trong khoảng [Từ kỳ, Đến kỳ]
  ) t
  WHERE rk = 1
  GROUP BY period_code
)
-- 6. TỔNG HỢP LÊN BIỂU ĐỒ
SELECT ky, loai_ck, san, kl_ny_dkgd FROM stock_agg
UNION ALL
SELECT ky, loai_ck, NULL, kl_ny_dkgd FROM govbond_agg
UNION ALL
SELECT ky, loai_ck, NULL, kl_ny_dkgd FROM corpbond_agg
ORDER BY ky, loai_ck
;