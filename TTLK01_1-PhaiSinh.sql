WITH 
-- Dữ liệu tổng hợp từ báo cáo
group_totals AS (
  SELECT 
    report_year, report_month, column_path, value
  FROM (
    -- Tính tổng riêng hai nhóm: TVLK NULL và TVLK NOT NULL 
    ----> Nếu có dòng Tổng (TVLK NULL) thì lấy dòng Tổng, không có thì lấy dòng chi tiết (TVLK NOT NULL)
    SELECT 
      report_year, 
      report_month, 
      column_path, 
      SUM(NVL(value, 0)) value,
      IF(tvlk IS NULL, 0, 1) AS tvlk_group,
      ROW_NUMBER() OVER(PARTITION BY report_year, report_month, column_path ORDER BY IF(tvlk IS NULL, 0, 1)) rn -- Nhóm NULL = 0 (Tổng) ưu tiên trước nhóm NOT NULL = 1 (Chi tiết TTLK) 
    FROM (
      SELECT
        report_year, report_month, row_num, column_path,
        MAX(ma_tvlk) OVER (PARTITION BY report_year, report_month, row_num) AS tvlk,
        value
      FROM (
        -- Dữ liệu báo cáo TTLK01_1 (Tài khoản Phái sinh)
        SELECT
            f.report_year,
            f.report_month,
            f.row_num,
            f.column_path,
            IF(f.column_path = 'TVLK', NULLIF(f.field_value, ''), NULL) AS ma_tvlk,
            IF(f.column_path <> 'TVLK', TRY_CAST(NULLIF(f.field_value, '') AS DOUBLE), NULL) AS value
          FROM uat_iss_ods.flat_report f
          WHERE f.report_code = 'TTLK01'
            AND f.sheet_name = 'Sheet 1'
            AND f.submit_source = 'ICP'
            AND f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
            AND f.date_type = 'MONTHLY'
            AND f.report_year = :report_year
            AND f.report_month = :report_month
      ) 
    ) 
    WHERE column_path NOT IN ('STT','TVLK')
    GROUP BY report_year, report_month, IF(tvlk IS NULL, 0, 1), column_path
  ) WHERE rn = 1
)
SELECT * FROM group_totals
ORDER BY column_path
;
-- Xoay thành bảng dữ liệu giống báo cáo để tính tổng
, row_data AS (
  SELECT *
  FROM (
    -- Đưa TVLK về cùng hàng với các chỉ tiêu trước khi pivot.
    SELECT
      report_year,
      report_month,
      row_num,
      column_path,
      numeric_value,
      MAX(ma_tvlk) OVER (PARTITION BY report_year, report_month, row_num) AS tvlk
    FROM source_data
  )
  PIVOT (
    MAX(numeric_value) FOR column_path IN (
      'SỐ LƯỢNG ĐẦU KỲ > TRONG NƯỚC > CN' AS dk_trongnuoc_cn,
      'SỐ LƯỢNG ĐẦU KỲ > TRONG NƯỚC > TC' AS dk_trongnuoc_tc,
      'SỐ LƯỢNG ĐẦU KỲ > NƯỚC NGOÀI > CN' AS dk_nuocngoai_cn,
      'SỐ LƯỢNG ĐẦU KỲ > NƯỚC NGOÀI > TC' AS dk_nuocngoai_tc,
      'SỐ LƯỢNG MỞ TRONG KỲ > TRONG NƯỚC > CN' AS tk_trongnuoc_cn_mo,
      'SỐ LƯỢNG MỞ TRONG KỲ > TRONG NƯỚC > TC' AS tk_trongnuoc_tc_mo,
      'SỐ LƯỢNG MỞ TRONG KỲ > NƯỚC NGOÀI > CN' AS tk_nuocngoai_cn_mo,
      'SỐ LƯỢNG MỞ TRONG KỲ > NƯỚC NGOÀI > TC' AS tk_nuocngoai_tc_mo,
      'SỐ LƯỢNG ĐÓNG TRONG KỲ > TRONG NƯỚC > CN' AS tk_trongnuoc_cn_dong,
      'SỐ LƯỢNG ĐÓNG TRONG KỲ > TRONG NƯỚC > TC' AS tk_trongnuoc_tc_dong,
      'SỐ LƯỢNG ĐÓNG TRONG KỲ > NƯỚC NGOÀI > CN' AS tk_nuocngoai_cn_dong,
      'SỐ LƯỢNG ĐÓNG TRONG KỲ > NƯỚC NGOÀI > TC' AS tk_nuocngoai_tc_dong,
      'SỐ LƯỢNG CUỐI KỲ > TRONG NƯỚC > CN' AS ck_trongnuoc_cn,
      'SỐ LƯỢNG CUỐI KỲ > TRONG NƯỚC > TC' AS ck_trongnuoc_tc,
      'SỐ LƯỢNG CUỐI KỲ > NƯỚC NGOÀI > CN' AS ck_nuocngoai_cn,
      'SỐ LƯỢNG CUỐI KỲ > NƯỚC NGOÀI > TC' AS ck_nuocngoai_tc
    )
  )
)
-- 3. Tính tổng riêng hai nhóm: TVLK NULL và TVLK NOT NULL.
group_totals AS (
    SELECT
        report_year,
        report_month,
        IF(tvlk IS NULL, 0, 1) AS tvlk_group,
        COUNT(*) AS row_count,
        SUM(TRY_CAST(begin_dom_cn AS DECIMAL(38, 0))) AS begin_dom_cn,
        SUM(TRY_CAST(begin_dom_tc AS DECIMAL(38, 0))) AS begin_dom_tc,
        SUM(TRY_CAST(begin_for_cn AS DECIMAL(38, 0))) AS begin_for_cn,
        SUM(TRY_CAST(begin_for_tc AS DECIMAL(38, 0))) AS begin_for_tc,
        SUM(TRY_CAST(open_dom_cn AS DECIMAL(38, 0))) AS open_dom_cn,
        SUM(TRY_CAST(open_dom_tc AS DECIMAL(38, 0))) AS open_dom_tc,
        SUM(TRY_CAST(open_for_cn AS DECIMAL(38, 0))) AS open_for_cn,
        SUM(TRY_CAST(open_for_tc AS DECIMAL(38, 0))) AS open_for_tc,
        SUM(TRY_CAST(close_dom_cn AS DECIMAL(38, 0))) AS close_dom_cn,
        SUM(TRY_CAST(close_dom_tc AS DECIMAL(38, 0))) AS close_dom_tc,
        SUM(TRY_CAST(close_for_cn AS DECIMAL(38, 0))) AS close_for_cn,
        SUM(TRY_CAST(close_for_tc AS DECIMAL(38, 0))) AS close_for_tc,
        SUM(TRY_CAST(end_dom_cn AS DECIMAL(38, 0))) AS end_dom_cn,
        SUM(TRY_CAST(end_dom_tc AS DECIMAL(38, 0))) AS end_dom_tc,
        SUM(TRY_CAST(end_for_cn AS DECIMAL(38, 0))) AS end_for_cn,
        SUM(TRY_CAST(end_for_tc AS DECIMAL(38, 0))) AS end_for_tc
    FROM row_data
    GROUP BY report_year, report_month, IF(tvlk IS NULL, 0, 1)
),