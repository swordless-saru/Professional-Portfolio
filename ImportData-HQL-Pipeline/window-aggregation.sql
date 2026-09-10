SELECT
  shp.booking_po_nbr,
  shp.distribution_po_nbr,
  shp.item_nbr,

  -- Distribution-level quantity (aggregated by GROUP BY)
  SUM(shp.order_qty) AS vnpk_ord_qty,

  -- Booking-level total: window function applied over the GROUP BY aggregate
  SUM(SUM(shp.order_qty)) OVER (
    PARTITION BY shp.booking_po_nbr, shp.item_nbr
  ) AS total_vnpk_ord_qty

FROM imports_dw.import_shipment_historic AS shp
GROUP BY shp.booking_po_nbr, shp.distribution_po_nbr, shp.item_nbr;