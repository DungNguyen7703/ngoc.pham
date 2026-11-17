-- BÁO CÁO THƯỜNG NIÊN >> ĐẤU GIÁ
---- Tham số tra cứu: Từ năm (fromyear), Đến năm (toyear)
WITH 
-- Dữ liệu tổng hợp theo năm x loại hình
data_agg AS (
-- Bước 3. Tính tổng giá trị theo Nhóm Loại hình đấu giá x Năm
SELECT 
  report_year,
  CASE 
    WHEN TRIM(loai_hinh_dau_gia) IN ('Cổ phần hóa') THEN 'IPO'
    WHEN TRIM(loai_hinh_dau_gia) IN (
        'Bán phần vốn Nhà nước', 'Bán phần vốn Nhà nước (chào bán cạnh tranh)', 'Bán phần vốn Nhà nước (Đấu giá cả lô cổ phần)', 
        'Đấu giá phần góp vốn', 'Thoái phần vốn nhà nước', 'Chào bán cạnh tranh cả lô cổ phần (Bán phần vốn Nhà nước)')
      THEN 'Thoái vốn'
    WHEN TRIM(loai_hinh_dau_gia) IN ('Bán phần vốn Nhà nước (Đấu giá quyền mua cổ phiếu)', 'Bán CP ra công chúng của cổ đông lớn theo giấy phép UBCK', 'Bán CP ra công chúng theo giấy phép UBCK')
      THEN 'Phát hành ra công chúng / quyền mua'
    ELSE 'Khác'
  END nhom_loai_hinh_dau_gia,
  COUNT(row_num) so_dot_dau_gia,
  SUM(gt_trunggia_ndttrongnuoc) + SUM(gt_trunggia_ndtnuocngoai) AS tong_gia_tri_trung_gia
FROM (
  -- Bước 2. Chuyển dòng thành các cột riêng biệt
  SELECT 
    report_code,
    report_year,
    report_month,
    row_num,
    MAX(loai_hinh_dau_gia) AS loai_hinh_dau_gia,
    SUM(COALESCE(CAST(gt_trunggia_ndttrongnuoc AS DECIMAL(38,10)), 0)) AS gt_trunggia_ndttrongnuoc,
    SUM(COALESCE(CAST(gt_trunggia_ndtnuocngoai AS DECIMAL(38,10)), 0)) AS gt_trunggia_ndtnuocngoai  
  FROM (
    -- Bước 1: Chuẩn bị dữ liệu và chuẩn hóa tên cột
    SELECT 
      f.report_code,
      f.report_year,
      f.report_month,
      f.row_num,
      --TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) AS metric_name,
      CASE
        WHEN TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) = 'LOẠI HÌNH ĐẤU GIÁ' THEN 'LOAI_HINH_DAU_GIA'
        WHEN TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) IN ('GIÁ TRỊ CP TRÚNG GIÁ > NĐT TRONG NƯỚC (VND)', 'GIÁ TRỊ CP TRÚNG GIÁ(VND) > NĐT TRONG NƯỚC') THEN 'GT_TRUNGGIA_NDTTRONGNUOC'
        WHEN TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) IN ('GIÁ TRỊ CP TRÚNG GIÁ > NĐT NƯỚC NGOÀI (VND)', 'GIÁ TRỊ CP TRÚNG GIÁ(VND) > NĐT NƯỚC NGOÀI') THEN 'GT_TRUNGGIA_NDTNUOCNGOAI'
      END metric_name_cd,
      f.field_value
    FROM uat_iss_ods.flat_report f
    WHERE f.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
      AND f.submit_source = 'ICP'
      AND (
        (
          f.report_code = 'HNX05' AND f.sheet_name = 'sheet 1'
          AND TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) IN ('LOẠI HÌNH ĐẤU GIÁ', 'GIÁ TRỊ CP TRÚNG GIÁ > NĐT TRONG NƯỚC (VND)', 'GIÁ TRỊ CP TRÚNG GIÁ > NĐT NƯỚC NGOÀI (VND)')
        )
        OR
        (
          f.report_code = 'HSX03' AND f.sheet_name = 'sheet 1'
          AND TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) IN ('LOẠI HÌNH ĐẤU GIÁ', 'GIÁ TRỊ CP TRÚNG GIÁ(VND) > NĐT TRONG NƯỚC', 'GIÁ TRỊ CP TRÚNG GIÁ(VND) > NĐT NƯỚC NGOÀI')
        )
      ) 
      AND f.report_year BETWEEN :fromyear AND :toyear
      --AND f.report_year = '2022' AND f.report_month = '5'
      AND f.ds_snpst_dt = '2026-10-22'
  ) f2
  PIVOT (
    MAX(field_value)
    FOR metric_name_cd IN (
        'LOAI_HINH_DAU_GIA'        AS loai_hinh_dau_gia,
        'GT_TRUNGGIA_NDTTRONGNUOC' AS gt_trunggia_ndttrongnuoc,
        'GT_TRUNGGIA_NDTNUOCNGOAI' AS gt_trunggia_ndtnuocngoai
    )
  )
  GROUP BY report_code, report_year, report_month, row_num
) f3
GROUP BY 
  report_year, 
  (CASE 
    WHEN TRIM(loai_hinh_dau_gia) IN ('Cổ phần hóa') THEN 'IPO'
    WHEN TRIM(loai_hinh_dau_gia) IN (
        'Bán phần vốn Nhà nước', 'Bán phần vốn Nhà nước (chào bán cạnh tranh)', 'Bán phần vốn Nhà nước (Đấu giá cả lô cổ phần)', 
        'Đấu giá phần góp vốn', 'Thoái phần vốn nhà nước', 'Chào bán cạnh tranh cả lô cổ phần (Bán phần vốn Nhà nước)')
      THEN 'Thoái vốn'
    WHEN TRIM(loai_hinh_dau_gia) IN ('Bán phần vốn Nhà nước (Đấu giá quyền mua cổ phiếu)', 'Bán CP ra công chúng của cổ đông lớn theo giấy phép UBCK', 'Bán CP ra công chúng theo giấy phép UBCK')
      THEN 'Phát hành ra công chúng / quyền mua'
    ELSE 'Khác'
  END)
)
-- TỔNG HỢP LÊN BIỂU ĐỒ
---- Số liệu tổng theo năm x loại hình
SELECT report_year, nhom_loai_hinh_dau_gia, so_dot_dau_gia, tong_gia_tri_trung_gia
FROM data_agg 
UNION ALL
---- Số liệu tổng theo năm
SELECT report_year, 'Tổng' nhom_loai_hinh_dau_gia, SUM(so_dot_dau_gia) AS so_dot_dau_gia, SUM(tong_gia_tri_trung_gia) AS tong_gia_tri_trung_gia
FROM data_agg 
GROUP BY report_year
ORDER BY report_year, nhom_loai_hinh_dau_gia
;