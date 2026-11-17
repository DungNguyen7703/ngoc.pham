-- 49. BÁO CÁO THƯỜNG NIÊN >> QUY MÔ NIÊM YẾT VÀ GIAO DỊCH TPCP
---- Tham số: :fromyear - :toyear  [Từ năm - Đến năm (yyyy)]
WITH 
-------------------------------------------------------
-- 1. Tổng GTGD Outright, Repo theo năm
-------------------------------------------------------
outright_agg AS (
  SELECT
    CAST(DATE_FORMAT(o.trading_date, 'yyyy') AS INT) AS nam,
    SUM(CAST(o.trading_value AS DECIMAL(38, 2))) AS gtgd_outright
  FROM uat_hnx_stg.outright_order_book o
  WHERE o.order_status = 'ĐTH'
    AND CAST(DATE_FORMAT(o.trading_date, 'yyyy') AS INT) BETWEEN CAST(:fromyear AS INT) AND CAST(:toyear AS INT)
  GROUP BY CAST(DATE_FORMAT(o.trading_date, 'yyyy') AS INT)
)
, repo_agg AS (
  SELECT
    CAST(DATE_FORMAT(r.trading_date, 'yyyy') AS INT) AS nam,
    SUM(CAST(r.first_settlement_value AS DECIMAL(38, 2))) AS gtgd_repo
  FROM uat_hnx_stg.repo_order_book r
  WHERE r.order_status = 'ĐTH'
    AND CAST(DATE_FORMAT(r.trading_date, 'yyyy') AS INT) BETWEEN CAST(:fromyear AS INT) AND CAST(:toyear AS INT)
  GROUP BY CAST(DATE_FORMAT(r.trading_date, 'yyyy') AS INT)
)
-------------------------------------------------------
-- 2. Tính Giá trị niêm yết TPCP 
-- * Lưu ý: Bảng gov_bond_listed_list là snapshot hàng tháng, chỉ có các mã TP chưa đáo hạn tại thời điểm đó, nên Giá trị niêm yết của năm sẽ chốt theo file/kỳ mới nhất có dữ liệu của năm.
-- 2.1: Sắp xếp để lấy file/kỳ mới nhất nhận được dữ liệu trong từng năm
-------------------------------------------------------
, gb_listed_lastest AS (
  -- Lấy ra tập mã trái phiếu thuộc đúng kỳ gần nhất (khử trùng lặp mã nếu có)
  SELECT
    report_year,
    report_month,
    bond_code,
    MAX(listed_volume) AS listed_volume
  FROM (
    -- Sắp xếp thứ tự kỳ để lấy ra file/kỳ mới nhất (rk=1)
    SELECT
      g.report_year,
      g.report_month AS report_month,
      g.bond_code, 
      g.listed_volume, 
      DENSE_RANK() OVER (PARTITION BY g.report_year ORDER BY g.report_month DESC, g.ds_snpst_dt DESC) AS rk 
    FROM uat_hnx_stg.gov_bond_listed_list g
    WHERE CAST(g.report_year AS INT) BETWEEN CAST(:fromyear AS INT) AND CAST(:toyear AS INT)
  ) l WHERE l.rk = 1
  GROUP BY report_year, report_month, bond_code
)
-- 2.2: Tính GT niêm yết của năm từ tập mã trái phiếu chưa đáo hạn của kỳ đó
, latest_listed AS (
  SELECT
    report_year AS nam,
    SUM(listed_volume) * 100000 AS gt_niem_yet
  FROM gb_listed_lastest
  GROUP BY report_year
)
---------------------------------------------------------------------------------
-- 3. Tổng hợp dữ liệu báo cáo
---------------------------------------------------------------------------------
SELECT
  y.nam,
  o.gtgd_outright AS gtgd_outright,
  r.gtgd_repo     AS gtgd_repo,
  l.gt_niem_yet   AS gt_niem_yet
FROM (SELECT EXPLODE(SEQUENCE(CAST(:fromyear AS INT), CAST(:toyear AS INT))) AS nam) y
LEFT JOIN outright_agg o  ON y.nam = o.nam
LEFT JOIN repo_agg r      ON y.nam = r.nam
LEFT JOIN latest_listed l ON y.nam = l.nam
ORDER BY y.nam ASC;