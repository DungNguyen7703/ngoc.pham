-- CHỈ TIÊU TÀI KHOẢN NĐT THEO KỲ (D/M/Q/Y) - Spark SQL 3.5
/* Tham số:
 *  :period_type  Loại kỳ: D (Ngày) | M (Tháng) | Q (Quý) | Y (Năm)
 *  :period_code  Kỳ: D = yyyy-MM-dd | M = yyyy-MM | Q = yyyy-Q[1-4] | Y = yyyy
 * Loại TK: 3 Cá nhân trong nước | 4 Cá nhân nước ngoài | 5 Pháp nhân trong nước | 6 Pháp nhân nước ngoài | 7 Nhà nước | KHAC (NULL/giá trị khác) | TONG
 * Logic xác định trạng thái hoạt động tại ngày cuối kỳ:
 *  - Gộp event mở/đóng theo TK + ngày; Đối với ngày có cả mở và đóng thì bỏ qua vì không đổi trạng thái
 *  - Hoạt động khi ngày "chỉ mở" gần nhất <= [Ngày chốt] mới hơn ngày "chỉ đóng" gần nhất <= [Ngày chốt] (hoặc chưa có ngày chỉ đóng)
 * Mốc tính: CUR = ngày cuối kỳ | PREV = ngày cuối kỳ trước (= ngày đầu kỳ - 1) | PY = 31/12 năm trước của ngày cuối kỳ
 */
WITH
-- 1. THAM SỐ: Kỳ -> Lấy ra ngày đầu kỳ, cuối kỳ, cuối kỳ trước, cuối năm trước
params AS (
  SELECT
    q.period_type, q.period_code, q.period_start, q.period_end,
    DATE_SUB(q.period_start, 1) AS prev_end,  -- Ngày cuối kỳ trước (D: ngày liền trước; M/Q/Y: ngày cuối tháng/quý/năm trước)
    MAKE_DATE(YEAR(q.period_end) - 1, 12, 31) AS py_end -- Ngày cuối năm trước
  FROM (
    SELECT
      s.period_type, s.period_code, s.period_start,
      CASE s.period_type
        WHEN 'D' THEN s.period_start
        WHEN 'M' THEN LAST_DAY(s.period_start)
        WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(s.period_start, 2))
        WHEN 'Y' THEN LAST_DAY(ADD_MONTHS(s.period_start, 11))
      END AS period_end  -- Ngày cuối kỳ
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
-- 3. Xác định trạng thái hoạt động của TK tại từng mốc: hoạt động khi có ngày chỉ mở và (chưa có ngày chỉ đóng hoặc chỉ mở mới hơn chỉ đóng)
, acc_flag AS (
  SELECT
    trading_account_no, 
    investor_type,
    (open_cur IS NOT NULL AND (close_cur IS NULL OR open_cur > close_cur)) AS act_cur,
    (open_prev IS NOT NULL AND (close_prev IS NULL OR open_prev > close_prev)) AS act_prev,
    (open_py IS NOT NULL AND (close_py IS NULL OR open_py > close_py)) AS act_py
  FROM (
    -- Bước 2. Tại 3 mốc CUR/PREV/PY: Lấy ngày "chỉ mở" / "chỉ đóng" gần nhất của từng tài khoản để xác định trạng thái, Ngày trùng (TK vừa mở vừa đóng trong ngày) bỏ qua do không thay đổi trạng thái
    SELECT
      d.trading_account_no,
      d.investor_type,
      MAX(CASE WHEN d.has_open  AND NOT d.has_close AND d.event_date <= p.period_end THEN d.event_date END) AS open_cur,   -- Ngày chỉ mở gần nhất <= ngày báo cáo
      MAX(CASE WHEN d.has_close AND NOT d.has_open  AND d.event_date <= p.period_end THEN d.event_date END) AS close_cur,  -- Ngày chỉ đóng gần nhất <= ngày báo cáo
      MAX(CASE WHEN d.has_open  AND NOT d.has_close AND d.event_date <= p.prev_end   THEN d.event_date END) AS open_prev,  -- Ngày chỉ mở gần nhất <= ngày cuối kỳ trước
      MAX(CASE WHEN d.has_close AND NOT d.has_open  AND d.event_date <= p.prev_end   THEN d.event_date END) AS close_prev, -- Ngày chỉ đóng gần nhất <= ngày cuối kỳ trước
      MAX(CASE WHEN d.has_open  AND NOT d.has_close AND d.event_date <= p.py_end     THEN d.event_date END) AS open_py,    -- Ngày chỉ mở gần nhất <= ngày cuối năm trước
      MAX(CASE WHEN d.has_close AND NOT d.has_open  AND d.event_date <= p.py_end     THEN d.event_date END) AS close_py    -- Ngày chỉ đóng gần nhất <= ngày cuối năm trước
    FROM (
      -- Bước 1. Gộp event mở/đóng theo tài khoản x ngày (<= ngày cuối kỳ)
      SELECT
        e.trading_account_no, e.investor_type, e.event_date, 
        BOOL_OR(e.event_type = 'OPEN')  AS has_open, -- Ngày có mở tk không
        BOOL_OR(e.event_type = 'CLOSE') AS has_close -- Ngày có đóng tk không
      FROM (
        SELECT o.trading_account_no, o.open_date AS event_date, 'OPEN' AS event_type, o.investor_type
        FROM uat_vsdc_stg.open_investors o
        CROSS JOIN params p
        WHERE open_date <= p.period_end --> Lọc dữ liệu <= Ngày cuối kỳ
        UNION ALL
        SELECT c.trading_account_no, c.close_date AS event_date, 'CLOSE' AS event_type, c.investor_type
        FROM uat_vsdc_stg.closed_investors c
        CROSS JOIN params p
        WHERE c.close_date <= p.period_end --> Lọc dữ liệu <= Ngày cuối kỳ
      ) e
      GROUP BY e.trading_account_no, e.investor_type, e.event_date
    ) d
    CROSS JOIN params p
    GROUP BY d.trading_account_no, d.investor_type
  )
)
-- 4. Đếm số TK theo loại TK (investor_type 3-7, giá trị khác/NULL gộp vào KHAC); mỗi cột là 1 chỉ tiêu 
, acc_cnt AS (
  SELECT
    loai_tk,
    -- Số TK hoạt động tại ngày cuối kỳ / cuối kỳ trước / cuối năm trước
    COUNT(CASE WHEN act_cur THEN 1 END) AS cnt_cur,
    COUNT(CASE WHEN act_prev THEN 1 END) AS cnt_prev,
    COUNT(CASE WHEN act_py THEN 1 END) AS cnt_py,
    -- TK mở mới = không hoạt động cuối kỳ trước và hoạt động cuối kỳ này; TK đóng = hoạt động cuối kỳ trước và không hoạt động cuối kỳ này
    COUNT(CASE WHEN act_cur AND NOT act_prev THEN 1 END) AS cnt_new,   
    COUNT(CASE WHEN act_prev AND NOT act_cur THEN 1 END) AS cnt_closed 
  FROM (
    SELECT
      CASE WHEN investor_type IN ('3', '4', '5', '6', '7') THEN investor_type ELSE 'KHAC' END AS loai_tk,
      act_cur, act_prev, act_py
    FROM acc_flag
  ) f
  GROUP BY loai_tk
)
-- 5. Ghép với danh mục loại TK: luôn đủ các dòng loại TK (kể cả = 0), dòng TONG = cộng tất cả loại TK
, cnt AS (
  SELECT
    l.loai_tk, l.ten_loai_tk, l.stt,
    COALESCE(SUM(a.cnt_cur), 0)    AS cnt_cur,
    COALESCE(SUM(a.cnt_prev), 0)   AS cnt_prev,
    COALESCE(SUM(a.cnt_py), 0)     AS cnt_py,
    COALESCE(SUM(a.cnt_new), 0)    AS cnt_new,
    COALESCE(SUM(a.cnt_closed), 0) AS cnt_closed
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
  -- 6.4. TK mở mới (chỉ dòng tổng)
  SELECT
    4, 'tk_mo_moi', 'Số lượng TK mở mới (mở trong kỳ và chưa đóng đến cuối kỳ)',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST(c.cnt_new AS DOUBLE), 'TK'
  FROM cnt c
  WHERE c.loai_tk = 'TONG'
  UNION ALL
  -- 6.5. TK đóng (chỉ dòng tổng)
  SELECT
    5, 'tk_dong', 'Số lượng TK đóng (đóng trong kỳ và chưa mở lại đến cuối kỳ)',
    c.loai_tk, c.ten_loai_tk, c.stt, CAST(c.cnt_closed AS DOUBLE), 'TK'
  FROM cnt c
  WHERE c.loai_tk = 'TONG'
) r
ORDER BY r.metric_stt, r.stt
;
