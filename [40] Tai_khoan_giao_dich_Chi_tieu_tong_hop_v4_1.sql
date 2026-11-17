-- CHỈ TIÊU TÀI KHOẢN NĐT THEO KỲ (D/M/Q/Y) - Spark SQL 3.5
/* Tham số:
 *  :period_type  Loại kỳ: D (Ngày) | M (Tháng) | Q (Quý) | Y (Năm)
 *  :period_code  Kỳ: D = yyyy-MM-dd | M = yyyy-MM | Q = yyyy-Q[1-4] | Y = yyyy
 * Loại TK (investor_type): 3 Cá nhân trong nước | 4 Cá nhân nước ngoài | 5 Pháp nhân trong nước | 6 Pháp nhân nước ngoài | 7 Nhà nước | KHAC (NULL/giá trị khác) | TONG
 * Quy tắc tính (dữ liệu mở/đóng tài khoản đầy đủ, mỗi lần mở/đóng là 1 bản ghi, không trùng):
 *  - Số TK hoạt động tại ngày D (lũy kế) = số bản ghi mở có ngày <= D - số bản ghi đóng có ngày <= D
 *  - TK mở mới trong kỳ = Có ngày mở trong kỳ [ngày đầu kỳ, ngày cuối kỳ]
 *  - TK đóng trong kỳ   = Có ngày đóng trong kỳ [ngày đầu kỳ, ngày cuối kỳ]
 * Chỉ tiêu:
 *  1-3. Tổng số TK hoạt động: số lượng, % so với kỳ trước, % so với cuối năm trước (chi tiết theo loại TK)
 *  4-5. TK mở mới, TK đóng trong kỳ (dòng tổng)
 *  6-9. TK mở mới, TK đóng: % so với kỳ trước, % so với cùng kỳ năm trước (dòng tổng)
 */
WITH
-- 1. THAM SỐ: Kỳ -> Lấy ra [ngày đầu kỳ, ngày cuối kỳ] của kỳ báo cáo / kỳ trước / cùng kỳ năm trước, Ngày cuối năm trước
params AS (
  SELECT
    q.period_type, q.period_code, q.period_start, q.period_end,
    q.prev_start,                                         -- Ngày đầu kỳ trước
    DATE_SUB(q.period_start, 1) AS prev_end,              -- Ngày cuối kỳ trước (D: ngày liền trước; M/Q/Y: ngày cuối tháng/quý/năm trước)
    MAKE_DATE(YEAR(q.period_end) - 1, 12, 31) AS py_end,  -- Ngày cuối năm trước
    q.ly_start,                                           -- Ngày đầu kỳ cùng kỳ năm trước
    CASE q.period_type
      WHEN 'D' THEN q.ly_start
      WHEN 'M' THEN LAST_DAY(q.ly_start)
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(q.ly_start, 2))
      WHEN 'Y' THEN LAST_DAY(ADD_MONTHS(q.ly_start, 11))
    END AS ly_end                                         -- Ngày cuối kỳ cùng kỳ năm trước
  FROM (
    SELECT
      s.period_type, s.period_code, s.period_start,
      CASE s.period_type
        WHEN 'D' THEN s.period_start
        WHEN 'M' THEN LAST_DAY(s.period_start)
        WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(s.period_start, 2))
        WHEN 'Y' THEN LAST_DAY(ADD_MONTHS(s.period_start, 11))
      END AS period_end,  -- Ngày cuối kỳ
      CASE s.period_type
        WHEN 'D' THEN DATE_SUB(s.period_start, 1)
        WHEN 'M' THEN ADD_MONTHS(s.period_start, -1)
        WHEN 'Q' THEN ADD_MONTHS(s.period_start, -3)
        WHEN 'Y' THEN ADD_MONTHS(s.period_start, -12)
      END AS prev_start,  -- Ngày đầu kỳ trước
      ADD_MONTHS(s.period_start, -12) AS ly_start -- Ngày đầu kỳ cùng kỳ năm trước
    FROM (
      SELECT
        :period_type AS period_type, -- Loại kỳ
        :period_code AS period_code, -- Kỳ
        CASE :period_type
          WHEN 'D' THEN TO_DATE(:period_code, 'yyyy-MM-dd')
          WHEN 'M' THEN TO_DATE(CONCAT(:period_code, '-01'), 'yyyy-MM-dd')
          WHEN 'Q' THEN MAKE_DATE(CAST(SUBSTR(:period_code, 1, 4) AS INT), (CAST(SUBSTR(:period_code, 7, 1) AS INT) - 1) * 3 + 1, 1)
          WHEN 'Y' THEN MAKE_DATE(CAST(:period_code AS INT), 1, 1)
        END AS period_start -- Ngày đầu kỳ
    ) s
  ) q
)
-- 2. Danh mục loại tài khoản
, loai AS (
  SELECT * FROM VALUES
    ('3',     'Cá nhân trong nước',    1),
    ('4',     'Cá nhân nước ngoài',    2),
    ('5',     'Pháp nhân trong nước',  3),
    ('6',     'Pháp nhân nước ngoài',  4),
    ('7',     'Nhà nước',              5),
    ('KHAC',  'Khác/Chưa phân loại',   6),
    ('TONG',  'Tổng',                  7)
  AS t(loai_tk, ten_loai_tk, stt)
)
-- 3. Event mở/đóng tài khoản <= ngày cuối kỳ: mỗi bản ghi mở (is_open = 1) hoặc đóng (is_close = 1) kèm loại TK
, acc_event AS (
  SELECT
    o.open_date AS event_date, 1 AS is_open, 0 AS is_close,
    CASE WHEN o.investor_type IN ('3', '4', '5', '6', '7') THEN o.investor_type ELSE 'KHAC' END AS loai_tk
  FROM uat_vsdc_stg.open_investors o
  JOIN params p ON o.open_date <= p.period_end --> Lọc dữ liệu <= Ngày cuối kỳ
  UNION ALL
  SELECT
    c.close_date AS event_date, 0 AS is_open, 1 AS is_close,
    CASE WHEN c.investor_type IN ('3', '4', '5', '6', '7') THEN c.investor_type ELSE 'KHAC' END AS loai_tk
  FROM uat_vsdc_stg.closed_investors c
  JOIN params p ON c.close_date <= p.period_end --> Lọc dữ liệu <= Ngày cuối kỳ
)
-- 4. Đếm theo loại TK (investor_type 3-7, giá trị khác/NULL gộp vào KHAC); mỗi cột là 1 chỉ tiêu
----   cnt_cur / cnt_prev / cnt_py : số TK hoạt động lũy kế (mở - đóng) đến ngày cuối kỳ / cuối kỳ trước / cuối năm trước
----   cnt_new / cnt_closed        : số TK mở / đóng trong kỳ báo cáo
----   cnt_new_prev / cnt_closed_prev : số TK mở / đóng trong kỳ trước
----   cnt_new_ly / cnt_closed_ly     : số TK mở / đóng trong cùng kỳ năm trước
, acc_cnt AS (
  SELECT
    e.loai_tk,
    SUM(e.is_open - e.is_close) AS cnt_cur, -- Event đã lọc <= ngày cuối kỳ
    SUM(CASE WHEN e.event_date <= p.prev_end THEN e.is_open - e.is_close ELSE 0 END) AS cnt_prev,
    SUM(CASE WHEN e.event_date <= p.py_end   THEN e.is_open - e.is_close ELSE 0 END) AS cnt_py,
    SUM(CASE WHEN e.event_date BETWEEN p.period_start AND p.period_end THEN e.is_open  ELSE 0 END) AS cnt_new,
    SUM(CASE WHEN e.event_date BETWEEN p.period_start AND p.period_end THEN e.is_close ELSE 0 END) AS cnt_closed,
    SUM(CASE WHEN e.event_date BETWEEN p.prev_start   AND p.prev_end   THEN e.is_open  ELSE 0 END) AS cnt_new_prev,
    SUM(CASE WHEN e.event_date BETWEEN p.prev_start   AND p.prev_end   THEN e.is_close ELSE 0 END) AS cnt_closed_prev,
    SUM(CASE WHEN e.event_date BETWEEN p.ly_start     AND p.ly_end     THEN e.is_open  ELSE 0 END) AS cnt_new_ly,
    SUM(CASE WHEN e.event_date BETWEEN p.ly_start     AND p.ly_end     THEN e.is_close ELSE 0 END) AS cnt_closed_ly
  FROM acc_event e
  CROSS JOIN params p
  GROUP BY e.loai_tk
)
-- 5. Ghép với danh mục loại TK: luôn đủ các dòng loại TK (kể cả = 0), dòng TONG = cộng tất cả loại TK
, cnt AS (
  SELECT
    l.loai_tk, l.ten_loai_tk, l.stt,
    COALESCE(SUM(a.cnt_cur), 0)         AS cnt_cur,
    COALESCE(SUM(a.cnt_prev), 0)        AS cnt_prev,
    COALESCE(SUM(a.cnt_py), 0)          AS cnt_py,
    COALESCE(SUM(a.cnt_new), 0)         AS cnt_new,
    COALESCE(SUM(a.cnt_closed), 0)      AS cnt_closed,
    COALESCE(SUM(a.cnt_new_prev), 0)    AS cnt_new_prev,
    COALESCE(SUM(a.cnt_closed_prev), 0) AS cnt_closed_prev,
    COALESCE(SUM(a.cnt_new_ly), 0)      AS cnt_new_ly,
    COALESCE(SUM(a.cnt_closed_ly), 0)   AS cnt_closed_ly
  FROM loai l
  LEFT JOIN acc_cnt a ON l.loai_tk = 'TONG' OR l.loai_tk = a.loai_tk -- acc_cnt chỉ có tối đa 6 dòng nên ghép OR không ảnh hưởng hiệu năng
  GROUP BY l.loai_tk, l.ten_loai_tk, l.stt
)
-- 6. Kết quả: mỗi dòng 1 chỉ tiêu x 1 loại TK
SELECT
  p.period_type, p.period_code, p.period_start, p.period_end,
  r.metric_stt, r.metric_code, r.metric_name,
  r.loai_tk, r.ten_loai_tk, r.gia_tri, r.don_vi
FROM params p
CROSS JOIN (
  -- 6.1. Tổng số TK hoạt động (chi tiết theo loại TK)
  SELECT
    1 AS metric_stt, 'tk_hoat_dong' AS metric_code, 'Tổng số tài khoản hoạt động (đến ngày cuối kỳ)' AS metric_name,
    c.loai_tk, c.ten_loai_tk, c.stt, CAST(c.cnt_cur AS DOUBLE) AS gia_tri, 'TK' AS don_vi
  FROM cnt c
  UNION ALL
  -- 6.2. % so với kỳ trước (chi tiết theo loại TK)
  SELECT
    2, 'tk_hoat_dong_pct_kytruoc', 'Tổng số tài khoản hoạt động - % so với kỳ trước',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST((c.cnt_cur - c.cnt_prev) / NULLIF(c.cnt_prev, 0) * 100 AS DOUBLE), '%'
  FROM cnt c
  UNION ALL
  -- 6.3. % so với cuối năm trước (chi tiết theo loại TK)
  SELECT
    3, 'tk_hoat_dong_pct_cuoinamtruoc', 'Tổng số tài khoản hoạt động - % so với cuối năm trước',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST((c.cnt_cur - c.cnt_py) / NULLIF(c.cnt_py, 0) * 100 AS DOUBLE), '%'
  FROM cnt c
  UNION ALL
  -- 6.4. TK mở mới trong kỳ (chỉ dòng tổng)
  SELECT
    4, 'tk_mo_moi', 'Số lượng TK mở mới trong kỳ',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST(c.cnt_new AS DOUBLE), 'TK'
  FROM cnt c
  WHERE c.loai_tk = 'TONG'
  UNION ALL
  -- 6.5. TK đóng trong kỳ (chỉ dòng tổng)
  SELECT
    5, 'tk_dong', 'Số lượng TK đóng trong kỳ',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST(c.cnt_closed AS DOUBLE), 'TK'
  FROM cnt c
  WHERE c.loai_tk = 'TONG'
  UNION ALL
  -- 6.6. TK mở mới - % so với kỳ trước (chỉ dòng tổng)
  SELECT
    6, 'tk_mo_moi_pct_kytruoc', 'Số lượng TK mở mới - % so với kỳ trước',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST((c.cnt_new - c.cnt_new_prev) / NULLIF(c.cnt_new_prev, 0) * 100 AS DOUBLE), '%'
  FROM cnt c
  WHERE c.loai_tk = 'TONG'
  UNION ALL
  -- 6.7. TK mở mới - % so với cùng kỳ năm trước (chỉ dòng tổng)
  SELECT
    7, 'tk_mo_moi_pct_cungkynamtruoc', 'Số lượng TK mở mới - % so với cùng kỳ năm trước',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST((c.cnt_new - c.cnt_new_ly) / NULLIF(c.cnt_new_ly, 0) * 100 AS DOUBLE), '%'
  FROM cnt c
  WHERE c.loai_tk = 'TONG'
  UNION ALL
  -- 6.8. TK đóng - % so với kỳ trước (chỉ dòng tổng)
  SELECT
    8, 'tk_dong_pct_kytruoc', 'Số lượng TK đóng - % so với kỳ trước',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST((c.cnt_closed - c.cnt_closed_prev) / NULLIF(c.cnt_closed_prev, 0) * 100 AS DOUBLE), '%'
  FROM cnt c
  WHERE c.loai_tk = 'TONG'
  UNION ALL
  -- 6.9. TK đóng - % so với cùng kỳ năm trước (chỉ dòng tổng)
  SELECT
    9, 'tk_dong_pct_cungkynamtruoc', 'Số lượng TK đóng - % so với cùng kỳ năm trước',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST((c.cnt_closed - c.cnt_closed_ly) / NULLIF(c.cnt_closed_ly, 0) * 100 AS DOUBLE), '%'
  FROM cnt c
  WHERE c.loai_tk = 'TONG'
) r
ORDER BY r.metric_stt, r.stt
;
