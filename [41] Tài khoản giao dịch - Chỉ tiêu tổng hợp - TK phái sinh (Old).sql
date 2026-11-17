-- TÀI KHOẢN GIAO DỊCH >> CHỈ TIÊU TỔNG HỢP >> TÀI KHOẢN PHÁI SINH
/* Tham số tra cứu:
 *   :period_type  Loại kỳ: D/M/Q/Y
 *   :period_to    Kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH 
-- Lọc dữ liệu báo cáo TTLK01_1 (Tài khoản Phái sinh)
bc_tk_phaisinh_raw AS (
  SELECT f2.* 
  FROM (
    SELECT
      f.report_year,
      f.report_month,
      f.row_num,
      TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) AS column_path,
      CAST(NULLIF(f.field_value, '') AS DOUBLE) AS field_value,
      DENSE_RANK() OVER (PARTITION BY f.report_year, f.report_month ORDER BY f.ds_snpst_dt DESC) AS rk -- Lọc snapshotdate
    FROM uat_iss_ods.flat_report f
    WHERE f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED') -- Trạng thái dữ liệu báo cáo
      AND f.submit_source = 'ICP' -- Chỉ lấy nguồn từ Sở/VSDC
      AND f.report_code = 'TTLK01_1' 
      AND TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) IN ('TỔNG CỘNG', 'SỐ LƯỢNG CUỐI KỲ > TRONG NƯỚC', 'SỐ LƯỢNG CUỐI KỲ > NƯỚC NGOÀI')
      -- Lọc các tháng thuộc kỳ tra cứu. Kỳ "Ngày" không có dữ liệu do báo cáo TTLK01 chỉ có dữ liệu THEO THÁNG
      AND f.date_type = 'MONTHLY'
      AND (
        (:period_type = 'M'
          AND report_year  = CAST(SUBSTR(:period_code, 1, 4) AS INT)
          AND report_month = CAST(SUBSTR(:period_code, 6, 2) AS INT))
        OR (:period_type = 'Q'
              AND report_year  = CAST(SUBSTR(:period_code, 1, 4) AS INT)
              AND CAST(CEIL(report_month / 3) AS INT) = CAST(SUBSTR(:period_code, 7, 1) AS INT))
        OR (:period_type = 'Y'
              AND report_year  = CAST(SUBSTR(:period_code, 1, 4) AS INT))
      )
  ) f2
  WHERE f2.rk = 1 -- Lọc snapshotdate
) 
-- TỔNG HỢP DỮ LIỆU LÊN BIỂU ĐỒ
SELECT
  :period_type AS period_type,
  :period_code AS period_code,
  CONCAT(report_year, '-', LPAD(report_month, 2, '0')) AS data_month,
  sl_tk_phaisinh_tong,
  sl_tk_phaisinh_trongnuoc,
  sl_tk_phaisinh_nuocngoai
FROM (
  -- Q/Y: tháng gần nhất có báo cáo; M: tối đa 1 dòng
  SELECT d.* 
  FROM (
    -- Tổng SL TK theo tháng
    SELECT 
      report_year,
      report_month,
      SUM(CASE WHEN column_path = 'TỔNG CỘNG' THEN field_value END) AS sl_tk_phaisinh_tong,
      SUM(CASE WHEN column_path = 'SỐ LƯỢNG CUỐI KỲ > TRONG NƯỚC' THEN field_value END) AS sl_tk_phaisinh_trongnuoc,
      SUM(CASE WHEN column_path = 'SỐ LƯỢNG CUỐI KỲ > NƯỚC NGOÀI' THEN field_value END) AS sl_tk_phaisinh_nuocngoai
    FROM bc_tk_phaisinh_raw 
    GROUP BY report_year, report_month
  ) d
  ORDER BY report_year DESC, report_month DESC
  LIMIT 1
)
;