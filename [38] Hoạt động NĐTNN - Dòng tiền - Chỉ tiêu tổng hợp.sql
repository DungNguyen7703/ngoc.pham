-- 38. HOẠT ĐỘNG NĐTNN >> DÒNG TIỀN >> CHỈ TIÊU TỔNG HỢP
/* ===============================================================
 * Tham số:
 *  :period_type  HM = Nửa tháng | M = Tháng | Q = Quý | Y = Năm
 *  :period_code  HM: yyyy-MM-H[1-2] | M: yyyy-MM | Q: yyyy-Q[1-4] | Y: yyyy
 * Chỉ tiêu trả ra:
 *  1. Vào ròng/Rút ròng, Dòng tiền vào, Dòng tiền ra  (kỳ tra cứu)
 *  2. Vào ròng/Rút ròng (YTD)                         (từ 01/01 đến hết kỳ tra cứu)
 *  3. % so với kỳ trước của: Vào ròng/Rút ròng, Dòng tiền vào, Dòng tiền ra --> % = (kỳ này - kỳ trước) / kỳ trước * 100
=============================================================== */
WITH
-- Tham số kỳ -> Lấy kỳ trước, kỳ đầu năm
period_bounds AS (
  SELECT
    :period_type AS period_type,
    :period_code AS period_code,
    CASE :period_type
      WHEN 'HM' THEN
        CASE
          WHEN RIGHT(:period_code, 1) = '2' THEN CONCAT(SUBSTR(:period_code, 1, 7), '-H1') -- H2 -> H1 cùng tháng
          ELSE CONCAT(DATE_FORMAT(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(:period_code, 1, 7), '-01')), -1), 'yyyy-MM'), '-H2') -- H1 -> H2 tháng trước
        END
      WHEN 'M' THEN DATE_FORMAT(ADD_MONTHS(TO_DATE(CONCAT(:period_code, '-01')), -1), 'yyyy-MM')
      WHEN 'Q' THEN
        CASE
          WHEN RIGHT(:period_code, 1) = '1' THEN CONCAT(CAST(CAST(SUBSTR(:period_code, 1, 4) AS INT) - 1 AS STRING),'-Q4')
          ELSE CONCAT(SUBSTR(:period_code, 1, 4), '-Q', CAST(CAST(RIGHT(:period_code, 1) AS INT) - 1 AS STRING))
        END
      WHEN 'Y' THEN CAST(CAST(:period_code AS INT) - 1 AS STRING)
    END AS previous_code,
    CASE :period_type
      WHEN 'HM' THEN CONCAT(SUBSTR(:period_code, 1, 4), '-01-H1')
      WHEN 'M'  THEN CONCAT(SUBSTR(:period_code, 1, 4), '-01')
      WHEN 'Q'  THEN CONCAT(SUBSTR(:period_code, 1, 4), '-Q1')
      WHEN 'Y'  THEN :period_code
    END AS ytd_start_code
)
-- Dữ liệu báo cáo dòng tiền (PLIV-TT51)
, report_data AS (
  -- B2. Lọc trùng dữ liệu, lấy file báo cáo mới nhất của từng đối tượng trong kỳ
  SELECT d.*
  FROM (
    -- B1. Dữ liệu từ bảng dãn phẳng báo cáo dòng tiền (PLIV-TT51)
    -- Lấy ra thông tin kỳ Nửa tháng/Tháng/Quý/Năm tương ứng của từng kỳ báo cáo
    SELECT
      CASE :period_type 
        WHEN 'HM' THEN CONCAT(DATE_FORMAT(day_report, 'yyyy-MM'), '-H', MAP('DT',1,'CT',2)[SUBSTR(period_value,1,2)])
        WHEN 'M' THEN DATE_FORMAT(day_report, 'yyyy-MM')
        WHEN 'Q' THEN CONCAT(CAST(YEAR(day_report) AS STRING), '-Q', CAST(QUARTER(day_report) AS STRING))
        WHEN 'Y' THEN CAST(YEAR(day_report) AS STRING)
      END AS period_code,
      day_report,
      period_value,
      ngay_nop,
      object_name,
      column_path,
      CASE column_path
        WHEN 'Giá trị dòng vốn vào trong kỳ báo cáo (+/-) (đơn vị USD)' THEN 'Vào ròng/Rút ròng'
        WHEN 'Tổng giá trị ngoại tệ đổi sang VND trong kỳ báo cáo (đơn vị USD)' THEN 'Dòng tiền vào'
        WHEN 'Tổng giá trị VND đổi ra ngoại tệ và chuyển ra trong kỳ báo cáo (đơn vị USD)' THEN 'Dòng tiền ra'
      END AS metric,
      CAST(value_raw AS DECIMAL(38,15)) AS value,
      -- Lọc trùng của cùng kỳ theo ngày bc x ngày nộp x id báo cáo
      DENSE_RANK() OVER (PARTITION BY object_name, DATE_FORMAT(day_report, 'yyyy-MM'), period_value ORDER BY day_report DESC, ngay_nop DESC, report_log_id DESC) AS rk
    FROM uat_fims_ods.fir_value v
    WHERE report_code = 'IBOU9'
      AND period_type = 'NUA_THANG'
      AND row_path = 'Tổng= (1) + (2)'
      AND column_path IN (
          'Giá trị dòng vốn vào trong kỳ báo cáo (+/-) (đơn vị USD)',
          'Tổng giá trị ngoại tệ đổi sang VND trong kỳ báo cáo (đơn vị USD)',
          'Tổng giá trị VND đổi ra ngoại tệ và chuyển ra trong kỳ báo cáo (đơn vị USD)'
      )
  ) d
  WHERE rk = 1
)
-- TỔNG HỢP DỮ LIỆU LÊN BIỂU ĐỒ
SELECT
  t.*,
  (period_cur_value - period_prev_value) / NULLIF(period_prev_value, 0) * 100.0 AS current_vs_prev_pct -- So với kỳ trước
FROM (
  SELECT
    p.period_type,
    p.period_code,
    d.metric,
    SUM(CASE WHEN d.period_code = p.period_code THEN d.value END) AS period_cur_value, -- Số kỳ này
    SUM(CASE WHEN d.period_code = p.previous_code THEN d.value END ) AS period_prev_value, -- Số kỳ trước
    SUM(CASE WHEN d.period_code BETWEEN p.ytd_start_code AND p.period_code THEN d.value END) AS ytd_value -- Số từ đầu năm đến kỳ này
  FROM report_data d
  CROSS JOIN period_bounds p
  -- Lấy dữ liệu kỳ trước và các kỳ thuộc YTD
  WHERE d.period_code = p.previous_code -- Lấy dữ liệu của các báo cáo thuộc kỳ trước
     OR d.period_code BETWEEN p.ytd_start_code AND p.period_code -- Lấy dữ liệu của các báo cáo từ kỳ đầu năm đến kỳ này
  GROUP BY p.period_type, p.period_code, d.metric
) t
ORDER BY metric;

------------- ****************** CÁCH 2 ****************** -------------
-- HOẠT ĐỘNG NĐTNN >> DÒNG TIỀN >> CHỈ TIÊU TỔNG HỢP
/* ===============================================================
 * Tham số:
 *  :period_type  HM = Nửa tháng | M = Tháng | Q = Quý | Y = Năm
 *  :period_code  HM: yyyy-MM-H[1-2] | M: yyyy-MM | Q: yyyy-Q[1-4] | Y: yyyy
 * Chỉ tiêu trả ra:
 *  1. Vào ròng/Rút ròng, Dòng tiền vào, Dòng tiền ra  (kỳ tra cứu)
 *  2. Vào ròng/Rút ròng (YTD)                         (từ 01/01 đến hết kỳ tra cứu)
 *  3. % so với kỳ trước của: Vào ròng/Rút ròng, Dòng tiền vào, Dòng tiền ra --> % = (kỳ này - kỳ trước) / kỳ trước * 100
=============================================================== */
WITH 
-- Tham số lọc kỳ -> Lấy ra ngày đại diện kỳ nửa tháng của kỳ đầu/cuối kỳ này, kỳ trước, kỳ đầu năm
period_bounds AS (
  SELECT
    p.*,
    CASE
      WHEN period_type IN ('D', 'HM') THEN (CASE WHEN DAYOFMONTH(current_start) = 1 THEN DATE_ADD(current_start, 15) ELSE ADD_MONTHS(TRUNC(current_start, 'MM'), 1) END)
      WHEN period_type = 'M' THEN ADD_MONTHS(current_start, 1)
      WHEN period_type = 'Q' THEN ADD_MONTHS(current_start, 3)
      WHEN period_type = 'Y' THEN ADD_MONTHS(current_start, 12)
    END AS current_end, -- Ngày đại diện cho kỳ kết thúc kỳ này
    CASE
      WHEN period_type IN ('D', 'HM') THEN CASE WHEN DAYOFMONTH(current_start) = 1 THEN DATE_ADD(ADD_MONTHS(current_start, -1), 15) ELSE TRUNC(current_start, 'MM') END
      WHEN period_type = 'M' THEN ADD_MONTHS(current_start, -1)
      WHEN period_type = 'Q' THEN ADD_MONTHS(current_start, -3)
      WHEN period_type = 'Y' THEN ADD_MONTHS(current_start, -12)
    END AS previous_start, -- Ngày đại diện kỳ nửa tháng đầu kỳ trước
    TRUNC(current_start, 'YEAR') AS ytd_start -- Ngày đại diện cho kỳ bắt đầu năm
  FROM (
    SELECT
      :period_type AS period_type,
      :period_code AS period_code,
      CASE
        WHEN period_type = 'HM' THEN DATE_ADD(TO_DATE(CONCAT(SUBSTR(period_code, 1, 7), '-01')), CASE WHEN RIGHT(period_code, 1) = '1' THEN 0 ELSE 15 END)
        WHEN period_type = 'M'  THEN TO_DATE(CONCAT(period_code, '-01'))
        WHEN period_type = 'Q'  THEN ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(period_code, 1, 4), '-01-01')), (CAST(RIGHT(period_code, 1) AS INT) - 1) * 3)
        WHEN period_type = 'Y'  THEN TO_DATE(CONCAT(period_code, '-01-01'))
    END AS current_start -- Ngày đại diện cho kỳ bắt đầu kỳ này
  ) p
)
-- Dữ liệu báo cáo dòng tiền (PLIV-TT51)
, report_data AS (
  -- B2. Lọc trùng dữ liệu, lấy file báo cáo mới nhất của từng đối tượng trong kỳ
  SELECT v2.*
  FROM (
    -- B1. Dữ liệu từ bảng dãn phẳng báo cáo dòng tiền (PLIV-TT51)
    -- Lấy ra thông tin kỳ Nửa tháng/Tháng/Quý/Năm + ngày đại diện cho kỳ nửa tháng (H1 ngày 01; H2 ngày 16); Tháng/năm lấy từ day_report, H1/H2 lấy từ period_value
    SELECT
      --DATE_ADD(TRUNC(day_report, 'MM'), CASE WHEN CAST(SUBSTR(period_value,3,2) AS INT) <= 15 THEN 0 ELSE 15 END) AS halfmonth_date,
      DATE_ADD(TRUNC(day_report, 'MM'), MAP('DT',0,'CT',15)[SUBSTR(period_value,1,2)]) AS halfmonth_date,
      --Comment 4 field dưới do không dùng nữa
      --DATE_FORMAT(day_report, 'yyyy-MM') AS month_code,
      --CONCAT(DATE_FORMAT(day_report, 'yyyy-MM'), '-H', IF(CAST(SUBSTR(period_value,3,2) AS INT) <= 15, '1', '2')) AS half_month_code,
      --CONCAT(CAST(YEAR(day_report) AS STRING), '-Q', CAST(QUARTER(day_report) AS STRING)) AS quarter_code,
      --CAST(year_value AS STRING) AS year_code,
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
      DENSE_RANK() OVER(PARTITION BY object_name, year_value, period_value ORDER BY day_report DESC, ngay_nop DESC, report_log_id DESC) rk -- Lọc trùng của cùng kỳ theo ngày bc x ngày nộp x id báo cáo
    FROM uat_fims_ods.fir_value v
    WHERE report_code = 'IBOU9'
      AND period_type = 'NUA_THANG'
      AND row_path = 'Tổng= (1) + (2)'
      AND column_path IN (
          'Giá trị dòng vốn vào trong kỳ báo cáo (+/-) (đơn vị USD)',
          'Tổng giá trị ngoại tệ đổi sang VND trong kỳ báo cáo (đơn vị USD)',
          'Tổng giá trị VND đổi ra ngoại tệ và chuyển ra trong kỳ báo cáo (đơn vị USD)'
      )
      AND object_name = 'HSBC'
      AND period_value = 'CT07/2026'
  ) v2
  WHERE rk = 1
)
-- TỔNG HỢP DỮ LIỆU LÊN BIỂU ĐỒ
SELECT 
  t.*,
  (period_cur_value - period_prev_value) / NULLIF(period_prev_value, 0) * 100.0 AS current_vs_prev_pct -- So với kỳ trước
FROM (
  SELECT
    p.period_type,
    p.period_code,
    CASE column_path
      WHEN 'Giá trị dòng vốn vào trong kỳ báo cáo (+/-) (đơn vị USD)' THEN 'Vào ròng/Rút ròng'
      WHEN 'Tổng giá trị ngoại tệ đổi sang VND trong kỳ báo cáo (đơn vị USD)' THEN 'Dòng tiền vào'
      WHEN 'Tổng giá trị VND đổi ra ngoại tệ và chuyển ra trong kỳ báo cáo (đơn vị USD)' THEN 'Dòng tiền ra'
    END AS metric,
    --m.sort_order,
    SUM(CASE WHEN d.halfmonth_date >= p.current_start  AND d.halfmonth_date <  p.current_end   THEN d.value END) AS period_cur_value,  -- Số kỳ này
    SUM(CASE WHEN d.halfmonth_date >= p.previous_start AND d.halfmonth_date <  p.current_start THEN d.value END) AS period_prev_value, -- Số kỳ trước
    SUM(CASE WHEN d.halfmonth_date >= p.ytd_start      AND d.halfmonth_date <  p.current_end   THEN d.value END) AS ytd_value          -- Số từ đầu năm đến kỳ này
  FROM report_data d 
  CROSS JOIN period_bounds p -- Thông tin ngày đại diện kỳ nửa tháng của kỳ bắt đầu/kết thúc kỳ này, ngày đại diện kỳ bắt đầu của kỳ trước và kỳ bắt đầu năm để lọc dữ liệu
  WHERE d.halfmonth_date >= LEAST(p.previous_start, p.ytd_start) -- Chặn dưới: MIN(Ngày đại diện cho Kỳ bắt đầu kỳ trước, Ngày đại diện cho Kỳ bắt đầu năm)
    AND d.halfmonth_date <  p.current_end -- Chặn trên: Kỳ kết thúc của kỳ này
  GROUP BY period_type, period_code, metric
) t
;