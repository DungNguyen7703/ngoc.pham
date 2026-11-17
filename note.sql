* Map loại chứng khoán cho sổ lệnh:
- Bảng uat_mdds_stg.jad_stockinfor (s): 
s.stocktype = '2' -- Loại chứng khoán = Cổ phiếu
Lấy bản ghi cuối ngày theo từng mã chứng khoán: (ROW_NUMBER() OVER(PARTITION BY s.symbol, s.tradingdate ORDER BY s.tradingtime DESC, s.`sequence` DESC) = 1
- Link bảng uat_hose_stg.trade_book (t) / uat_hnx_stg.trade_book (h) với bảng uat_mdds_stg.jad_stockinfor (s):
t.symbol = s.symbol AND t.trade_date = s.tradingdate
h.issue_code = s.symbolisin AND TO_DATE(h.trade_date, 'yyyyMMdd') = s.tradingdate

--- Báo cáo VP02
DATE_FORMAT(ADD_MONTHS(p.report_date, 1), 'yyyyMMdd') -- Chặn = [ngày báo cáo + 1 tháng] để lấy ngày liền sau ngày giao dịch mới nhất

-- Chuyển loại CK thành cột
, trade_agg AS (
  SELECT
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') THEN d.gt_m ELSE 0 END) AS cp_gt_m,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') THEN d.gt_pm ELSE 0 END) AS cp_gt_pm,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') THEN d.gt_lym ELSE 0 END) AS cp_gt_lym,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') THEN d.gt_y ELSE 0 END) AS cp_gt_y,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') THEN d.gt_py ELSE 0 END) AS cp_gt_py,
    SUM(CASE WHEN d.loai_ck = 'TPCP' THEN d.gt_m ELSE 0 END) AS tp_gt_m,
    SUM(CASE WHEN d.loai_ck = 'TPCP' THEN d.gt_pm ELSE 0 END) AS tp_gt_pm,
    SUM(CASE WHEN d.loai_ck = 'TPCP' THEN d.gt_lym ELSE 0 END) AS tp_gt_lym,
    SUM(CASE WHEN d.loai_ck = 'TPCP' THEN d.gt_y ELSE 0 END) AS tp_gt_y,
    SUM(CASE WHEN d.loai_ck = 'TPCP' THEN d.gt_py ELSE 0 END) AS tp_gt_py,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_m ELSE 0 END) AS cw_gt_m,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_m ELSE 0 END) AS cw_kl_m,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_pm ELSE 0 END) AS cw_gt_pm,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_pm ELSE 0 END) AS cw_kl_pm,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_lym ELSE 0 END) AS cw_gt_lym,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_lym ELSE 0 END) AS cw_kl_lym,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_y ELSE 0 END) AS cw_gt_y,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_y ELSE 0 END) AS cw_kl_y,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.gt_py ELSE 0 END) AS cw_gt_py,
    SUM(CASE WHEN d.loai_ck = 'CW' THEN d.kl_py ELSE 0 END) AS cw_kl_py,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_m ELSE 0 END) AS ps_kl_m,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_pm ELSE 0 END) AS ps_kl_pm,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_lym ELSE 0 END) AS ps_kl_lym,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_y ELSE 0 END) AS ps_kl_y,
    SUM(CASE WHEN d.loai_ck = 'HDTL_VN30' THEN d.kl_py ELSE 0 END) AS ps_kl_py,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') THEN d.ndtnn_rong_m ELSE 0 END) AS ndtnn_rong_cq_ccq_m,
    SUM(CASE WHEN d.loai_ck = 'TPCP' THEN d.ndtnn_rong_m ELSE 0 END) AS ndtnn_rong_tpcp_m,
    SUM(CASE WHEN d.loai_ck IN ('CP', 'CCQ') THEN d.ndtnn_rong_y ELSE 0 END) AS ndtnn_rong_cp_ccq_y,
    SUM(CASE WHEN d.loai_ck = 'TPCP' THEN d.ndtnn_rong_y ELSE 0 END) AS ndtnn_rong_tpcp_y
  FROM trade_period d
)

---------------------
- UNION ALL 2 bảng uat_vsdc_stg.open_investors (o), uat_vsdc_stg.closed_investors (c) thành danh sách event mở/đóng tài khoản:
o.open_date <= [Ngày báo cáo]
c.close_date <= [Ngày báo cáo]
- Lấy event gần nhất <= [Ngày báo cáo]
  + Event gần nhất là mở: tài khoản đang hoạt động tại ngày báo cáo
  + Event gần nhất là đóng: tài khoản không hoạt động tại ngày báo cáo
  + Chưa có event nào: Không tính
  + Chỉ có bản ghi đóng (thiếu dữ liệu mở): Không tính
  + Ngày gần nhất < Ngày báo cáo có cả mở và đóng: 
    - Event trước đó = Mở <-> Ngày gần nhất đóng rồi mở lại -> TK vẫn hoạt động
    - Event trước đó = Đóng <-> Ngày gần nhất mở rồi đóng lại -> TK vẫn không hoạt động
-> Ngày trùng (có cả mở + đóng) -> Không làm thay đổi trạng thái tài khoản nên bỏ qua ngày trùng
-> Công thức: Đếm tài khoản hoạt động = Có ngày mở <= [Ngày báo cáo] và (chưa từng đóng hoặc ngày mở gần nhất > ngày đóng gần nhất trước [Ngày báo cáo])

- Điều kiện Thời gian: 
o.open_date <= [Ngày cuối năm trước]
c.close_date <= [Ngày cuối năm trước]
- Điều kiện và công thức tính giống chỉ tiêu "Số lượng tài khoản NĐT"

--------------------------
-- CHECK TÀI KHOẢN ĐÓNG CÓ BẢN GHI MỞ KHÔNG
SELECT COUNT(DISTINCT trading_account_no) AS so_tk_loi
FROM (
  SELECT trading_account_no,
         SUM(net) OVER (PARTITION BY trading_account_no ORDER BY event_date) AS cum
  FROM (
    SELECT trading_account_no, event_date, SUM(delta) AS net
    FROM (
      SELECT trading_account_no, open_date  AS event_date,  1 AS delta FROM uat_vsdc_stg.open_investors   WHERE trading_account_no IS NOT NULL AND open_date  IS NOT NULL
      UNION ALL
      SELECT trading_account_no, close_date AS event_date, -1 AS delta FROM uat_vsdc_stg.closed_investors WHERE trading_account_no IS NOT NULL AND close_date IS NOT NULL
    ) e
    GROUP BY trading_account_no, event_date
  ) d
) w
WHERE cum NOT IN (0, 1);

-----
, acc_agg AS (
  SELECT
    COALESCE(SUM(CASE WHEN e.event_date <= p.report_date THEN e.delta ELSE 0 END), 0) AS tk_cur, -- Số TK hoạt động đến ngày báo cáo
    COALESCE(SUM(CASE WHEN e.event_date <= p.py_end      THEN e.delta ELSE 0 END), 0) AS tk_py   -- Số TK hoạt động đến ngày cuối năm trước
  FROM (
    -- Event mở (+1) / đóng (-1) tài khoản <= ngày báo cáo
    SELECT o.open_date AS event_date, 1 AS delta
    FROM uat_vsdc_stg.open_investors o
    WHERE o.open_date <= :report_date
    UNION ALL
    SELECT c.close_date AS event_date, -1 AS delta
    FROM uat_vsdc_stg.closed_investors c
    WHERE c.close_date <= :report_date
  ) e
  CROSS JOIN params p
)

-----------------------------
SELECT 
  'OPEN' event_type,
  o.investor_type,
  o.opendate AS event_date, 
  COUNT(o.trading_account_no) cnt_acc
FROM uat_vsdc_stg.open_investors o
GROUP BY o.investor_type, o.opendate
UNION ALL
SELECT 
  'CLOSE' event_type,
  c.investor_type,
  c.close_date AS event_date, 
  COUNT(c.trading_account_no) cnt_acc
FROM uat_vsdc_stg.closed_investors o
GROUP BY c.investor_type, c.close_date
;

CASE :period_type
  WHEN 'D' THEN a.event_date
  WHEN 'M' THEN TRUNC(a.event_date, 'MM')
  WHEN 'Q' THEN CAST(DATE_TRUNC('QUARTER', a.event_date) AS DATE)
  WHEN 'Y' THEN TRUNC(a.event_date, 'YYYY')
END AS period_startdate,
;

-------------------------------
AND (NVL(a.new_listed_shares, 0) + NVL(a.additional_listed_value, 0)) > 0 -- Chỉ lấy NY/ĐKGD mới và bổ sung

-- Ánh xạ mã sàn: Sau này gộp sàn (ví dụ 10 + 02 -> VNX) chỉ cần sửa tại đây
CASE x.floorcode
  WHEN '10' THEN 'HOSE'
  WHEN '02' THEN 'HNX'
  WHEN '04' THEN 'UPCOM'
  ELSE 'KHAC'
END AS san,

--------------------------------
REGEXP_REPLACE(f.column_path, '[\\r\\n]+','') 
TRIM(REGEXP_REPLACE(f.column_path, '\\s+', ' ')) 
--------------------------------

SELECT 
  object_name, period_type, period_value, year_value, day_report, ngay_nop, 
  late_status, late_status_code, 
  row_path, column_path, 
  value_raw, CAST(value_raw AS DECIMAL(38,15)) AS value
FROM uat_fims_ods.fir_value v
WHERE report_code = 'IBOU9'
  AND column_path IN (
    'Giá trị dòng vốn vào trong kỳ báo cáo (+/-) (đơn vị USD)',
    'Tổng giá trị ngoại tệ đổi sang VND trong kỳ báo cáo (đơn vị USD)',
    'Tổng giá trị VND đổi ra ngoại tệ và chuyển ra trong kỳ báo cáo (đơn vị USD)'
  )
AND row_path = 'Tổng= (1) + (2)'
AND period_type = 'NUA_THANG'
;

-- 4. Mỗi kỳ có phát sinh x mỗi tổ hợp chiều; tổ hợp không phát sinh = 0
, underlying_period_data AS (
  SELECT pc.period_type, pc.period_code, d.origin_type, d.investor_kind,
         NVL(c.open_acc_count, 0) AS open_acc_count, NVL(c.close_acc_count, 0) AS close_acc_count
  FROM (SELECT DISTINCT period_type, period_code FROM underlying_period_counts) pc
  CROSS JOIN (SELECT DISTINCT origin_type, investor_kind FROM investor_type_map) d
  LEFT JOIN underlying_period_counts c
    ON c.period_code = pc.period_code AND c.origin_type = d.origin_type AND c.investor_kind = d.investor_kind
)
;

SELECT *
FROM VALUES
  ('1',  'Chào bán cho cổ đông hiện hữu',                                             '',                                    'Phát hành ra công chúng',                      'Y'),
  ('2',  'Đấu giá',                                                                   '',                                    'Phát hành ra công chúng',                      'Y'),
  ('3',  'Chào bán ra công chúng theo hình thức khác',                                '',                                    'Phát hành ra công chúng',                      'Y'),
  ('4',  'Chào bán của cổ đông công ty đại chúng ra công chúng',                      '',                                    'Phát hành ra công chúng',                      'N'),
  ('5',  'Chào bán riêng lẻ',                                                         '',                                    'Phát hành riêng lẻ',                           'Y'),
  ('6',  'Hoán đổi',                                                                  '',                                    'Phát hành để hoán đổi/sáp nhập',               'N'),
  ('7',  'Phát hành trả cổ tức',                                                      '',                                    'Phát hành để trả cổ tức, tăng vốn từ vốn CSH', 'Y'),
  ('8',  'Phát hành cổ phiếu từ nguồn vốn CSH',                                       '',                                    'Phát hành để trả cổ tức, tăng vốn từ vốn CSH', 'Y'),
  ('9',  'Phát hành cổ phiếu cho người lao động',                                     'Phát hành cho người lao động (ESOP)', 'ESOP',                                         'Y'),
  ('9',  'Phát hành cổ phiếu cho người lao động',                                     'Phát hành thưởng cho người lao động', 'ESOP',                                         'N'),
  ('10', 'Phát hành cổ phiếu thưởng cho người lao động',                              '',                                    'ESOP',                                         'N'),
  ('11', 'Chào bán trái phiếu giao dịch quốc tế',                                     '',                                    'Khác',                                         'Y'),
  ('12', 'Phát hành cổ phiếu để chào mua công khai',                                  '',                                    'Phát hành ra công chúng',                      'Y'),
  ('13', 'Chào bán thêm cổ phiếu ra công chúng',                                      '',                                    'Phát hành ra công chúng',                      'Y'),
  ('14', 'Chào bán cổ phiếu ra nước ngoài',                                           '',                                    'Khác',                                         'Y'),
  ('15', 'Phát hành cổ phiếu mới làm cơ sở chào bán chứng chỉ lưu ký tại nước ngoài', '',                                    'Khác',                                         'Y')
AS t(offering_method_cd, offering_method_name, security_name, offering_method_group, is_raising_capital)