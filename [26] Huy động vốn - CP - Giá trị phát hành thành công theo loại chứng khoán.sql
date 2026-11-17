-- [26] HUY ĐỘNG VỐN - GIÁ TRỊ PHÁT HÀNH THÀNH CÔNG THEO LOẠI CHỨNG KHOÁN (CP, TPDN niêm yết, TPDN riêng lẻ, TPCP), THEO THỜI GIAN
-- =======================================
-- Tham số:
--   :period_type -> M (Tháng) | Q (Quý) | Y (Năm)
--   :period_from, :period_to -> Từ kỳ, Đến kỳ: Tháng 'yyyy-MM' | Quý 'yyyy-Q[1-4]' | Năm 'yyyy'
-- CP, TPDN: Nguồn dữ liệu UB quản lý gồm IDS (CTĐC) + SCMS (CTCK) + FMS (CTQLQ). Lọc kỳ theo Ngày GCN/CV. Chỉ lấy huy động vốn. Loại chứng khoán: CP (Cổ phiếu), TP (Trái phiếu).
-- TPDN riêng lẻ, TPCP: Nguồn từ báo cáo chào bán của HNX
--    TPDN riêng lẻ (bảng uat_hnx_stg.private_corp_bond_offering): Số liệu lũy kế từ đầu năm đến cuối tháng báo cáo (report_month, report_year) -> Số phát sinh trong tháng = lũy kế tháng - lũy kế tháng liền trước cùng năm.
--    TPCP (bảng uat_hnx_stg.gov_bond_offering): Số liệu phát sinh trong tháng báo cáo -> lọc theo ngày phát hành (issue_date). GT phát hành = GT trúng thầu (winning_value).
-- Kết quả: Giá trị phát hành thành công (gt_tc) của từng loại chứng khoán theo từng kỳ (chỉ các kỳ có dữ liệu trong khoảng Từ kỳ - Đến kỳ)
--    Dòng TPDN: GT phát hành TPDN = TPDN (Nguồn dữ liệu UB quản lý) + TPDN riêng lẻ (TPDNRL Sở GDCK)
-- =======================================
WITH
-- =======================================
-- 0. THAM SỐ KỲ BÁO CÁO
-- =======================================
params AS (
  SELECT
    period_type,
    period_from, -- Từ kỳ
    period_to, -- Đến kỳ
    -- Ngày đầu của "Từ kỳ"
    CAST(CASE period_type
      WHEN 'M' THEN CONCAT(period_from, '-01')
      WHEN 'Q' THEN CONCAT(SUBSTR(period_from, 1, 4), '-', LPAD(CAST(CAST(SUBSTR(period_from, 7, 1) AS INT) * 3 - 2 AS STRING), 2, '0'), '-01')
      WHEN 'Y' THEN CONCAT(period_from, '-01-01')
    END AS DATE) AS period_from_startdate,
    -- Ngày cuối của "Đến kỳ"
    CAST(CASE period_type
      WHEN 'M' THEN CAST(LAST_DAY(TO_DATE(CONCAT(period_to, '-01'))) AS STRING)
      WHEN 'Q' THEN CAST(DATE_SUB(ADD_MONTHS(TO_DATE(CONCAT(SUBSTR(period_to, 1, 4), '-01-01')), CAST(SUBSTR(period_to, 7, 1) AS INT) * 3), 1) AS STRING)
      WHEN 'Y' THEN CONCAT(period_to, '-12-31')
    END AS DATE) AS period_to_enddate
  FROM (
    SELECT
      :period_type AS period_type, -- Loại kỳ: M | Q | Y
      :period_from AS period_from, -- Từ kỳ
      :period_to AS period_to -- Đến kỳ
  ) t
)
-- =======================================
-- 1. DỮ LIỆU CHÀO BÁN PHÁT HÀNH CỦA PHÂN HỆ IDS - CÔNG TY ĐẠI CHÚNG
-- =======================================
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
    offering_method_cd, offering_method_name, security_name,
    par_value, offering_price,
    SUM(plan_total_registered_qty) AS plan_total_registered_qty,
    SUM(plan_total_expected_am_orig) AS plan_total_expected_am_orig,
    SUM(plan_total_expected_am) AS plan_total_expected_am
  FROM (
    -- Bước 1. Chi tiết kế hoạch
    SELECT
      p.securities_offering_id, P.security_type_cd, v5.lookup_value_vn AS security_type,
      P.offering_method_cd, v4.lookup_value_vn AS offering_method_name,
      P.security_name,
      p.par_value, p.offering_price,
      p.total_registered_qty AS plan_total_registered_qty,
      p.total_expected_am AS plan_total_expected_am_orig,
      IF(NVL(p.total_expected_am, 0) = 0, IF(NVL(p.offering_price, 0) = 0, p.par_value, p.offering_price) * p.total_registered_qty, p.total_expected_am) AS plan_total_expected_am
    FROM uat_ids_stg.securities_offering_plan p
    LEFT JOIN uat_ids_stg.lookup_values v4 ON v4.lookup_group = 'SO_OFFERING_METHOD' AND v4.lookup_cd = P.offering_method_cd AND v4.ds_snpst_dt = '2026-11-07' -- Hình thức chào bán
    LEFT JOIN uat_ids_stg.lookup_values v5 ON v5.lookup_group = 'SO_SECURITY_TYPE' AND v5.lookup_cd = P.security_type_cd AND v5.ds_snpst_dt = '2026-11-07' -- Loại CK
    WHERE p.ds_snpst_dt = '2026-11-08'
  )
  GROUP BY securities_offering_id, security_type_cd, security_type, offering_method_cd, offering_method_name, security_name, par_value, offering_price
)
-- Kết quả (Gộp theo đăng ký chào bán (securities_offering_id) x Hình thức phát hành (offering_method_cd))
, ids_so_result AS (
  -- Tổng theo ĐKCB x Hình thức
  SELECT
    securities_offering_id, result_report_date, offering_end_date, offering_method_cd, offering_method_name, has_result,
    SUM(total_successful_qty) AS total_successful_qty,
    SUM(total_collected_am) AS total_collected_am
  FROM (
    -- Bước 1. Chi tiết kết quả
    SELECT
      R.securities_offering_id, R.result_report_date, R.offering_end_date,
      R.offering_method_cd, v6.lookup_value_vn AS offering_method_name,
      R.total_successful_qty, R.actual_offering_price, R.total_collected_am,
      IF(R.total_successful_qty IS NOT NULL, 'Y', 'N') AS has_result
    FROM uat_ids_stg.securities_offering_result R
    LEFT JOIN uat_ids_stg.lookup_values v6 ON v6.lookup_group = 'SO_OFFERING_METHOD' AND v6.lookup_cd = R.offering_method_cd AND v6.ds_snpst_dt = '2026-11-07' -- Hình thức chào bán
    WHERE R.approval_status_cd = 'APPROVED'
      AND R.delete_flg = '0'
      AND R.ds_snpst_dt = '2026-11-08'
  )
  GROUP BY securities_offering_id, result_report_date, offering_end_date, offering_method_cd, offering_method_name, has_result
)
-- Kết quả chào bán: Tính bổ sung số tiền thực tế -> Lấy giá bán offering_price từ plan (nếu không có thì lấy Mệnh giá par_value) * KL phát hành thực tế
, ids_so_result_cal AS (
  SELECT
    r.securities_offering_id, r.result_report_date, r.offering_end_date, r.offering_method_cd, r.offering_method_name,
    r.total_successful_qty,
    r.total_collected_am AS total_collected_am_orig,
    IF(NVL(r.total_collected_am, 0) = 0, IF(NVL(p.offering_price, 0) = 0, p.par_value, p.offering_price) * r.total_successful_qty, total_collected_am) AS total_collected_am,
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
    s.security_type_cd, s.security_type, s.offering_method_cd, s.offering_method_name,
    m.offering_method_group, -- Nhóm hình thức phát hành
    m.is_raising_capital, -- Có phải huy động vốn không
    s.plan_total_registered_qty, s.plan_total_expected_am, -- Kế hoạch -- Không lấy am_orig
    s.total_successful_qty, s.total_collected_am, -- Kết quả -- Không lấy am_orig
    s.has_result, s.result_report_date, s.offering_end_date
  FROM (
    -- Gộp dữ liệu đăng ký + kế hoạch + kết quả
    SELECT
      o.*,
      p.security_type_cd, p.security_type,
      p.offering_method_cd, p.offering_method_name, p.security_name,
      p.plan_total_registered_qty,
      p.plan_total_expected_am,
      r.result_report_date, r.offering_end_date,
      r.total_successful_qty,
      r.total_collected_am, 
      r.has_result
    FROM ids_so_certificate o
    JOIN ids_so_plan p ON o.securities_offering_id = p.securities_offering_id
    LEFT JOIN ids_so_result_cal r ON o.securities_offering_id = r.securities_offering_id
      AND p.securities_offering_id = r.securities_offering_id AND p.offering_method_cd = r.offering_method_cd
  ) s
  LEFT JOIN (
    -- Mapping nhóm hình thức phát hành + có huy động vốn không: theo offering_method_cd và security_name [chỉ dùng cho offering_method_cd='9']
    SELECT * FROM VALUES
      ('1',  'Chào bán cho cổ đông hiện hữu',                        '', 'Phát hành ra công chúng',         'Y'),
      ('2',  'Đấu giá',                                              '', 'Phát hành ra công chúng',         'Y'),
      ('3',  'Chào bán ra công chúng theo hình thức khác',           '', 'Phát hành ra công chúng',         'Y'),
      ('4',  'Chào bán của cổ đông công ty đại chúng ra công chúng', '', 'Khác',                            'N'),
      ('5',  'Chào bán riêng lẻ',                                    '', 'Phát hành riêng lẻ',              'Y'),
      ('6',  'Hoán đổi',                                             '', 'Phát hành để hoán đổi/sáp nhập',  'N'),
      ('7',  'Phát hành trả cổ tức',                                 '', 'Phát hành để trả cổ tức',         'Y'),
      ('8',  'Phát hành cổ phiếu từ nguồn vốn CSH',                  '', 'Phát hành tăng vốn từ vốn CSH',   'Y'),
      ('9',  'Phát hành cổ phiếu cho người lao động', 'Phát hành cho người lao động (ESOP)', 'ESOP',        'Y'),
      ('9',  'Phát hành cổ phiếu cho người lao động', 'Phát hành thưởng cho người lao động', 'ESOP',        'N'),
      ('10', 'Phát hành cổ phiếu thưởng cho người lao động',         '', 'ESOP',                            'N'),
      ('11', 'Chào bán trái phiếu giao dịch quốc tế',                '', 'Phát hành ra thị trường quốc tế', 'Y'),
      ('12', 'Phát hành cổ phiếu để chào mua công khai',             '', 'Khác',                            'Y'), 
      ('13', 'Chào bán thêm cổ phiếu ra công chúng',                 '', 'Phát hành ra công chúng',         'Y'),
      ('14', 'Chào bán cổ phiếu ra nước ngoài',                      '', 'Phát hành ra thị trường quốc tế', 'Y'),
      ('15', 'Phát hành cổ phiếu mới làm cơ sở chào bán chứng chỉ lưu ký tại nước ngoài', '', 'Khác',       'Y')
    AS m(offering_method_cd, offering_method_name, security_name, offering_method_group, is_raising_capital)
  ) m
    ON  TRIM(s.offering_method_cd) = m.offering_method_cd
    AND m.security_name = IF(TRIM(s.offering_method_cd) = '9', TRIM(s.security_name), '') -- Chỉ check điều kiện security_name nếu offering_method_cd = '9'
)
-- =======================================
-- 2. DỮ LIỆU CHÀO BÁN PHÁT HÀNH CỦA PHÂN HỆ SCMS - CÔNG TY CHỨNG KHOÁN
-- =======================================
-- Bước 1: parse 2 cột JSON (mảng object) thành array<struct>
, scms_src AS (
  SELECT
    i.code AS sc_firm_code, sc.sc_firm_info_id, sc.document_number, sc.document_date, sc.created_at, sc.offering_date, sc.end_date,
    sc.total_offered_quantity, sc.expected_total_amount,
    sc.result_report_date, sc.proceeds_collected, sc.item_category,
    from_json(sc.plan_json, 'array<struct<loaiChaoBan:string, soLuongCb:decimal(30,2), giaTriCbTheoMenhGia:decimal(30,2)>>') AS plan_arr,
    from_json(sc.result_json, 'array<struct<loaiChaoBan:string, soLuongThucTe:decimal(30,2), giaTriThucTe:decimal(30,2)>>') AS result_arr,
    IF(sc.result_json IS NOT NULL, 'Y', 'N') has_result -- Có kết quả chào bán chưa
  FROM uat_scms_stg.disclosure_securities_offering sc
  LEFT JOIN uat_scms_stg.sc_firm_info i ON sc.sc_firm_info_id = i.id AND i.ds_snpst_dt = '2026-11-06'
  WHERE sc.ds_snpst_dt = '2026-11-07'
    AND NVL(sc.document_date, sc.created_at) IS NOT NULL
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
    x.loaiChaoBan AS offering_method_code,
    m.offering_method_name,
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
      ('CHAO_BAN_RA_CONG_CHUNG',   'Chào bán ra công chúng',             'Phát hành ra công chúng',         'Y'),
      ('CO_PHIEU_THUONG',          'Cổ phiếu thưởng',                    'ESOP',                            'N'),
      ('TRA_CO_TUC_BANG_CP',       'Trả cổ tức bằng CP',                 'Phát hành để trả cổ tức',         'Y'),
      ('PHAT_HANH_CO_THU_TIEN',    'Phát hành có thu tiền',              'ESOP',                            'Y'),
      ('DAU_GIA',                  'Đấu giá',                            'Phát hành ra công chúng',         'Y'),
      ('CHAO_BAN_RIENG_LE',        'Chào bán riêng lẻ',                  'Phát hành riêng lẻ',              'Y'),
      ('PHAT_HANH_CP_DE_HOAN_DOI', 'Phát hành CP để hoán đổi',           'Phát hành để hoán đổi/sáp nhập',  'N'),
      ('CO_DONG_LON_CHAO_BAN',     'Cổ đông lớn chào bán',               'Khác',                            'N'),
      ('CHU_SO_HUU_GOP_VON',       'Chủ sở hữu góp vốn',                 'Phát hành tăng vốn từ vốn CSH',   'Y'),
      ('KHAC',                     'Khác',                               'Khác',                            'Y'),
      ('PHAT_HANH_TP_QUOC_TE',     'Phát hành TP ra thị trường quốc tế', 'Phát hành ra thị trường quốc tế', 'Y')
    AS m(loaiChaoBan, offering_method_name, offering_method_group, is_raising_capital)
  ) m ON x.loaiChaoBan = m.loaiChaoBan
  WHERE x.loaiChaoBan IS NOT NULL -- Lọc dữ liệu lỗi
)
-- =======================================
-- 3. DỮ LIỆU CHÀO BÁN PHÁT HÀNH CỦA PHÂN HỆ FMS - CÔNG TY QLQ
-- =======================================
, fms_offering_data AS (
  SELECT
    'CTQLQ' AS doituong, -- Đối tượng phát hành
    s.code AS fmc_code,
    f.approval_document_no, f.approval_document_date, -- Ngày GCN/CV
    f.securities_type, fd.method_code, m.offering_method_name,
    m.offering_method_group, -- Nhóm hình thức phát hành
    m.is_raising_capital, -- Có phải huy động vốn không
    f.expected_start_date, f.expected_end_date, fd.quantity_cb, fd.value_cb, -- Thông tin kế hoạch
    f.report_result_date, fd.actual_quantity_cb, fd.actual_value_cb, -- Thông tin kết quả
    IF(f.report_result_date IS NOT NULL, 'Y', 'N') AS has_result
  FROM uat_fms_stg.offering f
  LEFT JOIN uat_fms_stg.offering_plan fd ON f.id = fd.offering_id AND fd.ds_snpst_dt = '2026-11-07'
  LEFT JOIN uat_fms_stg.securities s ON f.sec_id = s.id AND s.ds_snpst_dt = '2026-11-07'
  LEFT JOIN (
    -- Map hình thức phát hành -> Nhóm hình thức
    SELECT * FROM VALUES
      ('01', 'Chào bán ra công chúng',   'Phát hành ra công chúng',        'Y'),
      ('02', 'Cổ phiếu thưởng',          'ESOP',                           'N'),
      ('03', 'Trả cổ tức bằng CP',       'Phát hành để trả cổ tức',        'Y'),
      ('04', 'Phát hành có thu tiền',    'ESOP',                           'Y'),
      ('05', 'Đấu giá',                  'Phát hành ra công chúng',        'Y'),
      ('06', 'Chào bán riêng lẻ',        'Phát hành riêng lẻ',             'Y'),
      ('07', 'Phát hành CP để hoán đổi', 'Phát hành để hoán đổi/sáp nhập', 'N'),
      ('08', 'Cổ đông lớn chào bán',     'Khác',                           'N'),
      ('09', 'Chủ sở hữu góp vốn',       'Phát hành tăng vốn từ vốn CSH',  'Y'),
      ('10', 'Khác',                     'Khác',                           'Y')
    AS m(method_code, offering_method_name, offering_method_group, is_raising_capital)
  ) m ON m.method_code = fd.method_code
  WHERE f.deleted = '0'
    AND f.approval_document_date IS NOT NULL
    AND f.ds_snpst_dt = '2026-11-07'
)
-- =======================================
-- 4. GỘP 3 PHÂN HỆ
--    offering_key: khóa đợt dùng để đếm số đợt phát hành theo GCN/CV cấp phép chào bán
--    LỌC: HUY ĐỘNG VỐN + CỔ PHIẾU, TRÁI PHIẾU + (CÁC KỲ TRONG KHOẢNG TỪ KỲ - ĐẾN KỲ) THEO NGÀY GCN/CV
-- =======================================
, all_offering AS (
  SELECT
    CASE p.period_type
      WHEN 'M' THEN DATE_FORMAT(a.cert_date, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(a.cert_date), '-Q', QUARTER(a.cert_date))
      WHEN 'Y' THEN CAST(YEAR(a.cert_date) AS STRING)
    END AS period_key, -- Mã kỳ: 'yyyy-MM' | 'yyyy-Q[1-4]' | 'yyyy'
    a.*
  FROM (
    -- IDS - CTĐC
    SELECT
      d.doituong,
      concat_ws('|', d.doituong, business_reg_no, COALESCE(d.cert_no, '0'), CAST(d.cert_date AS STRING)) AS offering_key, -- Đợt = GCN/CV + mã số CTĐC
      d.cert_date,
      d.offering_method_group AS method_group,
      d.is_raising_capital, d.security_type_cd,
      d.plan_total_registered_qty AS plan_qty,
      d.plan_total_expected_am AS plan_am,
      d.total_successful_qty AS result_qty,
      d.total_collected_am AS result_am,
      d.has_result,
      COALESCE(d.result_report_date, d.offering_end_date) result_report_date
    FROM ids_offering_data d
    WHERE security_type_cd IN ('CP', 'CPUD', 'TP', 'TPCD', 'TPKCQ') -- Loại chứng khoán: Cổ phiếu, Trái phiếu
    UNION ALL
    -- SCMS - CTCK
    SELECT
      d.doituong,
      -- Đợt = GCN/CV (số văn bản) + mã CTCK; văn bản thiếu số thì dùng documentdate/created_at
      concat_ws('|', 'CTCK', d.sc_firm_code, COALESCE(d.document_number, '0'), CAST(d.cert_date AS STRING)) AS offering_key, 
      d.cert_date,
      d.offering_method_group AS method_group,
      d.is_raising_capital,
      d.item_category,
      CAST(d.soLuongCb AS DECIMAL(30,2)) AS plan_qty,
      CAST(d.giaTriCbTheoMenhGia AS DECIMAL(30,2)) AS plan_am,
      CAST(d.soLuongThucTe AS DECIMAL(30,2)) AS result_qty,
      CAST(d.giaTriThucTe AS DECIMAL(30,2)) AS result_am,
      d.has_result,
      d.result_report_date
    FROM scms_offering_data d
    WHERE item_category IN ('CP', 'TP') -- Loại chứng khoán: Cổ phiếu, Trái phiếu
    UNION ALL
    -- FMS - CTQLQ
    SELECT
      d.doituong,
      concat_ws('|', d.doituong, d.fmc_code, COALESCE(d.approval_document_no, '0'), CAST(d.approval_document_date AS STRING)) AS offering_key, -- Đợt = GCN/CV
      d.approval_document_date AS cert_date,
      d.offering_method_group AS method_group,
      d.is_raising_capital, d.securities_type,
      d.quantity_cb AS plan_qty,
      d.value_cb AS plan_am,
      d.actual_quantity_cb AS result_qty,
      d.actual_value_cb AS result_am,
      d.has_result,
      d.report_result_date
    FROM fms_offering_data d
    WHERE securities_type IN ('CP', 'TP') -- Loại chứng khoán: Cổ phiếu, Trái phiếu
  ) a
  CROSS JOIN params p
  WHERE a.cert_date BETWEEN p.period_from_startdate AND p.period_to_enddate -- Lọc điều kiện ngày GCN/CV thuộc khoảng [Từ kỳ, Đến kỳ]
    AND a.is_raising_capital = 'Y' -- Có phải huy động vốn không
)
-- =======================================
-- 5. DỮ LIỆU PHÁT HÀNH CỦA TPDN RIÊNG LẺ, TPCP (HNX)
--    TPDN riêng lẻ: báo cáo nguồn là số LŨY KẾ từ đầu năm đến cuối tháng báo cáo (report_year, report_month)
--    TPCP: báo cáo nguồn là số PHÁT SINH trong tháng báo cáo -> lọc trực tiếp theo ngày phát hành (issue_date)
-- =======================================
---- 5.1. TPDNRL: Tính số phát sinh của riêng từng tháng = lũy kế tháng này - lũy kế tháng liền trước cùng năm (tháng đầu năm/chưa có tháng trước: trừ 0)
, private_corpbond_offering_monthly AS (
  SELECT
    report_month_startdate,
    market_type,
    gt_phat_hanh_ytd - COALESCE(LAG(gt_phat_hanh_ytd) OVER w, 0) AS gt_phat_hanh
  FROM (
    -- Số LŨY KẾ từ đầu năm của GT phát hành theo từng tháng báo cáo
    SELECT
      report_year, report_month, market_type,
      MAKE_DATE(report_year, report_month, 1) AS report_month_startdate, -- Ngày đầu tháng báo cáo
      NVL(SUM(offering_volume * par_value), 0) AS gt_phat_hanh_ytd -- GT phát hành = KL phát hành x Mệnh giá
    FROM (
      SELECT report_year, report_month, market_type, offering_volume, par_value,
        DENSE_RANK() OVER(PARTITION BY report_year, report_month ORDER BY ds_snpst_dt DESC) AS rk -- Lọc snapshotdate mới nhất của từng tháng báo cáo
      FROM (
        -- report_month có thể là int (1,2,3) hoặc string ('01','02',...) -> chuẩn hóa về int
        SELECT
          CAST(cb.report_year AS INT) AS report_year,
          CAST(cb.report_month AS INT) AS report_month,
          cb.market_type, cb.offering_volume, cb.par_value, cb.ds_snpst_dt
        FROM uat_hnx_stg.private_corp_bond_offering cb
      ) cbn
    ) cs
    WHERE cs.rk = 1 -- Lọc snapshot date mới nhất
    GROUP BY report_year, report_month, market_type
  )
  WINDOW w AS (PARTITION BY report_year ORDER BY report_month)
)
---- 5.2. TPDNRL: GT phát hành của kỳ = Σ phát sinh riêng từng tháng báo cáo trong kỳ
, private_corpbond_agg AS (
  SELECT
    period_key,
    'TPDNRL' AS loai_ck,
    NVL(SUM(gt_phat_hanh), 0) AS gt_tc -- Giá trị phát hành thành công
  FROM (
    SELECT
      CASE p.period_type
        WHEN 'M' THEN DATE_FORMAT(m.report_month_startdate, 'yyyy-MM')
        WHEN 'Q' THEN CONCAT(YEAR(m.report_month_startdate), '-Q', QUARTER(m.report_month_startdate))
        WHEN 'Y' THEN CAST(YEAR(m.report_month_startdate) AS STRING)
      END AS period_key, -- Mã kỳ: 'yyyy-MM' | 'yyyy-Q[1-4]' | 'yyyy'
      m.gt_phat_hanh
    FROM private_corpbond_offering_monthly m
    CROSS JOIN params p
    WHERE m.report_month_startdate BETWEEN TRUNC(p.period_from_startdate, 'MM') AND TRUNC(p.period_to_enddate, 'MM')
  ) k
  GROUP BY period_key
)
---- 5.3. TPCP: Số liệu phát sinh trong tháng báo cáo -> lọc theo ngày phát hành (issue_date), GT phát hành = GT trúng thầu (winning_value)
, govbond_agg AS (
  SELECT
    period_key,
    'TPCP' AS loai_ck,
    NVL(SUM(calling_value), 0) AS gt_dangky,
    NVL(SUM(winning_value), 0) AS gt_tc -- Giá trị phát hành thành công = GT trúng thầu
  FROM (
    SELECT
      CASE p.period_type
        WHEN 'M' THEN DATE_FORMAT(gb.issue_date, 'yyyy-MM')
        WHEN 'Q' THEN CONCAT(YEAR(gb.issue_date), '-Q', QUARTER(gb.issue_date))
        WHEN 'Y' THEN CAST(YEAR(gb.issue_date) AS STRING)
      END AS period_key, -- Mã kỳ: 'yyyy-MM' | 'yyyy-Q[1-4]' | 'yyyy'
      gb.calling_value,
      gb.winning_value
    FROM (
      -- Lọc snapshotdate mới nhất của từng tháng báo cáo
      SELECT issue_date, calling_value, winning_value,
        DENSE_RANK() OVER(PARTITION BY CAST(report_year AS INT), CAST(report_month AS INT) ORDER BY ds_snpst_dt DESC) AS rk -- order theo snapshot date
      FROM uat_hnx_stg.gov_bond_offering
    ) gb
    CROSS JOIN params p
    WHERE gb.rk = 1
      AND gb.issue_date BETWEEN p.period_from_startdate AND p.period_to_enddate -- Ngày phát hành thuộc khoảng [Từ kỳ, Đến kỳ]
  ) k
  GROUP BY period_key
)
-- =======================================
-- 6. TỔNG HỢP: giá trị phát hành đăng ký, thành công theo kỳ x loại chứng khoán 
-- =======================================
-- Giá trị phát hành thành công theo kỳ x loại chứng khoán gốc (CP, TPDN, TPCP)
, offering_by_type AS (
  -- CP, TP do UB cấp phép chào bán
  SELECT
    period_key,
    security_type_cd AS loai_ck,
    COALESCE(SUM(plan_am), 0) AS gt_dangky,
    COALESCE(SUM(result_am), 0) AS gt_tc
  FROM all_offering
  GROUP BY period_key, security_type_cd
  UNION ALL
  -- TPDN riêng lẻ (HNX): không có số liệu về GT đăng ký chào bán -> Lấy GT đăng ký = GT thành công, khi có số liệu đăng ký do HNX cung cấp thì cập nhật lại
  SELECT period_key, loai_ck, gt_tc AS gt_dangky, gt_tc FROM private_corpbond_agg 
  UNION ALL
  -- TPCP (HNX)
  SELECT period_key, loai_ck, gt_dangky, gt_tc FROM govbond_agg
)
-- =======================================
-- 7. KẾT QUẢ: giá trị phát hành đăng ký, thành công theo loại chứng khoán (chỉ các kỳ có dữ liệu)
-- =======================================
SELECT
  pr.period_type,
  pr.period_from,
  pr.period_to,
  a.period_key AS ky, -- Mã kỳ
  a.nhom_loai_ck,
  a.gt_dangky, -- Giá trị phát hành đăng ký
  a.gt_tc -- Giá trị phát hành thành công
FROM (
  SELECT
    period_key,
    CASE 
      WHEN loai_ck IN ('CP', 'CPUD') THEN 'CP'
      WHEN loai_ck IN ('TP', 'TPCD', 'TPKCQ', 'TPDNRL') THEN 'TPDN'
      ELSE loai_ck
    END nhom_loai_ck,
    SUM(gt_dangky) AS gt_dangky,
    SUM(gt_tc) AS gt_tc
  FROM offering_by_type g
  GROUP BY 
    period_key,
    CASE 
      WHEN loai_ck IN ('CP', 'CPUD') THEN 'CP'
      WHEN loai_ck IN ('TP', 'TPCD', 'TPKCQ', 'TPDNRL') THEN 'TPDN'
      ELSE loai_ck
    END
) a 
CROSS JOIN params pr
ORDER BY ky
;