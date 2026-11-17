-- 39. HOẠT ĐỘNG NĐTNN >> DÒNG TIỀN >> THỐNG KÊ THEO THỜI GIAN
/* ==============================================================================
 * Tham số:
 *  :period_type  HM = Nửa tháng | M = Tháng | Q = Quý | Y = Năm
 *  :period_from :period_to  HM: yyyy-MM-H[1-2] | M: yyyy-MM | Q: yyyy-Q[1-4] | Y: yyyy
 * Chỉ tiêu đầu ra: Vào ròng/Rút ròng, Dòng tiền vào, Dòng tiền ra của từng kỳ trong khoảng [Từ kỳ, Đến kỳ]
============================================================================== */
WITH 
-- Dữ liệu báo cáo dòng tiền (PLIV-TT51)
report_data AS (
  -- B2. Lọc trùng dữ liệu, lấy file báo cáo mới nhất của từng đối tượng trong kỳ
  SELECT v2.*
  FROM (
    -- B1. Dữ liệu từ bảng dãn phẳng báo cáo dòng tiền (PLIV-TT51)
    -- Lấy ra thông tin kỳ Nửa tháng/Tháng/Quý/Năm Tháng/năm lấy từ day_report, H1/H2 lấy từ period_value
    SELECT
      --DATE_ADD(TRUNC(CAST(day_report AS DATE), 'MM'), CASE WHEN CAST(SUBSTR(period_value,3,2) AS INT) <= 15 THEN 0 ELSE 15 END) AS halfmonth_date, -- Comment do không cần
      :period_type AS period_type,
      CASE :period_type
        WHEN 'HM' THEN CONCAT(DATE_FORMAT(day_report, 'yyyy-MM'), '-H', MAP('DT',1,'CT',2)[SUBSTR(period_value,1,2)])
        WHEN 'M'  THEN DATE_FORMAT(day_report, 'yyyy-MM') 
        WHEN 'Q'  THEN CONCAT(CAST(YEAR(day_report) AS STRING), '-Q', CAST(QUARTER(day_report) AS STRING))
        WHEN 'Y'  THEN CAST(year_value AS STRING) 
      END AS period_code,
      year_value,
      day_report,
      ngay_nop,
      period_value,
      --Lấy giá trị ngày của kỳ NUA_THANG từ NT01..NT31 --> Comment do không dùng nữa
      --CASE WHEN TRIM(period_value) RLIKE '^NT(0[1-9]|[12][0-9]|3[01])(/|$)' THEN CAST(REGEXP_EXTRACT(TRIM(period_value), '^NT([0-9]{2})(/|$)', 1) AS INT) END AS nt_day,
      object_name,
      row_path,
      column_path,
      CAST(value_raw AS DECIMAL(38,15)) AS value,
      -- Lọc trùng của cùng kỳ theo ngày bc x ngày nộp x id báo cáo
      DENSE_RANK() OVER(PARTITION BY object_name, year_value, DATE_FORMAT(day_report, 'yyyy-MM'), period_value ORDER BY day_report DESC, ngay_nop DESC, report_log_id DESC) rk 
    FROM uat_fims_ods.fir_value v
    WHERE report_code = 'IBOU9'
      AND period_type = 'NUA_THANG'
      AND row_path = 'Tổng= (1) + (2)'
      AND column_path IN (
          'Giá trị dòng vốn vào trong kỳ báo cáo (+/-) (đơn vị USD)',
          'Tổng giá trị ngoại tệ đổi sang VND trong kỳ báo cáo (đơn vị USD)',
          'Tổng giá trị VND đổi ra ngoại tệ và chuyển ra trong kỳ báo cáo (đơn vị USD)'
      )
  ) v2
  WHERE rk = 1
)
-- TỔNG HỢP CHỈ TIÊU LÊN BIỂU ĐỒ
SELECT
  period_type,
  period_code,
  CASE column_path
    WHEN 'Giá trị dòng vốn vào trong kỳ báo cáo (+/-) (đơn vị USD)' THEN 'Vào ròng/Rút ròng'
    WHEN 'Tổng giá trị ngoại tệ đổi sang VND trong kỳ báo cáo (đơn vị USD)' THEN 'Dòng tiền vào'
    WHEN 'Tổng giá trị VND đổi ra ngoại tệ và chuyển ra trong kỳ báo cáo (đơn vị USD)' THEN 'Dòng tiền ra'
  END AS metric,
  SUM(value) AS value
FROM report_data
WHERE period_code BETWEEN :period_from AND :period_to
GROUP BY period_type, period_code, column_path
ORDER BY period_code, column_path
;