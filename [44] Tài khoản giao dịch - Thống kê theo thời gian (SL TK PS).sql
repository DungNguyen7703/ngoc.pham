-- TÀI KHOẢN GIAO DỊCH >> CHỈ TIÊU TỔNG HỢP >> TỔNG SỐ TÀI KHOẢN PHÁI SINH (theo từng kỳ trong khoảng)
/* Tham số tra cứu:
 *   :period_type  Loại kỳ: D/M/Q/Y
 *   :period_from  Từ kỳ: Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 *   :period_to    Đến kỳ: cùng định dạng với :period_from
 */
WITH
-- Dữ liệu báo cáo TTLK01_1: Tổng số tài khoản phái sinh theo tháng 
----> Gắn nhãn kỳ theo loại kỳ (Ngày, Tháng, Quý, Năm)
flat_report_ttlk01_ps AS (
  SELECT
    :period_type AS period_type,
    CASE :period_type
      WHEN 'M' THEN date_format(report_month_startdate, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(report_month_startdate), '-Q', QUARTER(report_month_startdate))
      WHEN 'Y' THEN CAST(YEAR(report_month_startdate) AS STRING)
      -- 'D': báo cáo TTLK01 chỉ có theo tháng -> NULL => không có dòng kết quả
    END AS period_code,
    report_month_startdate,
    field_value
  FROM (
    SELECT
      make_date(f2.report_year, f2.report_month, 1) AS report_month_startdate,
      TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) AS column_path,
      CAST(NULLIF(f2.field_value, '') AS DECIMAL(38,2)) AS field_value
    FROM (
      SELECT
        f.report_year,
        f.report_month,
        f.column_path,
        f.field_value,
        DENSE_RANK() OVER (PARTITION BY f.report_year, f.report_month ORDER BY f.ds_snpst_dt DESC) AS rk_snapshotdate -- Lọc snapshot date
      FROM uat_iss_ods.flat_report f
      WHERE f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
        AND f.submit_source = 'ICP'
        AND f.report_code = 'TTLK01_1'
        AND TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) IN ('TỔNG CỘNG')
        AND f.date_type = 'MONTHLY'
        AND f.report_year BETWEEN CAST(SUBSTR(:period_from, 1, 4) AS INT) AND CAST(SUBSTR(:period_to, 1, 4) AS INT)
    ) f2
    WHERE f2.rk_snapshotdate = 1 -- Lấy snapshot date mới nhất cho mỗi kỳ báo cáo
  ) m
)
-- SỐ LIỆU THEO TỪNG KỲ: tháng mới nhất có dữ liệu của kỳ
SELECT
  period_type AS loaiky,
  period_code AS ky,
  field_value AS tong_so_tk,
  date_format(report_month_startdate, 'yyyy-MM') AS thang_du_lieu   -- tháng báo cáo thực tế được lấy cho kỳ
FROM (
  SELECT
    period_type,
    period_code,
    report_month_startdate,
    field_value,
    DENSE_RANK() OVER (PARTITION BY period_code ORDER BY report_month_startdate DESC) AS month_rk -- Tháng mới nhất của kỳ
  FROM flat_report_ttlk01_ps
  WHERE period_code BETWEEN :period_from AND :period_to   -- kỳ thuộc khoảng tra cứu [Từ kỳ, Đến kỳ]
) r
WHERE r.month_rk = 1
ORDER BY period_code
;