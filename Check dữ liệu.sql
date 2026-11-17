/* ========== CHECK DỮ LIỆU MDDS PROD ========== */
mdds_stg.jad_stockinfor 
21/05/2026: Xóa dữ liệu từ hnx (lọc floorcode <> '10')
All bảng mdds:
  - Xóa dữ liệu từ 06/10/2026 đến 10/11/2026
  - Từ 11/11/2026: Hỏi Việt xem dữ liệu mdds có lỗ chỗ không thì mới xóa vì các ngày này là ko phải dữ liệu uat.
Bảng jad_csidxinfor: Dữ liệu lịch sử bị lặp (1 dòng stockno là stockid, 1 dòng stockno là symbol), 2 mã index X50, XALL bị null symbol 
SELECT 
  indexcode, symbol, tradingdate, count(*)
FROM uat_mdds_stg.jad_csidxinfor cs
--WHERE cs.tradingdate >= '2026-10-01'
GROUP BY indexcode, symbol, tradingdate 
HAVING count(*) > 1
ORDER BY tradingdate DESC, indexcode, symbol
;

---------------------------------------------------
/*
https://uat-icp.ssc.gov.vn/internal-dashboard
