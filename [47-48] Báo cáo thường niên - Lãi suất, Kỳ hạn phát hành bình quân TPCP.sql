-- 47-48. BÁO CÁO THƯỜNG NIÊN >> KỲ HẠN PHÁT HÀNH BÌNH QUÂN, LÃI SUẤT PHÁT HÀNH BÌNH QUÂN TPCP
---- Tham số: :fromyear - :toyear  [Từ năm - Đến năm (yyyy)]
SELECT 
  y.nam,
  o.lai_suat_phat_hanh_bq_tpcp,
  o.ky_han_phat_hanh_bq_tpcp
FROM (SELECT EXPLODE(SEQUENCE(CAST(:fromyear AS INT), CAST(:toyear AS INT))) AS nam) y -- Danh sách năm trong khoảng [Từ năm, Đến năm]
LEFT JOIN (
  -- Tính lãi suất, kỳ hạn bình quân theo năm
  SELECT 
    nam,
    SUM(winning_interest_rate * winning_value) / SUM(winning_value) AS lai_suat_phat_hanh_bq_tpcp, -- Lãi suất phát hành bình quân
    SUM(term_years * winning_value) / SUM(winning_value) AS ky_han_phat_hanh_bq_tpcp -- Kỳ hạn phát hành bình quân (quy đổi ra năm)
  FROM (
    -- Lọc dữ liệu và quy đổi kỳ hạn (tuần, tháng, năm) về số năm
    SELECT 
      CAST(DATE_FORMAT(issue_date, 'yyyy') AS INT) AS nam,
      winning_value,
      winning_interest_rate,
      CASE 
        WHEN LOWER(term) LIKE '%tuần%' THEN CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4)) / 52.0  -- Kỳ hạn "Tuần"
        WHEN LOWER(term) LIKE '%tháng%' THEN CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4)) / 12.0 -- Kỳ hạn "Tháng"
        ELSE CAST(REGEXP_EXTRACT(term, '[0-9]+', 0) AS DECIMAL(10, 4)) -- Kỳ hạn "Năm"
      END AS term_years
    FROM uat_hnx_stg.gov_bond_offering 
    WHERE CAST(DATE_FORMAT(issue_date, 'yyyy') AS INT) BETWEEN CAST(:fromyear AS INT) AND CAST(:toyear AS INT)
  ) sub
  GROUP BY nam
) o ON y.nam = o.nam
ORDER BY y.nam ASC;