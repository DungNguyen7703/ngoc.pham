-- =====================================================================================
-- [23] TÌNH HÌNH HUY ĐỘNG VỐN QUA PHÁT HÀNH CỔ PHIẾU - CHỈ TIÊU TỔNG HỢP
-- Nguồn: IDS (CTĐC) + SCMS (CTCK) + FMS (CTQLQ)
-- Tham số:
--   :period_type -> D (Ngày) | M (Tháng) | Q (Quý) | Y (Năm)
--   :period_to   -> Ngày 'yyyy-MM-dd' | Tháng 'yyyy-MM' | Quý 'yyyy-Q[1-4]' | Năm 'yyyy'
-- Lọc kỳ theo Ngày GCN/CV. Số đợt = số GCN/CV. Chỉ lấy huy động vốn và loại chứng khoán CP.
-- Kết quả: mỗi dòng = 1 chỉ tiêu x nhóm; Đăng ký / Thành công, kỳ này / kỳ trước, % so kỳ trước.
-- =====================================================================================
WITH
-- ===============================================
-- 0. THAM SỐ KỲ BÁO CÁO
-- ===============================================
params AS (
  SELECT 
    period_type,
    period_to, -- Kỳ này
    period_to_startdate, -- Ngày đầu kỳ này
    CASE 
      WHEN period_type = 'D' THEN period_to_startdate
      WHEN period_type IN ('M','Q','Y') THEN DATE_SUB(ADD_MONTHS(period_to_startdate, MAP('M',1,'Q',3,'Y',12)[period_type]), 1)
    END AS period_to_enddate, -- Ngày cuối kỳ này
    CASE 
      WHEN period_type = 'D' THEN DATE_SUB(period_to_startdate, 1)
      WHEN period_type IN ('M','Q','Y') THEN ADD_MONTHS(period_to_startdate, MAP('M',-1,'Q',-3,'Y',-12)[period_type])
    END AS period_prev_startdate -- Ngày đầu kỳ trước
  FROM (
    SELECT
      :period_type AS period_type, -- Loại kỳ
      :period_to AS period_to, -- Kỳ
      CAST(CASE :period_type
        WHEN 'D' THEN :period_to
        WHEN 'M' THEN CONCAT(:period_to, '-01')
        WHEN 'Q' THEN CONCAT(SUBSTR(:period_to, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
        WHEN 'Y' THEN CONCAT(:period_to, '-01-01')
      END AS DATE) AS period_to_startdate -- Ngày đầu kỳ này
  ) t
)
-- Điều kiện lọc kỳ này, kỳ trước
, periods AS (
  SELECT 'CURRENT' AS period_key, period_to_startdate AS startdate, period_to_enddate AS enddate FROM params -- Kỳ này
  UNION ALL
  SELECT 'PREVIOUS' AS period_key, period_prev_startdate AS startdate, DATE_SUB(period_to_startdate, 1) AS enddate FROM params -- Kỳ trước
)
-- ===============================================
-- 1. DỮ LIỆU CHÀO BÁN PHÁT HÀNH CỦA PHÂN HỆ IDS - CÔNG TY ĐẠI CHÚNG
-- ===============================================
-- Thông tin chấp thuận đăng ký chào bán
, ids_so_certificate AS (
  SELECT
    o.id AS securities_offering_id,
    c.business_reg_no, c.equity_ticker,
    COALESCE(cat.industry_cd, 'NA') AS industry_cd, COALESCE(cat.industry_name, 'Chưa phân ngành') AS industry_name,
    o.application_cd, o.administrative_proc_cd, v1.lookup_value_vn AS administrative_proc,
    o.applicant_type_flg, o.legal_entity_id,
    o.certificate_no, o.certificate_date, o.official_letter_no, o.official_letter_date, o.multi_turn_flg,
    o.total_registered_qty, o.total_expected_am,
    o.administrative_status_cd, v2.lookup_value_vn AS administrative_status,
    o.approval_status_cd, v3.lookup_value_vn AS approval_status
  FROM uat_ids_stg.securities_offering o
  LEFT JOIN uat_ids_stg.lookup_values v1 ON v1.lookup_group = 'SO_ADMINISTRATIVE_PROCEDURE' AND v1.lookup_cd = o.administrative_proc_cd AND v1.ds_snpst_dt = '2026-11-07' -- TTHC
  LEFT JOIN uat_ids_stg.lookup_values v2 ON v2.lookup_group = 'SO_ADMINISTRATIVE_STATUS' AND v2.lookup_cd = o.administrative_status_cd AND v2.ds_snpst_dt = '2026-11-07' -- Trạng thái TTHC
  LEFT JOIN uat_ids_stg.lookup_values v3 ON v3.lookup_group = 'SO_APPROVAL_STATUS' AND v3.lookup_cd = o.approval_status_cd AND v3.ds_snpst_dt = '2026-11-07' -- Trạng thái chấp thuận / duyệt đăng ký
  LEFT JOIN uat_ids_stg.company_profiles c ON c.id = o.company_profile_id AND c.ds_snpst_dt = '2026-11-07' -- Thông tin Công ty đại chúng
  LEFT JOIN uat_ids_stg.categories cat ON cat.id = c.category_l1_id AND cat.ds_snpst_dt = '2026-11-07' -- Thông tin phân ngành cấp 1
  WHERE o.delete_flg = '0'
    AND o.administrative_status_cd = '022' -- Duyệt TTHC
    AND o.approval_status_cd = 'APPROVED'  -- Duyệt chấp thuận đăng ký chào bán
    AND o.ds_snpst_dt = '2026-11-07'
)
-- Kế hoạch (Gộp theo đăng ký chào bán (securities_offering_id) x Hình thức phát hành (offering_method_cd + security_name))
, ids_so_plan AS (
  -- Bước 2. Tổng theo ĐKCB x Hình thức
  SELECT
    securities_offering_id,
    security_type_cd, security_type,
    offering_method_cd, offering_method, security_name,
    par_value, offering_price,
    SUM(plan_total_registered_qty) AS plan_total_registered_qty,
    SUM(plan_total_expected_am_orig) AS plan_total_expected_am_orig,
    SUM(plan_total_expected_am) AS plan_total_expected_am
  FROM (
    -- Bước 1. Chi tiết kế hoạch
    SELECT
      p.securities_offering_id, P.security_type_cd, v5.lookup_value_vn AS security_type,
      P.offering_method_cd, v4.lookup_value_vn AS offering_method,
      P.security_name,
      p.par_value, p.offering_price,
      p.total_registered_qty AS plan_total_registered_qty,
      p.total_expected_am AS plan_total_expected_am_orig,
      (CASE
        WHEN NVL(p.offering_price, 0) = 0 THEN p.par_value * p.total_registered_qty
        ELSE p.total_expected_am
      END) AS plan_total_expected_am
    FROM uat_ids_stg.securities_offering_plan p
    LEFT JOIN uat_ids_stg.lookup_values v4 ON v4.lookup_group = 'SO_OFFERING_METHOD' AND v4.lookup_cd = P.offering_method_cd AND v4.ds_snpst_dt = '2026-11-07' -- Hình thức chào bán
    LEFT JOIN uat_ids_stg.lookup_values v5 ON v5.lookup_group = 'SO_SECURITY_TYPE' AND v5.lookup_cd = P.security_type_cd AND v5.ds_snpst_dt = '2026-11-07' -- Loại CK
    WHERE p.ds_snpst_dt = '2026-11-08'
  )
  GROUP BY securities_offering_id, security_type_cd, security_type, offering_method_cd, offering_method, security_name, par_value, offering_price
)
-- Kết quả (Gộp theo đăng ký chào bán (securities_offering_id) x Hình thức phát hành (offering_method_cd))
, ids_so_result AS (
  -- Tổng theo ĐKCB x Hình thức
  SELECT
    securities_offering_id, result_report_date, offering_end_date, offering_method_cd, offering_method, has_result,
    SUM(total_successful_qty) AS total_successful_qty,
    SUM(total_collected_am) AS total_collected_am
  FROM (
    -- Bước 1. Chi tiết kết quả
    SELECT
      R.securities_offering_id, R.result_report_date, R.offering_end_date,
      R.offering_method_cd, v6.lookup_value_vn AS offering_method,
      R.total_successful_qty, R.actual_offering_price, R.total_collected_am,
      IF(R.total_successful_qty IS NOT NULL, 'Y', 'N') AS has_result
    FROM uat_ids_stg.securities_offering_result R
    LEFT JOIN uat_ids_stg.lookup_values v6 ON v6.lookup_group = 'SO_OFFERING_METHOD' AND v6.lookup_cd = R.offering_method_cd AND v6.ds_snpst_dt = '2026-11-07' -- Hình thức chào bán
    WHERE R.approval_status_cd = 'APPROVED'
      AND R.delete_flg = '0'
      AND R.ds_snpst_dt = '2026-11-08'
  )
  GROUP BY securities_offering_id, result_report_date, offering_end_date, offering_method_cd, offering_method, has_result
)
-- Kết quả chào bán: Tính bổ sung số tiền thực tế -> Lấy giá bán offering_price từ plan (nếu không có thì lấy Mệnh giá par_value) * KL phát hành thực tế
, ids_so_result_cal AS (
  SELECT
    r.securities_offering_id, r.result_report_date, r.offering_end_date, r.offering_method_cd, r.offering_method,
    r.total_successful_qty,
    r.total_collected_am AS total_collected_am_orig,
    CASE
      WHEN NVL(r.total_collected_am, 0) = 0 THEN (CASE WHEN NVL(p.offering_price, 0) = 0 THEN p.par_value ELSE p.offering_price END) * r.total_successful_qty
      ELSE total_collected_am
    END total_collected_am,
    r.has_result
  FROM ids_so_result r
  LEFT JOIN ids_so_plan p ON R.securities_offering_id = p.securities_offering_id AND R.offering_method_cd = p.offering_method_cd 
)
-- Gộp dữ liệu đăng ký + kế hoạch + kết quả và map nhóm hình thức phát hành
, ids_offering_data AS (
  SELECT
    'CTĐC' AS doituong, -- Đối tượng phát hành
    s.securities_offering_id, -- Khóa hồ sơ đăng ký chào bán (1 hồ sơ = 1 đợt)
    s.business_reg_no, s.equity_ticker,
    s.industry_cd, s.industry_name, -- Ngành
    NVL(s.certificate_no, s.official_letter_no) AS cert_no,
    NVL(s.certificate_date, s.official_letter_date) AS cert_date, -- Ngày GCN/CV
    s.administrative_proc_cd, s.administrative_proc, 
    s.security_type_cd, s.security_type, s.offering_method_cd, s.offering_method,
    m.offering_method_group, -- Nhóm hình thức phát hành
    m.is_raising_capital, -- Có phải huy động vốn không
    -- Kế hoạch -- Không lấy am_orig
    s.plan_total_registered_qty, s.plan_total_expected_am,
    -- Kết quả -- Không lấy am_orig
    s.result_report_date, s.offering_end_date, s.total_successful_qty, s.total_collected_am, s.has_result
  FROM (
    -- Gộp dữ liệu đăng ký + kế hoạch + kết quả
    SELECT
      o.*,
      p.security_type_cd, p.security_type,
      p.offering_method_cd, p.offering_method, p.security_name,
      p.plan_total_registered_qty,
      p.plan_total_expected_am,
      r.result_report_date, r.offering_end_date,
      r.total_successful_qty,
      r.total_collected_am, 
      r.has_result
    FROM ids_so_certificate o
    LEFT JOIN ids_so_plan p ON o.securities_offering_id = p.securities_offering_id
    LEFT JOIN ids_so_result_cal r ON o.securities_offering_id = r.securities_offering_id
      AND p.securities_offering_id = r.securities_offering_id AND p.offering_method_cd = r.offering_method_cd
  ) s
  LEFT JOIN (
    SELECT * FROM VALUES
      -- Mapping nhóm hình thức phát hành + có huy động vốn không: theo offering_method_cd và security_name [chỉ dùng cho offering_method_cd='9']
      ('1',  'Chào bán cho cổ đông hiện hữu',                       CAST(NULL AS STRING), 'Phát hành ra công chúng',                          'Y'),
      ('2',  'Đấu giá',                                             CAST(NULL AS STRING), 'Phát hành ra công chúng',                          'Y'),
      ('3',  'Chào bán ra công chúng theo hình thức khác',          CAST(NULL AS STRING), 'Phát hành ra công chúng',                          'Y'),
      ('4',  'Chào bán của cổ đông công ty đại chúng ra công chúng',CAST(NULL AS STRING), 'Phát hành ra công chúng',                          'N'),
      ('5',  'Chào bán riêng lẻ',                                   CAST(NULL AS STRING), 'Phát hành riêng lẻ',                               'Y'),
      ('6',  'Hoán đổi',                                            CAST(NULL AS STRING), 'Phát hành để hoán đổi/sáp nhập',                   'N'),
      ('7',  'Phát hành trả cổ tức',                                CAST(NULL AS STRING), 'Phát hành để trả cổ tức, tăng vốn từ vốn CSH',     'Y'),
      ('8',  'Phát hành cổ phiếu từ nguồn vốn CSH',                 CAST(NULL AS STRING), 'Phát hành để trả cổ tức, tăng vốn từ vốn CSH',     'Y'),
      ('9',  'Phát hành cổ phiếu cho người lao động', 'Phát hành cho người lao động (ESOP)', 'ESOP',                                          'Y'),
      ('9',  'Phát hành cổ phiếu cho người lao động', 'Phát hành thưởng cho người lao động', 'ESOP',                                          'N'),
      ('10', 'Phát hành cổ phiếu thưởng cho người lao động',        CAST(NULL AS STRING), 'ESOP',                                             'N'),
      ('11', 'Chào bán trái phiếu giao dịch quốc tế',               CAST(NULL AS STRING), 'Khác',                                             'Y'),
      ('12', 'Phát hành cổ phiếu để chào mua công khai',            CAST(NULL AS STRING), 'Phát hành ra công chúng',                          'Y'),
      ('13', 'Chào bán thêm cổ phiếu ra công chúng',                CAST(NULL AS STRING), 'Phát hành ra công chúng',                          'Y'),
      ('14', 'Chào bán cổ phiếu ra nước ngoài',                     CAST(NULL AS STRING), 'Khác',                                             'Y'),
      ('15', 'Phát hành cổ phiếu mới làm cơ sở chào bán chứng chỉ lưu ký tại nước ngoài', CAST(NULL AS STRING), 'Khác',                       'Y')
    AS t(offering_method_cd, offering_method, security_name, offering_method_group, is_raising_capital)
  ) m
    ON  TRIM(s.offering_method_cd) = m.offering_method_cd
    AND TRIM(s.offering_method)    = m.offering_method
    AND (m.security_name IS NULL OR TRIM(s.security_name)  = m.security_name) -- Chỉ check điều kiện security_name nếu offering_method_cd = '9'
)
-- ===============================================
-- 2. DỮ LIỆU CHÀO BÁN PHÁT HÀNH CỦA PHÂN HỆ SCMS - CÔNG TY CHỨNG KHOÁN
-- ===============================================
-- Bước 1: parse 2 cột JSON (mảng object) thành array<struct>
, scms_src AS (
  SELECT
    i.code AS sc_firm_code, o.sc_firm_info_id, o.document_number, o.document_date, o.created_at, o.offering_date, o.end_date,
    o.total_offered_quantity, o.expected_total_amount,
    o.result_report_date, o.proceeds_collected, o.item_category,
    from_json(o.plan_json, 'array<struct<loaiChaoBan:string, soLuongCb:decimal(30,2), giaTriCbTheoMenhGia:decimal(30,2)>>') AS plan_arr,
    from_json(o.result_json, 'array<struct<loaiChaoBan:string, soLuongThucTe:decimal(30,2), giaTriThucTe:decimal(30,2)>>') AS result_arr,
    IF(o.result_json IS NOT NULL, 'Y', 'N') has_result -- Có kết quả chào bán chưa
  FROM uat_scms_stg.disclosure_securities_offering o
  LEFT JOIN uat_scms_stg.sc_firm_info i ON o.sc_firm_info_id = i.id AND i.ds_snpst_dt = '2026-11-06'
  WHERE o.ds_snpst_dt = '2026-11-07'
    AND NVL(o.document_date, o.created_at) IS NOT NULL
)
-- Bước 2: Explode plan; map result với plan có cùng loaiChaoBan trong cùng dòng
, scms_plan_x AS (
  SELECT
    s.*,
    p.loaiChaoBan,
    p.soLuongCb,
    p.giaTriCbTheoMenhGia,
    filter(s.result_arr, r -> r.loaiChaoBan = p.loaiChaoBan)[0] AS r
  FROM scms_src s
  LATERAL VIEW OUTER explode(s.plan_arr) px AS p
)
, scms_offering_data AS (
  -- Bước 3: Mapping nhóm hình thức + cờ huy động vốn
  SELECT
    'CTCK' AS doituong, -- Đối tượng phát hành
    x.sc_firm_code,
    x.document_number,
    NVL(x.document_date, TO_DATE(x.created_at)) AS cert_date, -- Ngày GCN/CV
    x.offering_date,
    x.end_date,
    x.item_category,
    x.loaiChaoBan AS method_code,
    m.method_name,
    m.offering_method_group, -- Nhóm hình thức phát hành
    m.is_raising_capital, -- Có phải huy động vốn không
    -- Thông tin kế hoạch
    x.soLuongCb,
    x.giaTriCbTheoMenhGia,
    -- Thông tin kết quả
    x.r.soLuongThucTe,
    x.r.giaTriThucTe,
    x.result_report_date,
    x.has_result
  FROM scms_plan_x x
  LEFT JOIN (
    SELECT * FROM VALUES
      ('CHAO_BAN_RA_CONG_CHUNG',   'Chào bán ra công chúng',             'Phát hành ra công chúng',                       'Y'),
      ('CO_PHIEU_THUONG',          'Cổ phiếu thưởng',                    'ESOP',                                          'N'),
      ('TRA_CO_TUC_BANG_CP',       'Trả cổ tức bằng CP',                 'Phát hành để trả cổ tức, tăng vốn từ vốn CSH',  'Y'),
      ('PHAT_HANH_CO_THU_TIEN',    'Phát hành có thu tiền',              'Phát hành ra công chúng',                       'Y'),
      ('DAU_GIA',                  'Đấu giá',                            'Phát hành ra công chúng',                       'Y'),
      ('CHAO_BAN_RIENG_LE',        'Chào bán riêng lẻ',                  'Phát hành riêng lẻ',                            'Y'),
      ('PHAT_HANH_CP_DE_HOAN_DOI', 'Phát hành CP để hoán đổi',           'Phát hành để hoán đổi/sáp nhập',                'N'),
      ('CO_DONG_LON_CHAO_BAN',     'Cổ đông lớn chào bán',               'Phát hành ra công chúng',                       'N'),
      ('CHU_SO_HUU_GOP_VON',       'Chủ sở hữu góp vốn',                 'Phát hành để trả cổ tức, tăng vốn từ vốn CSH',  'Y'),
      ('KHAC',                     'Khác',                               'Khác',                                          'Y'),
      ('PHAT_HANH_TP_QUOC_TE',     'Phát hành TP ra thị trường quốc tế', 'Khác',                                          'Y')
    AS t(method_code, method_name, offering_method_group, is_raising_capital)
  ) m ON x.loaiChaoBan = m.method_code
  WHERE x.offering_method IS NOT NULL -- Lọc dữ liệu lỗi
)
-- ===============================================
-- 3. DỮ LIỆU CHÀO BÁN PHÁT HÀNH CỦA PHÂN HỆ FMS - CÔNG TY QLQ
-- ===============================================
, fms_offering_data AS (
  SELECT
    'CTQLQ' AS doituong, -- Đối tượng phát hành
    s.code AS fmc_code,
    o.approval_document_no, o.approval_document_date, -- Ngày GCN/CV
    o.securities_type, p.method_code, m.method_name,
    m.offering_method_group, -- Nhóm hình thức phát hành
    m.is_raising_capital, -- Có phải huy động vốn không
    o.expected_start_date, o.expected_end_date, p.quantity_cb, p.value_cb, -- Thông tin kế hoạch
    o.report_result_date, p.actual_quantity_cb, p.actual_value_cb, -- Thông tin kết quả
    IF(o.report_result_date IS NOT NULL, 'Y', 'N') AS has_result
  FROM uat_fms_stg.offering o
  LEFT JOIN uat_fms_stg.offering_plan p ON o.id = p.offering_id AND p.ds_snpst_dt = '2026-11-07'
  LEFT JOIN uat_fms_stg.securities s ON o.sec_id = s.id AND s.ds_snpst_dt = '2026-11-07'
  LEFT JOIN (
    -- Map hình thức phát hành -> Nhóm hình thức
    SELECT * FROM VALUES
      ('01', 'Chào bán ra công chúng',   'Phát hành ra công chúng',                      'Y'),
      ('02', 'Cổ phiếu thưởng',          'ESOP',                                         'N'),
      ('03', 'Trả cổ tức bằng CP',       'Phát hành để trả cổ tức, tăng vốn từ vốn CSH', 'Y'),
      ('04', 'Phát hành có thu tiền',    'Phát hành ra công chúng',                      'Y'),
      ('05', 'Đấu giá',                  'Phát hành ra công chúng',                      'Y'),
      ('06', 'Chào bán riêng lẻ',        'Phát hành riêng lẻ',                           'Y'),
      ('07', 'Phát hành CP để hoán đổi', 'Phát hành để hoán đổi/sáp nhập',               'N'),
      ('08', 'Cổ đông lớn chào bán',     'Phát hành ra công chúng',                      'N'),
      ('09', 'Chủ sở hữu góp vốn',       'Phát hành để trả cổ tức, tăng vốn từ vốn CSH', 'Y'),
      ('10', 'Khác',                     'Khác',                                         'N')
    AS t(method_code, method_name, offering_method_group, is_raising_capital)
  ) m ON m.method_code = p.method_code
  WHERE o.deleted = '0'
    AND o.approval_document_date IS NOT NULL
    AND o.ds_snpst_dt = '2026-11-07'
)
-- ===============================================
-- 4. GỘP 3 PHÂN HỆ VỀ CÙNG CẤU TRÚC
--    offering_key: khóa đợt dùng để đếm số đợt phát hành theo GCN/CV cấp phép chào bán
--    LỌC: HUY ĐỘNG VỐN + CỔ PHIẾU + (KỲ NÀY | KỲ TRƯỚC) THEO NGÀY GCN/CV
-- ===============================================
, all_offering AS (
  SELECT p.period_key, a.*
  FROM (
    -- IDS - CTĐC
    SELECT
      d.doituong,
      concat_ws('|', d.doituong, business_reg_no, COALESCE(d.cert_no, '0'), CAST(d.cert_date AS STRING))) AS offering_key, -- Đợt = GCN/CV + mã số CTĐC
      d.cert_date,
      d.offering_method_group END AS method_group,
      d.is_raising_capital, d.security_type_cd,
      d.plan_total_registered_qty AS plan_qty,
      d.plan_total_expected_am AS plan_am,
      d.total_successful_qty AS result_qty,
      d.total_collected_am AS result_am,
      d.has_result
    FROM ids_offering_data d
    UNION ALL
    -- SCMS - CTCK
    SELECT
      d.doituong,
      -- Đợt = GCN/CV (số văn bản) + mã CTCK; văn bản thiếu số thì dùng documentdate/created_at
      concat_ws('|', 'CTCK', d.sc_firm_code, COALESCE(d.document_number, '0'), CAST(d.cert_date AS STRING))) AS offering_key, 
      d.cert_date,
      d.offering_method_group AS method_group,
      d.is_raising_capital,
			d.item_category,
      CAST(d.soLuongCb AS DECIMAL(30,2)) AS plan_qty,
      CAST(d.giaTriCbTheoMenhGia AS DECIMAL(30,2)) AS plan_am,
      CAST(d.soLuongThucTe AS DECIMAL(30,2)) AS result_qty,
      CAST(d.giaTriThucTe AS DECIMAL(30,2)) AS result_am,
      d.has_result
    FROM scms_offering_data d
    UNION ALL
    -- FMS - CTQLQ
    SELECT
      d.doituong,
      concat_ws('|', d.doituong, COALESCE(d.approval_document_no, '0'), CAST(d.approval_document_date AS STRING)) AS offering_key, -- Đợt = GCN/CV
      d.approval_document_date AS cert_date,
      d.offering_method_group AS method_group,
      d.method_code, d.method_name,
      d.is_raising_capital, d.securities_type,
      d.quantity_cb AS plan_qty,
      d.value_cb AS plan_am,
      d.actual_quantity_cb AS result_qty,
      d.actual_value_cb AS result_am,
      d.has_result
    FROM fms_offering_data d
  ) a
  JOIN periods p ON a.cert_date BETWEEN p.startdate AND p.enddate -- Lọc điều kiện ngày GCN/CV thuộc kỳ này, kỳ trước
  WHERE a.is_raising_capital = 'Y' -- Có phải huy động vốn không
	  AND a.security_type_cd = 'CP' -- Loại chứng khoán là "Cổ phiếu"
)
-- ===============================================
-- 5. TỔNG HỢP: GROUPING SETS -> mỗi nhóm hình thức + dòng TONG (tất cả hình thức)
--    dk = Đăng ký (kế hoạch) | tc = Thành công (kết quả) | kynay = kỳ báo cáo | kytruoc = kỳ trước
-- ===============================================
, metrics AS (
  SELECT
    CASE WHEN GROUPING(method_group) = 1 THEN 'TOTAL' ELSE 'METHOD_GROUP' END group_type,
    method_group,
    -- Số đợt (đếm theo GCN/CV): Đăng ký | Có kết quả chào bán
    COUNT(DISTINCT CASE WHEN period_key = 'CURRENT'  THEN dot_key END) AS sodot_dk_kynay,
    COUNT(DISTINCT CASE WHEN period_key = 'PREVIOUS' THEN dot_key END) AS sodot_dk_kytruoc,
    COUNT(DISTINCT CASE WHEN period_key = 'CURRENT'  AND has_result = 'Y' THEN dot_key END) AS sodot_tc_kynay,
    COUNT(DISTINCT CASE WHEN period_key = 'PREVIOUS' AND has_result = 'Y' THEN dot_key END) AS sodot_tc_kytruoc,
    -- Khối lượng phát hành
    COALESCE(SUM(CASE WHEN period_key = 'CURRENT'  THEN plan_qty   END), 0) AS kl_dk_kynay,
    COALESCE(SUM(CASE WHEN period_key = 'PREVIOUS' THEN plan_qty   END), 0) AS kl_dk_kytruoc,
    COALESCE(SUM(CASE WHEN period_key = 'CURRENT'  THEN result_qty END), 0) AS kl_tc_kynay,
    COALESCE(SUM(CASE WHEN period_key = 'PREVIOUS' THEN result_qty END), 0) AS kl_tc_kytruoc,
    -- Giá trị phát hành
    COALESCE(SUM(CASE WHEN period_key = 'CURRENT'  THEN plan_am    END), 0) AS gt_dk_kynay,
    COALESCE(SUM(CASE WHEN period_key = 'PREVIOUS' THEN plan_am    END), 0) AS gt_dk_kytruoc,
    COALESCE(SUM(CASE WHEN period_key = 'CURRENT'  THEN result_am  END), 0) AS gt_tc_kynay,
    COALESCE(SUM(CASE WHEN period_key = 'PREVIOUS' THEN result_am  END), 0) AS gt_tc_kytruoc
  FROM all_offering
  GROUP BY method_group GROUPING SETS ((method_group), ())
)
-- ===============================================
-- 7. KẾT QUẢ: giá trị kỳ này, kỳ trước (_kt) và % so với kỳ trước (_pct)
-- ===============================================
SELECT
  k.nhom, -- Nhóm hình thức phát hành (TONG = tất cả hình thức)
  k.sodot_dk_kynay,
  k.sodot_dk_kytruoc,
  (k.sodot_dk_kynay - k.sodot_dk_kytruoc) / NULLIF(k.sodot_dk_kytruoc, 0) * 100 AS sodot_dk_sskytruoc_pct,
  k.sodot_tc_kynay AS sodot_coketqua_kynay,
  k.sodot_tc_kytruoc AS sodot_coketqua_kytruoc,
  (k.sodot_tc_kynay - k.sodot_tc_kytruoc) / NULLIF(k.sodot_tc_kytruoc, 0) * 100 AS sodot_coketqua_sskytruoc_pct,
  k.kl_dk_kynay,
  k.kl_dk_kytruoc,
  (k.kl_dk_kynay - k.kl_dk_kytruoc) / NULLIF(k.kl_dk_kytruoc, 0) * 100 AS kl_dk_sskytruoc_pct,
  k.kl_tc_kynay,
  k.kl_tc_kytruoc,
  (k.kl_tc_kynay - k.kl_tc_kytruoc) / NULLIF(k.kl_tc_kytruoc, 0) * 100 AS kl_tc_sskytruoc_pct,
  k.gt_dk_kynay,
  k.gt_tc_kytruoc,
  (k.gt_dk_kynay - k.gt_tc_kytruoc) / NULLIF(k.gt_tc_kytruoc, 0) * 100 AS gt_tc_sskytruoc_pct,
  k.gt_tc_kynay,
  k.gt_tc_kytruoc,
  (k.gt_tc_kynay - k.gt_tc_kytruoc) / NULLIF(k.gt_tc_kytruoc, 0) * 100 AS gt_tc_sskytruoc_pct,
  p.period_to_startdate AS ngaydauky, 
	p.period_to_enddate AS ngaycuoiky, 
	p.period_prev_startdate AS ngaydaukytruoc, 
	DATE_SUB(p.period_to_startdate, 1) AS ngaycuoikytruoc
FROM metrics k
CROSS JOIN params p
ORDER BY CASE WHEN k.nhom = 'TONG' THEN 0 ELSE 1 END, k.nhom
;