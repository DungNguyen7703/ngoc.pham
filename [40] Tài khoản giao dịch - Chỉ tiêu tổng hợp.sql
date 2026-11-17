-- 40. TÀI KHOẢN GIAO DỊCH >> CHỈ TIÊU TỔNG HỢP
/* Tham số:
 *  :period_type  Loại kỳ: D (Ngày) | M (Tháng) | Q (Quý) | Y (Năm)
 *  :period_code  Kỳ: D = yyyy-MM-dd | M = yyyy-MM | Q = yyyy-Q[1-4] | Y = yyyy
 * Loại TK (investor_type): 3 Cá nhân trong nước | 4 Cá nhân nước ngoài | 5 Pháp nhân trong nước | 6 Pháp nhân nước ngoài | 7 Nhà nước | KHAC (NULL/giá trị khác) | TOTAL (Tổng)
 * Logic:
 *  - Số TK hoạt động tại ngày D (lũy kế) = số bản ghi mở có ngày <= D - số bản ghi đóng có ngày <= D
 *  - TK mở mới trong kỳ = Có ngày mở trong kỳ [ngày đầu kỳ, ngày cuối kỳ]
 *  - TK đóng trong kỳ   = Có ngày đóng trong kỳ [ngày đầu kỳ, ngày cuối kỳ]
 */
WITH
-- 1. THAM SỐ: Kỳ -> Lấy ra [ngày đầu kỳ, ngày cuối kỳ] của kỳ báo cáo / kỳ trước / cùng kỳ năm trước, Ngày cuối năm trước
params AS (
  SELECT
    q.period_type, q.period_code, q.period_start, q.period_end,
    q.prev_start,                                         -- Ngày đầu kỳ trước
    DATE_SUB(q.period_start, 1) AS prev_end,              -- Ngày cuối kỳ trước (D: ngày liền trước; M/Q/Y: ngày cuối tháng/quý/năm trước)
    MAKE_DATE(YEAR(q.period_end) - 1, 12, 31) AS py_end,  -- Ngày cuối năm trước
    q.py_sameperiod_start,                                -- Ngày đầu kỳ cùng kỳ năm trước
    CASE q.period_type
      WHEN 'D' THEN q.py_sameperiod_start
      WHEN 'M' THEN LAST_DAY(q.py_sameperiod_start)
      WHEN 'Q' THEN LAST_DAY(ADD_MONTHS(q.py_sameperiod_start, 2))
      WHEN 'Y' THEN LAST_DAY(ADD_MONTHS(q.py_sameperiod_start, 11))
    END AS py_sameperiod_end -- Ngày cuối kỳ cùng kỳ năm trước
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
      ADD_MONTHS(s.period_start, -12) AS py_sameperiod_start -- Ngày đầu kỳ cùng kỳ năm trước
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
-- Tính tổng tài khoản mở, đóng theo ngày
, count_acc_open_close_daily AS (
  SELECT 
    IF(o.investor_type IN ('3','4','5','6','7'), o.investor_type, 'NA') AS investor_type, 
    'OPEN' event_type, o.open_date AS event_date, COUNT(o.trading_account_no) acc_cnt
  FROM uat_vsdc_stg.open_investors o
  JOIN params p ON o.open_date <= p.period_end --> Lọc dữ liệu <= Ngày cuối kỳ
  GROUP BY o.investor_type, o.open_date
  UNION ALL
  SELECT 
    IF(c.investor_type IN ('3','4','5','6','7'), c.investor_type, 'NA') AS investor_type,
    'CLOSE' event_type, c.close_date AS event_date, COUNT(c.trading_account_no) acc_cnt
  FROM uat_vsdc_stg.closed_investors c
  JOIN params p ON c.close_date <= p.period_end --> Lọc dữ liệu <= Ngày cuối kỳ
  GROUP BY c.investor_type, c.close_date
)
-- Tính tổng tài khoản lũy kế, tài khoản mở/đóng trong kỳ: Kỳ báo cáo, Kỳ trước, Cùng kỳ năm trước
, count_acc_agg AS (
  SELECT 
    investor_type,
    GROUPING(investor_type) AS is_total,
    -- Tổng số tài khoản lũy kế = OPEN - CLOSE tại từng mốc.
    SUM(IF(event_type = 'OPEN', NVL(cnt_cur_cum, 0), 0)) - SUM(IF(event_type = 'CLOSE', NVL(cnt_cur_cum, 0), 0)) AS total_cur_cum,
    SUM(IF(event_type = 'OPEN', NVL(cnt_prev_cum, 0), 0)) - SUM(IF(event_type = 'CLOSE', NVL(cnt_prev_cum, 0), 0)) AS total_prev_cum,
    SUM(IF(event_type = 'OPEN', NVL(cnt_py_cum, 0), 0)) - SUM(IF(event_type = 'CLOSE', NVL(cnt_py_cum, 0), 0)) AS total_py_cum,
    -- Số tài khoản mở trong kỳ, kỳ trước, cùng kỳ năm trước.
    SUM(IF(event_type = 'OPEN', NVL(cnt_cur, 0), 0)) AS open_cur,
    SUM(IF(event_type = 'OPEN', NVL(cnt_prev, 0), 0)) AS open_prev,
    SUM(IF(event_type = 'OPEN', NVL(cnt_py_sameperiod, 0), 0)) AS open_py_sameperiod,
    -- Số tài khoản đóng trong kỳ, kỳ trước, cùng kỳ năm trước.
    SUM(IF(event_type = 'CLOSE', NVL(cnt_cur, 0), 0)) AS close_cur,
    SUM(IF(event_type = 'CLOSE', NVL(cnt_prev, 0), 0)) AS close_prev,
    SUM(IF(event_type = 'CLOSE', NVL(cnt_py_sameperiod, 0), 0)) AS close_py_sameperiod
  FROM (
    -- Tổng số TK mở/đóng theo từng loại tài khoản
    SELECT 
      i.event_type,
      i.investor_type,
      -- Tổng TK mở/đóng lũy kế
      SUM(IF(i.event_date <= period_end, acc_cnt, 0)) AS cnt_cur_cum, 
      SUM(IF(i.event_date <= prev_end, acc_cnt, 0)) AS cnt_prev_cum,
      SUM(IF(i.event_date <= py_end, acc_cnt, 0)) AS cnt_py_cum,
      -- Tổng TK mở/đóng trong kỳ
      SUM(IF(i.event_date BETWEEN p.period_start AND p.period_end, acc_cnt, 0)) AS cnt_cur,
      SUM(IF(i.event_date BETWEEN p.prev_start AND p.prev_end, acc_cnt, 0)) AS cnt_prev,
      SUM(IF(i.event_date BETWEEN p.py_sameperiod_start AND p.py_sameperiod_end, acc_cnt, 0)) AS cnt_py_sameperiod
    FROM count_acc_open_close_daily i 
    CROSS JOIN params p 
    WHERE i.event_date <= p.period_end 
    GROUP BY i.event_type, i.investor_type
  )
  GROUP BY GROUPING SETS ((investor_type), ())
) 
-- Chỉ tiêu báo cáo
SELECT
  IF(is_total = 1, 'TOTAL', investor_type) AS investor_type,
  CASE 
    WHEN is_total = 1 THEN 'Tổng'
    WHEN investor_type = '3' THEN 'Cá nhân trong nước'
    WHEN investor_type = '4' THEN 'Cá nhân nước ngoài'
    WHEN investor_type = '5' THEN 'Tổ chức trong nước'
    WHEN investor_type = '6' THEN 'Tổ chức nước ngoài'
    WHEN investor_type = '7' THEN 'Nhà nước'
    ELSE 'Khác'
  END AS investor_type_name,
  -- 1. Tổng số tài khoản lũy kế và % thay đổi.
  total_cur_cum,
  total_prev_cum,
  total_py_cum,
  (total_cur_cum - total_prev_cum) / NULLIF(total_prev_cum, 0) * 100 AS pct_total_vs_prev_period,
  (total_cur_cum  - total_py_cum) / NULLIF(total_py_cum, 0) * 100 AS pct_total_vs_prev_year_end,
  -- 2. Số tài khoản mở trong kỳ và % thay đổi.
  open_cur,
  open_prev,
  open_py_sameperiod,
  (open_cur - open_prev) / NULLIF(open_prev, 0) * 100 AS pct_open_vs_prev_period,
  (open_cur - open_py_sameperiod) / NULLIF(open_py_sameperiod, 0) * 100 AS pct_open_vs_same_period_py,
  -- 3. Số tài khoản đóng trong kỳ và % thay đổi.
  close_cur,
  close_prev,
  close_py_sameperiod,
  (close_cur - close_prev) / NULLIF(close_prev, 0) * 100 AS pct_close_vs_prev_period,
  (close_cur - close_py_sameperiod) / NULLIF(close_py_sameperiod, 0) * 100 AS pct_close_vs_same_period_py
FROM count_acc_agg
ORDER BY is_total, investor_type
;