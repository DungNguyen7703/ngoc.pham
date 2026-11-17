-- TÀI KHOẢN GIAO DỊCH >> CHỈ TIÊU TỔNG HỢP >> TÀI KHOẢN PHÁI SINH
/* Tham số tra cứu:
 *   :period_type  Loại kỳ: D/M/Q/Y
 *   :period_to    Kỳ: Ngày yyyy-MM-dd / Tháng yyyy-MM / Quý yyyy-Q[1-4] / Năm yyyy
 */
WITH
-- Dữ liệu báo cáo TTLK01_1 (Tài khoản Phái sinh)
flat_report_ttlk01_ps AS (
  SELECT 
    report_year, report_quarter, report_month, 
    make_date(report_year, report_month, 1) AS report_month_startdate, 
    CASE TRIM(REGEXP_REPLACE(column_path, '\\s+', ' '))
      WHEN 'TỔNG CỘNG' THEN 'TONG'
      WHEN 'SỐ LƯỢNG CUỐI KỲ > TRONG NƯỚC' THEN 'TRONG_NUOC'
      WHEN 'SỐ LƯỢNG CUỐI KỲ > NƯỚC NGOÀI' THEN 'NUOC_NGOAI'
    END AS metric,
    CAST(NULLIF(field_value, '') AS DECIMAL(38,2)) AS field_value
  FROM (
    SELECT
      f.report_year,
      f.report_quarter,
      f.report_month,
      f.column_path,
      f.field_value,
      DENSE_RANK() OVER (PARTITION BY f.report_year, f.report_month ORDER BY f.ds_snpst_dt DESC) AS rk_snapshotdate -- Lọc snapshot date
    FROM uat_iss_ods.flat_report f
    WHERE f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
      AND f.submit_source = 'ICP'
      AND f.report_code = 'TTLK01_1' 
      AND TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) IN ('TỔNG CỘNG', 'SỐ LƯỢNG CUỐI KỲ > TRONG NƯỚC', 'SỐ LƯỢNG CUỐI KỲ > NƯỚC NGOÀI')
      AND f.date_type = 'MONTHLY'
      AND f.report_year IN (CAST(SUBSTR(:period_to, 1, 4) AS INT), CAST(SUBSTR(:period_to, 1, 4) AS INT) - 1) -- Lọc báo cáo thuộc năm của kỳ tra cứu + năm trước
  ) f2
  WHERE f2.rk_snapshotdate = 1 -- Lấy snapshot date mới nhất cho mỗi kỳ
)
-- THAM SỐ LỌC -> Lấy ngày đầu cho tháng bắt đầu, tháng kết thúc của Kỳ tra cứu, Kỳ trước, Năm trước
, params_period AS (
  SELECT 
    stack(3,
         'CUR',  cur_start,                          cur_end,                             -- kỳ tra cứu
         'PREV', add_months(cur_start, -step_m),     add_months(cur_end, -step_m),        -- kỳ trước
         'YTD',  make_date(YEAR(cur_end) - 1, 1, 1), make_date(YEAR(cur_end) - 1, 12, 1)  -- năm trước
         ) AS (period_tag, period_start, period_end)
  FROM (
    SELECT
      CASE UPPER(:period_type)
        WHEN 'M' THEN to_date(CONCAT(:period_to, '-01'))
        WHEN 'Q' THEN make_date(CAST(SUBSTR(:period_to, 1, 4) AS INT), (CAST(SUBSTR(:period_to, 7, 1) AS INT) - 1) * 3 + 1, 1)
        WHEN 'Y' THEN make_date(CAST(SUBSTR(:period_to, 1, 4) AS INT), 1, 1)
      END AS cur_start,
      CASE UPPER(:period_type)
        WHEN 'M' THEN to_date(CONCAT(:period_to, '-01'))
        WHEN 'Q' THEN make_date(CAST(SUBSTR(:period_to, 1, 4) AS INT), CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3, 1)
        WHEN 'Y' THEN make_date(CAST(SUBSTR(:period_to, 1, 4) AS INT), 12, 1)
      END AS cur_end,
      CASE UPPER(:period_type) WHEN 'M' THEN 1 WHEN 'Q' THEN 3 WHEN 'Y' THEN 12 END AS step_m
  ) t
)
-- TỔNG HỢP DỮ LIỆU CHỈ TIÊU BIỂU ĐỒ
SELECT
  :period_type AS loaiky,
  :period_to   AS ky,
  metric       AS chi_tieu,
  cur_val                                          AS sl_tk_phaisinh,
  (cur_val - prev_val) / NULLIF(prev_val, 0) * 100 AS sl_tk_phaisinh_so_ky_truoc_pct,
  (cur_val - ytd_val) / NULLIF(ytd_val, 0) * 100   AS sl_tk_phaisinh_so_ky_truoc_pct
FROM (
  -- Lấy số liệu tháng mới nhất có dữ liệu của Kỳ tra cứu, Kỳ trước, Năm trước
  SELECT metric, period_tag, val
  FROM (
    SELECT
      f.metric,
      p.period_tag,
      f.field_value AS val,
      DENSE_RANK() OVER (PARTITION BY p.period_tag ORDER BY f.report_year DESC, f.report_month DESC) AS month_rk -- Sắp xếp thứ tự tháng mới nhất của kỳ
    FROM flat_report_ttlk01_ps f
    JOIN params_period p
      ON f.report_month_startdate BETWEEN p.period_start AND p.period_end   -- tháng thuộc kỳ
  ) r
  WHERE r.month_rk = 1
) t
PIVOT (MAX(val) FOR period_tag IN ('CUR' AS cur_val, 'PREV' AS prev_val, 'YTD' AS ytd_val))
ORDER BY metric
;