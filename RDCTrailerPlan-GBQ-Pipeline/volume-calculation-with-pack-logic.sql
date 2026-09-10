SELECT
  INVOICE_NBR,
  -- Non-breakpack cases (casepacks + pallets + oversized breakpacks)
  SUM(CASE
    WHEN pack.PACK_TYPE IN ('CASEPACK', 'FULL_PALLET', 'MIXED_PALLET')
      THEN WHPK_SHIP_QTY
    WHEN LABEL_TYPE = 'FDSC'
      AND item.LENGTH + item.WIDTH + item.HEIGHT > 52
      THEN WHPK_SHIP_QTY -- Oversized breakpack treated as casepack
    ELSE 0
  END) AS NON_BRPK_CASE_QTY,

  -- Cube calculation with fallback formula
  SUM(LEAST(
    COALESCE(
      WHPK_SHIP_QTY * item.WHPK_CUBE,
      (WHPK_SHIP_QTY * item.WHPK_QTY / item.VNPK_QTY) * item.VNPK_CUBE
    ),
    (WHPK_SHIP_QTY * item.WHPK_QTY / item.VNPK_QTY) * item.VNPK_CUBE
  )) AS CUBE_QTY
FROM invoice_line
  JOIN item_dim         ON invoice_line.ITEM_NBR = item_dim.MDS_FAM_ID
  LEFT JOIN pick_code_class ON LABEL_TYPE = PICK_TYPE_CODE
GROUP BY INVOICE_NBR;