-- [53] DATA EXPLORER >> HUY ĐỘNG VỐN: KL, GT PHÁT HÀNH (ĐĂNG KÝ, THÀNH CÔNG), GT NĐTNN, KỲ HẠN BQ, LÃI SUẤT BQ
/* Tham số:
 *   :period_type  Loại kỳ: D | M | Q | Y
 *   :period_from, :period_to  Từ kỳ - Đến kỳ: D = yyyy-MM-dd | M = yyyy-MM | Q = yyyy-Q[1-4] | Y = yyyy
 * CHIỀU (dimension):
 *   doi_tuong : Đối tượng phát hành: CTĐC (IDS) | CTCK (SCMS) | CTQLQ (FMS) | NULL (TPCP, TPDN riêng lẻ của HNX)
 *   nganh     : Ngành của TCPH: IDS thông tin ngành cấp 1, NULL là 'Chưa phân ngành'; SCMS (CTCK), FMS (CTQLQ) mặc định là 'Tài chính ngân hàng'; HNX (TPDN riêng lẻ, TPCP, Đấu giá): NULL
 *   loai_ck   : CP | TPDNNY | TPDN riêng lẻ - TP thường | TPDN riêng lẻ - TP chuyển đổi | TPDN riêng lẻ - TP kèm chứng quyền | TPCP | Chứng chỉ quỹ | Chứng quyền
 *   huy_dong_von  : Y - Có | N - Không | NA - Không phân loại (HNX: TPDN riêng lẻ, TPCP = Y; Đấu giá = NA)
 *   nhom_hinhthuc : Nhóm hình thức phát hành
 * CHỈ TIÊU (cộng dồn được theo mọi chiều):
 *   kl_dangky, kl_tc : KL phát hành đăng ký / thành công (TPCP: NULL)
 *   gt_dangky, gt_tc : GT phát hành đăng ký / thành công (TPDN riêng lẻ HNX: GT đăng ký NULL; TPCP: GT gọi thầu / GT trúng thầu)
 *   gt_ndtnn         : GT phát hành cho NĐTNN: IDS foreign_collected_am | SCMS result_json.giaTriPhatHanhNdtnn | FMS offering_plan.issuance_value_foreign | HNX TPDN riêng lẻ: market_type = 'Quốc tế' | TPCP: NULL
 *   tyle_tc_tuso / tyle_tc_mauso     : Tử số / mẫu số Tỷ lệ thực hiện thành công = Σ GT thành công / Σ GT đăng ký (chỉ dòng có GT đăng ký)
 *   kyhanbq_tuso / kyhanbq_mauso     : Σ(Kỳ hạn năm x GT thành công) / Σ GT thành công (chỉ dòng có kỳ hạn)
 *   laisuatbq_tuso / laisuatbq_mauso : Σ(Lãi suất % x GT thành công) / Σ GT thành công (chỉ dòng có lãi suất)
 *   => tyle_tc_pct, kyhan_bq_nam, laisuat_bq_pct: SUM tử số, SUM mẫu số theo các chiều được chọn rồi mới chia -> tỷ lệ/BQ đã tính sẵn ở mức chi tiết đủ 4 chiều chỉ để map công thức.
 */
WITH
-- ========== 0. THAM SỐ: ngày đầu của Từ kỳ, ngày cuối của Đến kỳ ========== 
params AS (
  SELECT
    UPPER(:period_type) AS period_type,
    CASE UPPER(:period_type)
      WHEN 'D' THEN TO_DATE(:period_from)
      WHEN 'M' THEN TO_DATE(CONCAT(:period_from, '-01'))
      WHEN 'Q' THEN MAKE_DATE(CAST(SUBSTR(:period_from, 1, 4) AS INT), (CAST(SUBSTR(:period_from, 7, 1) AS INT) - 1) * 3 + 1, 1)
      WHEN 'Y' THEN MAKE_DATE(CAST(:period_from AS INT), 1, 1)
    END AS from_date,
    CASE UPPER(:period_type)
      WHEN 'D' THEN TO_DATE(:period_to)
      WHEN 'M' THEN LAST_DAY(TO_DATE(CONCAT(:period_to, '-01')))
      WHEN 'Q' THEN LAST_DAY(MAKE_DATE(CAST(SUBSTR(:period_to, 1, 4) AS INT), CAST(SUBSTR(:period_to, 7, 1) AS INT) * 3, 1))
      WHEN 'Y' THEN MAKE_DATE(CAST(:period_to AS INT), 12, 31)
    END AS to_date
)
-- Fix ngành cho CTCK, CTQLQ: Ngành "Tài chính ngân hàng" (như [29])
, industry_fix_ctck_ctqlq AS (
  SELECT DISTINCT industry_name
  FROM uat_ids_stg.categories
  WHERE industry_cd = '07000' AND active_flg = '1' AND ds_snpst_dt = '2026-11-11'
  LIMIT 1
)
-- ========== 1. IDS - CÔNG TY ĐẠI CHÚNG ==========
-- Thông tin chấp thuận đăng ký chào bán
, ids_so_certificate AS (
  SELECT
    o.id AS securities_offering_id,
    COALESCE(cp.industry_name, 'Chưa phân ngành') AS nganh, -- Ngành cấp 1 của CTĐC
    o.administrative_proc_cd, -- Thủ tục hành chính ('1.009.496', '1.009.501': IPO của DN thông thường)
    NVL(o.certificate_date, o.official_letter_date) AS cert_date -- Ngày GCN/CV
  FROM uat_ids_stg.securities_offering o
  -- Thông tin hồ sơ Công ty đại chúng + phân ngành (như [29])
  LEFT JOIN (
    SELECT cp.id, c.industry_name
    FROM uat_ids_stg.company_profiles cp
    LEFT JOIN uat_ids_stg.categories c ON cp.category_l1_id = c.id AND c.ds_snpst_dt = '2026-11-11'  -- Thông tin ngành nghề kinh tế
    WHERE cp.delete_flg <> '1' AND (cp.approval_status_cd <> 'REJECTED' OR cp.approval_status_cd IS NULL) AND cp.ds_snpst_dt = '2026-11-11'
  ) cp ON cp.id = o.company_profile_id
  WHERE o.delete_flg = '0'
    AND o.administrative_status_cd = '022' -- Duyệt TTHC
    AND o.approval_status_cd = 'APPROVED'  -- Duyệt chấp thuận đăng ký chào bán
    AND o.ds_snpst_dt = '2026-11-07'
)
-- Kế hoạch (Gộp theo đăng ký chào bán x Hình thức phát hành x Kỳ hạn x Lãi suất)
, ids_so_plan AS (
  SELECT
    securities_offering_id,
    security_type_cd,
    offering_method_cd, security_name,
    par_value, offering_price,
    SUM(plan_total_registered_qty) AS plan_total_registered_qty,
    SUM(plan_total_expected_am) AS plan_total_expected_am,
    term_years, -- Kỳ hạn (năm)
    interest_rate -- Lãi suất (%)
  FROM (
    SELECT
      p.securities_offering_id, p.security_type_cd,
      p.offering_method_cd, p.security_name,
      p.par_value, p.offering_price,
      p.total_registered_qty AS plan_total_registered_qty,
      IF(NVL(p.total_expected_am, 0) = 0, IF(NVL(p.offering_price, 0) = 0, p.par_value, p.offering_price) * p.total_registered_qty, p.total_expected_am) AS plan_total_expected_am,
      -- Kỳ hạn TP: bond_term_value dạng "... tháng" -> quy đổi năm (nhập "... năm" thì giữ nguyên)
      CASE
        WHEN LOWER(p.bond_term_value) LIKE '%năm%'   THEN CAST(NULLIF(REPLACE(REGEXP_EXTRACT(p.bond_term_value, '([0-9]+([.,][0-9]+)?)', 1), ',', '.'), '') AS DECIMAL(10, 4))
        WHEN LOWER(p.bond_term_value) LIKE '%tháng%' THEN CAST(NULLIF(REPLACE(REGEXP_EXTRACT(p.bond_term_value, '([0-9]+([.,][0-9]+)?)', 1), ',', '.'), '') AS DECIMAL(10, 4)) / 12.0
      END AS term_years,
      p.interest_rate -- Lãi suất (%)
    FROM uat_ids_stg.securities_offering_plan p
    WHERE p.ds_snpst_dt = '2026-11-08'
  )
  GROUP BY securities_offering_id, security_type_cd, offering_method_cd, security_name, par_value, offering_price, term_years, interest_rate
)
-- Kết quả (Gộp theo đăng ký chào bán x Hình thức phát hành)
, ids_so_result AS (
  SELECT
    securities_offering_id, result_report_date, offering_end_date, offering_method_cd,
    SUM(total_successful_qty) AS total_successful_qty,
    SUM(total_collected_am) AS total_collected_am,
    SUM(foreign_collected_am) AS foreign_collected_am -- GT phát hành cho NĐTNN
  FROM uat_ids_stg.securities_offering_result R
  WHERE R.approval_status_cd = 'APPROVED'
    AND R.delete_flg = '0'
    AND R.ds_snpst_dt = '2026-11-08'
  GROUP BY securities_offering_id, result_report_date, offering_end_date, offering_method_cd
)
-- Kết quả: bổ sung số tiền thực tế = Giá chào bán (không có thì Mệnh giá) x KL phát hành thực tế khi số tiền = 0/NULL
, ids_so_result_cal AS (
  SELECT
    r.securities_offering_id, r.offering_method_cd,
    r.total_successful_qty,
    IF(NVL(r.total_collected_am, 0) = 0, IF(NVL(p.offering_price, 0) = 0, p.par_value, p.offering_price) * r.total_successful_qty, r.total_collected_am) AS total_collected_am,
    r.foreign_collected_am
  FROM ids_so_result r
  LEFT JOIN (
    -- Giá chào bán / mệnh giá theo ĐKCB x Hình thức
    SELECT securities_offering_id, offering_method_cd, MAX(par_value) AS par_value, MAX(offering_price) AS offering_price
    FROM ids_so_plan
    GROUP BY securities_offering_id, offering_method_cd
  ) p ON r.securities_offering_id = p.securities_offering_id AND r.offering_method_cd = p.offering_method_cd
)
-- Gộp đăng ký + kế hoạch + kết quả, map nhóm hình thức phát hành
, ids_offering_data AS (
  SELECT
    s.securities_offering_id,
    'Công ty đại chúng' AS doi_tuong,
    s.nganh,
    s.cert_date,
    s.security_type_cd, -- Loại CK
    CASE WHEN TRIM(s.administrative_proc_cd) IN ('1.009.496', '1.009.501') THEN 'IPO của DN thông thường' ELSE m.offering_method_group END AS nhom_hinhthuc,
    m.is_raising_capital AS huy_dong_von,
    s.plan_total_registered_qty AS plan_qty,
    s.plan_total_expected_am AS plan_am,
    s.total_successful_qty AS result_qty,
    s.total_collected_am AS result_am,
    s.foreign_collected_am AS ndtnn_am,
    s.term_years,
    s.interest_rate
  FROM (
    SELECT
      o.*,
      p.security_type_cd, p.offering_method_cd, p.security_name,
      p.plan_total_registered_qty, p.plan_total_expected_am,
      p.term_years, p.interest_rate,
      r.total_successful_qty, r.total_collected_am, r.foreign_collected_am
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
      ('12', 'Phát hành cổ phiếu để chào mua công khai',             '', 'Phát hành để chào mua công khai', 'Y'),
      ('13', 'Chào bán thêm cổ phiếu ra công chúng',                 '', 'Phát hành ra công chúng',         'Y'),
      ('14', 'Chào bán cổ phiếu ra nước ngoài',                      '', 'Phát hành ra thị trường quốc tế', 'Y'),
      ('15', 'Phát hành cổ phiếu mới làm cơ sở chào bán chứng chỉ lưu ký tại nước ngoài', '', 'Khác',       'Y')
    AS m(offering_method_cd, offering_method_name, security_name, offering_method_group, is_raising_capital)
  ) m
    ON  TRIM(s.offering_method_cd) = m.offering_method_cd
    AND m.security_name = IF(TRIM(s.offering_method_cd) = '9', TRIM(s.security_name), '') -- Chỉ check điều kiện security_name nếu offering_method_cd = '9'
)
-- ========== 2. SCMS - CÔNG TY CHỨNG KHOÁN ========== 
-- Bước 1: parse 2 cột JSON (mảng object) thành array<struct>
, scms_src AS (
  SELECT
    NVL(sc.document_date, TO_DATE(sc.created_at)) AS cert_date, -- Ngày GCN/CV
    sc.item_category,
    sc.maturity_years AS term_years, -- Kỳ hạn (năm)
    from_json(sc.plan_json, 'array<struct<loaiChaoBan:string, soLuongCb:decimal(30,2), giaTriCbTheoMenhGia:decimal(30,2)>>') AS plan_arr,
    from_json(sc.result_json, 'array<struct<loaiChaoBan:string, soLuongThucTe:decimal(30,2), giaTriThucTe:decimal(30,2), giaTriPhatHanhNdtnn:decimal(30,2)>>') AS result_arr
  FROM uat_scms_stg.disclosure_securities_offering sc
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
-- Bước 3: Mapping nhóm hình thức + cờ huy động vốn
, scms_offering_data AS (
  SELECT
    'Công ty chứng khoán' AS doi_tuong,
    i.industry_name AS nganh, -- CTCK: Tài chính ngân hàng
    x.cert_date,
    x.item_category AS security_type_cd, -- Loại CK
    m.offering_method_group AS nhom_hinhthuc,
    m.is_raising_capital AS huy_dong_von,
    x.soLuongCb AS plan_qty,
    x.giaTriCbTheoMenhGia AS plan_am,
    x.r.soLuongThucTe AS result_qty,
    x.r.giaTriThucTe AS result_am,
    x.r.giaTriPhatHanhNdtnn AS ndtnn_am, -- GT phát hành cho NĐTNN
    x.term_years,
    CAST(NULL AS DECIMAL(10, 4)) AS interest_rate -- SCMS không có lãi suất
  FROM scms_plan_x x
  LEFT JOIN industry_fix_ctck_ctqlq i ON 1 = 1
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
-- ========== 3. FMS - CÔNG TY QLQ ==========
, fms_offering_data AS (
  SELECT
    'Công ty Quản lý quỹ' AS doi_tuong,
    i.industry_name AS nganh, -- CTQLQ: Tài chính ngân hàng
    f.approval_document_date AS cert_date, -- Ngày GCN/CV
    f.securities_type AS security_type_cd, -- Loại CK
    m.offering_method_group AS nhom_hinhthuc,
    m.is_raising_capital AS huy_dong_von,
    fd.quantity_cb AS plan_qty,
    fd.value_cb AS plan_am,
    fd.actual_quantity_cb AS result_qty,
    fd.actual_value_cb AS result_am,
    fd.issuance_value_foreign AS ndtnn_am, -- GT phát hành cho NĐTNN
    f.bond_term_years AS term_years,
    CAST(NULL AS DECIMAL(10, 4)) AS interest_rate -- FMS không có lãi suất
  FROM uat_fms_stg.offering f
  LEFT JOIN uat_fms_stg.offering_plan fd ON f.id = fd.offering_id AND fd.ds_snpst_dt = '2026-11-07'
  LEFT JOIN industry_fix_ctck_ctqlq i ON 1 = 1
  LEFT JOIN (
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
-- ========== 4. GỘP IDS + SCMS + FMS (UBCK quản lý): map loại CK, lọc kỳ theo ngày GCN/CV ==========
, ubck_offering AS (
  SELECT
    CASE p.period_type
      WHEN 'D' THEN DATE_FORMAT(a.cert_date, 'yyyy-MM-dd')
      WHEN 'M' THEN DATE_FORMAT(a.cert_date, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(a.cert_date), '-Q', QUARTER(a.cert_date))
      WHEN 'Y' THEN CAST(YEAR(a.cert_date) AS STRING)
    END AS period_code,
    a.doi_tuong,
    a.nganh,
    CASE
      WHEN a.security_type_cd IN ('CP', 'CPUD') THEN 'CP'
      WHEN a.security_type_cd IN ('TP', 'TPCD', 'TPKCQ') AND NVL(a.nhom_hinhthuc, '') <> 'Phát hành riêng lẻ' THEN 'TPDN niêm yết'
      WHEN a.security_type_cd = 'TPCD' AND a.nhom_hinhthuc = 'Phát hành riêng lẻ' THEN 'TPDN riêng lẻ - TP chuyển đổi'
      WHEN a.security_type_cd = 'TPKCQ' AND a.nhom_hinhthuc = 'Phát hành riêng lẻ' THEN 'TPDN riêng lẻ - TP kèm chứng quyền'
      WHEN a.security_type_cd = 'TP' AND a.nhom_hinhthuc = 'Phát hành riêng lẻ' THEN 'TPDN riêng lẻ - TP thường'
      WHEN a.security_type_cd = 'CCQ' THEN 'Chứng chỉ quỹ' -- FMS
      WHEN a.security_type_cd IN ('CQC', 'CW') THEN 'Chứng quyền' -- FMS: CQC, SCMS: CW
      ELSE a.security_type_cd
    END AS loai_ck,
    a.huy_dong_von,
    a.nhom_hinhthuc,
    CAST(a.plan_qty AS DECIMAL(38, 2)) AS kl_dangky,
    CAST(a.result_qty AS DECIMAL(38, 2)) AS kl_tc,
    CAST(a.plan_am AS DECIMAL(38, 2)) AS gt_dangky,
    CAST(a.result_am AS DECIMAL(38, 2)) AS gt_tc,
    CAST(a.ndtnn_am AS DECIMAL(38, 2)) AS gt_ndtnn,
    CAST(a.term_years AS DECIMAL(10, 4)) AS term_years,
    CAST(a.interest_rate AS DECIMAL(10, 4)) AS interest_rate
  FROM (
    SELECT securities_offering_id, doi_tuong, nganh, cert_date, security_type_cd, nhom_hinhthuc, huy_dong_von, plan_qty, plan_am, result_qty, result_am, ndtnn_am, term_years, interest_rate FROM ids_offering_data
    UNION ALL
    SELECT NULL, doi_tuong, nganh, cert_date, security_type_cd, nhom_hinhthuc, huy_dong_von, plan_qty, plan_am, result_qty, result_am, ndtnn_am, term_years, interest_rate FROM scms_offering_data
    UNION ALL
    SELECT NULL, doi_tuong, nganh, cert_date, security_type_cd, nhom_hinhthuc, huy_dong_von, plan_qty, plan_am, result_qty, result_am, ndtnn_am, term_years, interest_rate FROM fms_offering_data
  ) a
  CROSS JOIN params p
  WHERE a.cert_date BETWEEN p.from_date AND p.to_date -- Ngày GCN/CV thuộc khoảng [Từ kỳ, Đến kỳ]
)
, ubck_agg AS (
  SELECT
    period_code, doi_tuong, nganh, loai_ck, huy_dong_von, nhom_hinhthuc,
    SUM(kl_dangky) AS kl_dangky,
    SUM(kl_tc) AS kl_tc,
    SUM(gt_dangky) AS gt_dangky,
    SUM(gt_tc) AS gt_tc,
    SUM(gt_ndtnn) AS gt_ndtnn,
    SUM(IF(gt_dangky IS NOT NULL, gt_tc, NULL)) AS tyle_tc_tuso,
    SUM(IF(gt_dangky IS NOT NULL, gt_dangky, NULL)) AS tyle_tc_mauso,
    SUM(IF(term_years IS NOT NULL AND gt_tc > 0, term_years * gt_tc, NULL)) AS kyhanbq_tuso,
    SUM(IF(term_years IS NOT NULL AND gt_tc > 0, gt_tc, NULL)) AS kyhanbq_mauso,
    SUM(IF(interest_rate IS NOT NULL AND gt_tc > 0, interest_rate * gt_tc, NULL)) AS laisuatbq_tuso,
    SUM(IF(interest_rate IS NOT NULL AND gt_tc > 0, gt_tc, NULL)) AS laisuatbq_mauso
  FROM ubck_offering
  GROUP BY period_code, doi_tuong, nganh, loai_ck, huy_dong_von, nhom_hinhthuc
)
-- ========== 5. TPDN RIÊNG LẺ (HNX) ==========
-- Báo cáo LŨY KẾ từ đầu năm -> phát sinh tháng = lũy kế tháng - lũy kế tháng liền trước cùng năm
-- Tách theo loại TP x thị trường (market_type = 'Quốc tế' -> GT phát hành cho NĐTNN). Kỳ D: không có số liệu.
---- 5.1. Lũy kế theo tháng báo cáo x loại TP x thị trường (snapshot mới nhất của từng tháng báo cáo)
, private_corpbond_ytd AS (
  SELECT
    report_year, report_month, loai_ck, market_type, enterprise_type, business_sector,
    NVL(SUM(gt), 0) AS gt_ytd,
    NVL(SUM(IF(term_years IS NOT NULL, term_years * gt, 0)), 0) AS kyhanbq_tuso_ytd,
    NVL(SUM(IF(term_years IS NOT NULL, gt, 0)), 0) AS kyhanbq_mauso_ytd,
    NVL(SUM(IF(issue_interest_rate IS NOT NULL, issue_interest_rate * gt, 0)), 0) AS laisuatbq_tuso_ytd,
    NVL(SUM(IF(issue_interest_rate IS NOT NULL, gt, 0)), 0) AS laisuatbq_mauso_ytd, 
    NVL(SUM(IF(market_type = 'Quốc tế', gt, 0)), 0) AS gt_ndtnn_ytd
  FROM (
    SELECT
      CAST(cb.report_year AS INT) AS report_year,
      CAST(cb.report_month AS INT) AS report_month,
      CASE
        WHEN TRIM(cb.convertible_bond) = 'Có'    THEN 'TPDN riêng lẻ - TP chuyển đổi'
        WHEN TRIM(cb.warrant_linked_bond) = 'Có' THEN 'TPDN riêng lẻ - TP kèm chứng quyền'
        ELSE 'TPDN riêng lẻ - TP thường' -- convertible_bond, warrant_linked_bond đều = 'Không'
      END AS loai_ck,
      cb.market_type, -- Thị trường (Trong nước, Quốc tế)
      cb.enterprise_type,
      cb.business_sector,
      CAST(cb.offering_volume AS DECIMAL(30, 2)) * CAST(cb.par_value AS DECIMAL(30, 2)) AS gt, -- GT phát hành = KL phát hành x Mệnh giá
      CASE TRIM(cb.term_unit)
        WHEN 'Tháng' THEN cb.term / 12.0
        WHEN 'Năm'   THEN cb.term
      END AS term_years, -- Kỳ hạn (năm)
      cb.issue_interest_rate, -- Lãi suất phát hành (%)
      DENSE_RANK() OVER(PARTITION BY cb.report_year, cb.report_month, cb.market_type ORDER BY cb.ds_snpst_dt DESC) AS rk -- Snapshot mới nhất của từng tháng báo cáo
    FROM uat_hnx_stg.private_corp_bond_offering cb
  ) cs
  WHERE cs.rk = 1
  GROUP BY report_year, report_month, loai_ck, market_type, enterprise_type, business_sector
)
---- 5.2. Phát sinh riêng từng tháng (tháng đầu năm / chưa có tháng trước: trừ 0)
, private_corpbond_monthly AS (
  SELECT
    MAKE_DATE(report_year, report_month, 1) AS report_month_startdate,
    loai_ck, 
    market_type,
    enterprise_type,
    business_sector,
    gt_ytd              - COALESCE(LAG(gt_ytd)              OVER w, 0) AS gt,
    kyhanbq_tuso_ytd    - COALESCE(LAG(kyhanbq_tuso_ytd)    OVER w, 0) AS kyhanbq_tuso,
    kyhanbq_mauso_ytd   - COALESCE(LAG(kyhanbq_mauso_ytd)   OVER w, 0) AS kyhanbq_mauso,
    laisuatbq_tuso_ytd  - COALESCE(LAG(laisuatbq_tuso_ytd)  OVER w, 0) AS laisuatbq_tuso,
    laisuatbq_mauso_ytd - COALESCE(LAG(laisuatbq_mauso_ytd) OVER w, 0) AS laisuatbq_mauso
    gt_ndtnn_ytd        - COALESCE(LAG(gt_ndtnn_ytd) OVER w, 0) AS gt_ndtnn,
  FROM private_corpbond_ytd
  WINDOW w AS (PARTITION BY report_year, loai_ck, market_type, enterprise_type, business_sector, business_sector ORDER BY report_month)
)
---- 5.3. Tổng hợp theo kỳ = Σ phát sinh từng tháng báo cáo trong kỳ
, private_corpbond_agg AS (
  SELECT
    CASE p.period_type
      WHEN 'M' THEN DATE_FORMAT(m.report_month_startdate, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(m.report_month_startdate), '-Q', QUARTER(m.report_month_startdate))
      WHEN 'Y' THEN CAST(YEAR(m.report_month_startdate) AS STRING)
    END AS period_code,
    m.enterprise_type AS doi_tuong,
    m.business_sector AS nganh,
    m.loai_ck,
    'Y' AS huy_dong_von,
    'Phát hành riêng lẻ' AS nhom_hinhthuc,
    CAST(NULL AS DECIMAL(38, 2)) AS kl_dangky, -- Không có KL
    CAST(NULL AS DECIMAL(38, 2)) AS kl_tc,
    CAST(NULL AS DECIMAL(38, 2)) AS gt_dangky, -- Không có GT đăng ký
    SUM(m.gt) AS gt_tc,
    SUM(IF(m.market_type = 'Quốc tế', m.gt, 0)) AS gt_ndtnn, -- GT phát hành cho NĐTNN = GT phát hành thị trường Quốc tế
    CAST(NULL AS DECIMAL(38, 2)) AS tyle_tc_tuso,
    CAST(NULL AS DECIMAL(38, 2)) AS tyle_tc_mauso,
    SUM(m.kyhanbq_tuso) AS kyhanbq_tuso,
    SUM(m.kyhanbq_mauso) AS kyhanbq_mauso,
    SUM(m.laisuatbq_tuso) AS laisuatbq_tuso,
    SUM(m.laisuatbq_mauso) AS laisuatbq_mauso
  FROM private_corpbond_monthly m
  CROSS JOIN params p
  WHERE p.period_type <> 'D' -- Kỳ D: không có số liệu (báo cáo tháng)
    AND m.report_month_startdate BETWEEN TRUNC(p.from_date, 'MM') AND TRUNC(p.to_date, 'MM')
  GROUP BY 1, m.loai_ck, m.enterprise_type, m.business_sector
)
-- ========== 6. TPCP (HNX) ==========
-- Số liệu phát sinh trong tháng báo cáo -> lọc theo ngày phát hành (issue_date)
, govbond_agg AS (
  SELECT
    CASE p.period_type
      WHEN 'D' THEN DATE_FORMAT(gb.issue_date, 'yyyy-MM-dd')
      WHEN 'M' THEN DATE_FORMAT(gb.issue_date, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(gb.issue_date), '-Q', QUARTER(gb.issue_date))
      WHEN 'Y' THEN CAST(YEAR(gb.issue_date) AS STRING)
    END AS period_code,
    CAST(NULL AS STRING) AS doi_tuong,
    CAST(NULL AS STRING) AS nganh,
    'TPCP' AS loai_ck,
    'Y' AS huy_dong_von,
    'Đấu thầu' AS nhom_hinhthuc,
    CAST(NULL AS DECIMAL(38, 2)) AS kl_dangky, -- Không có KL
    CAST(NULL AS DECIMAL(38, 2)) AS kl_tc, -- Không có KL
    SUM(gb.calling_value) AS gt_dangky,
    SUM(gb.winning_value) AS gt_tc,
    CAST(NULL AS DECIMAL(38, 2)) AS gt_ndtnn, -- Không có số liệu NĐTNN
    SUM(IF(gb.calling_value IS NOT NULL, gb.winning_value, NULL)) AS tyle_tc_tuso,
    SUM(gb.calling_value) AS tyle_tc_mauso,
    SUM(IF(gb.term_years IS NOT NULL AND gb.winning_value > 0, gb.term_years * gb.winning_value, NULL)) AS kyhanbq_tuso,
    SUM(IF(gb.term_years IS NOT NULL AND gb.winning_value > 0, gb.winning_value, NULL)) AS kyhanbq_mauso,
    SUM(IF(gb.winning_interest_rate IS NOT NULL AND gb.winning_value > 0, gb.winning_interest_rate * gb.winning_value, NULL)) AS laisuatbq_tuso,
    SUM(IF(gb.winning_interest_rate IS NOT NULL AND gb.winning_value > 0, gb.winning_value, NULL)) AS laisuatbq_mauso
  FROM (
    SELECT
      issue_date,
      CAST(calling_value AS DECIMAL(38, 2)) AS calling_value,
      CAST(winning_value AS DECIMAL(38, 2)) AS winning_value,
      CAST(winning_interest_rate AS DECIMAL(10, 4)) AS winning_interest_rate,
      -- Quy đổi kỳ hạn tuần/tháng về số năm
      CASE
        WHEN LOWER(term) LIKE '%tuần%'  THEN CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4)) / 52.0
        WHEN LOWER(term) LIKE '%tháng%' THEN CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4)) / 12.0
        WHEN LOWER(term) LIKE '%năm%'   THEN CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4))
      END AS term_years,
      DENSE_RANK() OVER(PARTITION BY report_year, report_month ORDER BY ds_snpst_dt DESC) AS rk -- Snapshot mới nhất của từng tháng báo cáo
    FROM uat_hnx_stg.gov_bond_offering
  ) gb
  CROSS JOIN params p
  WHERE gb.rk = 1 -- Lọc snapshot date 
    AND gb.issue_date BETWEEN p.from_date AND p.to_date -- Ngày phát hành thuộc khoảng [Từ kỳ, Đến kỳ]
  GROUP BY 1
)
-- ========== 6.1. ĐẤU GIÁ (HNX05, HSX03 ==========
-- Số liệu phát sinh trong từng tháng báo cáo (report_year, report_month). Kỳ D: không có số liệu
-- Đối tượng NULL; Loại CK = CP; Huy động vốn = 'NA' (không phân loại)
-- Tỷ lệ thành công, Kỳ hạn, Lãi suất: NULL
-- ====================================================
, auction_agg AS (
  SELECT
    CASE p.period_type
      WHEN 'M' THEN DATE_FORMAT(a.report_month_startdate, 'yyyy-MM')
      WHEN 'Q' THEN CONCAT(YEAR(a.report_month_startdate), '-Q', QUARTER(a.report_month_startdate))
      WHEN 'Y' THEN CAST(YEAR(a.report_month_startdate) AS STRING)
    END AS period_code,
    CAST(NULL AS STRING) AS doi_tuong,
    CAST(NULL AS STRING) AS nganh,
    'CP' AS loai_ck,
    'NA' AS huy_dong_von, -- Không phân loại
    CASE
      WHEN TRIM(a.loai_hinh_dau_gia) IN ('Cổ phần hóa') THEN 'Cổ phần hóa (IPO)'
      WHEN TRIM(a.loai_hinh_dau_gia) IN (
          'Bán phần vốn Nhà nước', 'Bán phần vốn Nhà nước (chào bán cạnh tranh)', 'Bán phần vốn Nhà nước (Đấu giá cả lô cổ phần)',
          'Đấu giá phần góp vốn', 'Thoái phần vốn nhà nước', 'Chào bán cạnh tranh cả lô cổ phần (Bán phần vốn Nhà nước)')
        THEN 'Thoái vốn'
      WHEN TRIM(a.loai_hinh_dau_gia) IN ('Bán phần vốn Nhà nước (Đấu giá quyền mua cổ phiếu)', 'Bán CP ra công chúng của cổ đông lớn theo giấy phép UBCK', 'Bán CP ra công chúng theo giấy phép UBCK')
        THEN 'Phát hành ra công chúng / quyền mua'
      ELSE 'Đấu giá - Khác'
    END AS nhom_hinhthuc, -- nhom_loai_hinh_dau_gia
    SUM(a.kl_dangky) AS kl_dangky,
    SUM(a.kl_tc) AS kl_tc,
    CAST(NULL AS DECIMAL(38, 2)) AS gt_dangky, -- Không có GT đăng ký
    SUM(a.gt_tc) AS gt_tc,
    SUM(a.gt_ndtnn) AS gt_ndtnn,
    CAST(NULL AS DECIMAL(38, 2)) AS tyle_tc_tuso, -- Không có GT đăng ký -> không tính tỷ lệ
    CAST(NULL AS DECIMAL(38, 2)) AS tyle_tc_mauso,
    CAST(NULL AS DECIMAL(38, 4)) AS kyhanbq_tuso,
    CAST(NULL AS DECIMAL(38, 2)) AS kyhanbq_mauso,
    CAST(NULL AS DECIMAL(38, 4)) AS laisuatbq_tuso,
    CAST(NULL AS DECIMAL(38, 2)) AS laisuatbq_mauso
  FROM (
    -- Chuyển dòng thành cột: 1 dòng = 1 đợt đấu giá (report_code x tháng báo cáo x row_num)
    SELECT
      MAKE_DATE(CAST(f.report_year AS INT), CAST(f.report_month AS INT), 1) AS report_month_startdate,
      MAX(IF(f.metric_name = 'LOẠI HÌNH ĐẤU GIÁ', f.field_value, NULL)) AS loai_hinh_dau_gia,
      SUM(IF(f.metric_name = 'SỐ CP ĐĂNG KÝ CHÀO BÁN', CAST(f.field_value AS DECIMAL(38, 10)), NULL)) AS kl_dangky,
      SUM(IF(f.metric_name IN ('SỐ CP TRÚNG GIÁ > NĐT NƯỚC NGOÀI', 'SỐ CP TRÚNG GIÁ > NĐT TRONG NƯỚC',
                               'SỐ CP TRÚNG GIÁ(CHỨNG KHOÁN) > NĐT NƯỚC NGOÀI', 'SỐ CP TRÚNG GIÁ(CHỨNG KHOÁN) > NĐT TRONG NƯỚC'),
             CAST(f.field_value AS DECIMAL(38, 10)), NULL)) AS kl_tc,
      SUM(IF(f.metric_name IN ('GIÁ TRỊ CP TRÚNG GIÁ > NĐT TRONG NƯỚC (VND)', 'GIÁ TRỊ CP TRÚNG GIÁ(VND) > NĐT TRONG NƯỚC',
                               'GIÁ TRỊ CP TRÚNG GIÁ > NĐT NƯỚC NGOÀI (VND)', 'GIÁ TRỊ CP TRÚNG GIÁ(VND) > NĐT NƯỚC NGOÀI'),
             CAST(f.field_value AS DECIMAL(38, 10)), NULL)) AS gt_tc,
      SUM(IF(f.metric_name IN ('GIÁ TRỊ CP TRÚNG GIÁ > NĐT NƯỚC NGOÀI (VND)', 'GIÁ TRỊ CP TRÚNG GIÁ(VND) > NĐT NƯỚC NGOÀI'),
             CAST(f.field_value AS DECIMAL(38, 10)), NULL)) AS gt_ndtnn
    FROM (
      SELECT
        r.report_code, r.report_year, r.report_month, r.row_num,
        TRIM(REGEXP_REPLACE(r.column_path, '\\s+', ' ')) AS metric_name, -- Chuẩn hóa tên cột
        r.field_value
      FROM uat_iss_ods.flat_report r
      WHERE r.submit_status IN ('SUBMITTED', 'LATE_SUBMITTED')
        AND r.submit_source = 'ICP'
        AND r.report_code IN ('HNX05', 'HSX03')
        AND r.sheet_name = 'sheet 1'
        AND TRIM(REGEXP_REPLACE(r.column_path, '\\s+', ' ')) IN (
            'LOẠI HÌNH ĐẤU GIÁ', 'SỐ CP ĐĂNG KÝ CHÀO BÁN',
            'SỐ CP TRÚNG GIÁ > NĐT NƯỚC NGOÀI', 'SỐ CP TRÚNG GIÁ > NĐT TRONG NƯỚC',
            'SỐ CP TRÚNG GIÁ(CHỨNG KHOÁN) > NĐT NƯỚC NGOÀI', 'SỐ CP TRÚNG GIÁ(CHỨNG KHOÁN) > NĐT TRONG NƯỚC',
            'GIÁ TRỊ CP TRÚNG GIÁ > NĐT TRONG NƯỚC (VND)', 'GIÁ TRỊ CP TRÚNG GIÁ(VND) > NĐT TRONG NƯỚC',
            'GIÁ TRỊ CP TRÚNG GIÁ > NĐT NƯỚC NGOÀI (VND)', 'GIÁ TRỊ CP TRÚNG GIÁ(VND) > NĐT NƯỚC NGOÀI')
        AND r.ds_snpst_dt = '2026-10-22'
    ) f
    GROUP BY f.report_code, f.report_year, f.report_month, f.row_num
  ) a
  CROSS JOIN params p
  WHERE p.period_type <> 'D' -- Kỳ D: không có số liệu (báo cáo tháng)
    AND a.report_month_startdate BETWEEN TRUNC(p.from_date, 'MM') AND TRUNC(p.to_date, 'MM')
  GROUP BY 1, 6
)
-- =========== 7. KẾT QUẢ: Kỳ x Đối tượng x Loại CK x Huy động vốn x Nhóm hình thức ===========
SELECT
  p.period_type,
  a.period_code,
  a.doi_tuong,
  a.nganh,
  a.loai_ck,
  a.huy_dong_von,
  a.nhom_hinhthuc,
  CAST(a.kl_dangky AS DECIMAL(38, 2)) AS kl_dangky, -- KL phát hành - Đăng ký
  CAST(a.kl_tc     AS DECIMAL(38, 2)) AS kl_tc,     -- KL phát hành - Thành công
  CAST(a.gt_dangky AS DECIMAL(38, 2)) AS gt_dangky, -- GT phát hành - Đăng ký
  CAST(a.gt_tc     AS DECIMAL(38, 2)) AS gt_tc,     -- GT phát hành - Thành công
  CAST(a.gt_ndtnn  AS DECIMAL(38, 2)) AS gt_ndtnn,  -- GT phát hành cho NĐTNN
  -- Tử số / mẫu số (SUM theo chiều được chọn rồi mới chia)
  CAST(a.tyle_tc_tuso  AS DECIMAL(38, 2)) AS tyle_tc_tuso,  CAST(a.tyle_tc_mauso  AS DECIMAL(38, 2)) AS tyle_tc_mauso,
  CAST(a.kyhanbq_tuso    AS DECIMAL(38, 4)) AS kyhanbq_tuso,    CAST(a.kyhanbq_mauso    AS DECIMAL(38, 2)) AS kyhanbq_mauso,
  CAST(a.laisuatbq_tuso  AS DECIMAL(38, 4)) AS laisuatbq_tuso,  CAST(a.laisuatbq_mauso  AS DECIMAL(38, 2)) AS laisuatbq_mauso,
  -- Tỷ lệ / BQ tại mức chi tiết của dòng
  ROUND(a.tyle_tc_tuso / NULLIF(a.tyle_tc_mauso, 0) * 100, 2) AS tyle_tc_pct,   -- Tỷ lệ thực hiện thành công (%)
  ROUND(a.kyhanbq_tuso / NULLIF(a.kyhanbq_mauso, 0), 2) AS kyhan_bq_nam,             -- Kỳ hạn phát hành BQ (năm)
  ROUND(a.laisuatbq_tuso / NULLIF(a.laisuatbq_mauso, 0), 4) AS laisuat_bq_pct        -- Lãi suất phát hành BQ (%)
FROM (
  SELECT * FROM ubck_agg
  UNION ALL
  SELECT * FROM private_corpbond_agg
  UNION ALL
  SELECT * FROM govbond_agg
  UNION ALL
  SELECT * FROM auction_agg -- Đấu giá
) a
CROSS JOIN params p
ORDER BY a.period_code, a.loai_ck, a.doi_tuong, a.nganh, a.huy_dong_von, a.nhom_hinhthuc
;