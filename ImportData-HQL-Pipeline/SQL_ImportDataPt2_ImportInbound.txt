/*
OWNER: Imports Analytics Team
PURPOSE: Import inbound volume projection and receipt tracking
FEATURES: Hive SQL, Receipt date logic, Flow vs Storage classification
PLATFORM: Apache Hive / Hadoop
*/

-- Import Inbound Volume Analysis
WITH
booking_receipts AS (
    -- OMS order and receipt information
    SELECT
        oms.oms_po_nbr,
        oms.distribution_po_nbr,
        oms.booking_po_nbr,
        oms.po_line_nbr,
        oms.order_date,
        oms.po_type_code,
        oms.event_abbr,
        oms.item_nbr,
        oms.mds_fam_id,
        oms.order_dept_nbr,
        oms.dc_nbr,
        oms.mabd_date,
        rcv.received_date,
        COALESCE(oms.vnpk_ord_qty * (rcv.vnpk_rcv_qty / rcv.tot_vnpk_rcv_qty), oms.vnpk_ord_qty) AS vnpk_ord_qty,
        COALESCE(rcv.vnpk_rcv_qty, 0) AS vnpk_rcv_qty
        
    FROM oms_dw.purchase_order_line AS oms
    
        INNER JOIN oms_dw.purchase_order AS po
            ON po.oms_po_nbr = oms.oms_po_nbr
        
        INNER JOIN oms_dw.sub_purchase_order AS sub
            ON sub.oms_po_nbr = oms.oms_po_nbr
        
        LEFT JOIN (
            -- Receiving aggregation by date
            SELECT
                rcv_line.oms_po_nbr,
                rcv_line.po_line_nbr,
                rcv_hdr.received_date,
                SUM(SUM(rcv_line.vnpk_rcv_qty)) OVER (
                    PARTITION BY rcv_line.oms_po_nbr, rcv_line.po_line_nbr
                ) AS tot_vnpk_rcv_qty,
                SUM(rcv_line.vnpk_rcv_qty) AS vnpk_rcv_qty
                
            FROM oms_dw.receiver_line AS rcv_line
                LEFT JOIN oms_dw.dc_receiver AS rcv_hdr
                    ON rcv_hdr.oms_po_nbr = rcv_line.oms_po_nbr
                    AND rcv_hdr.receiver_nbr = rcv_line.receiver_nbr
            
            WHERE rcv_line.vnpk_rcv_qty > 0
            
            GROUP BY
                rcv_line.oms_po_nbr,
                rcv_line.po_line_nbr,
                rcv_hdr.received_date
        ) AS rcv
            ON rcv.oms_po_nbr = oms.oms_po_nbr
            AND rcv.po_line_nbr = oms.po_line_nbr
    
    WHERE po.po_status_cd IN (800, 1200, 1400, 1500)  -- ACTIVE, CLOSED, HISTORY, SPLIT
        AND oms.po_line_status_cd IN (700, 1000, 1100, 1200)  -- APPROVED, PARTIAL, RECEIVED, CLOSED
        AND oms.vnpk_ord_qty > 0
        AND (rcv.received_date > oms.order_date OR rcv.received_date IS NULL)
),

idc_volume AS (
    SELECT
        br.booking_po_nbr,
        br.distribution_po_nbr,
        br.order_date,
        br.po_type_code,
        br.event_abbr,
        br.item_nbr,
        br.mds_fam_id,
        br.order_dept_nbr,
        br.dc_nbr,
        
        -- Channel classification
        CASE
            WHEN br.dc_nbr IN (6060, 6061, 6088, 7042, 7067, 7078) THEN 'STORAGE'
            WHEN br.dc_nbr IN (7085, 7086, 7089, 7092, 7093, 7094, 8695, 9631) THEN 'FLOW'
            ELSE 'OTHER'
        END AS channel_method_desc,
        
        -- Date calculations
        br.mabd_date - 5 AS idc_date_planned,
        br.mabd_date AS rdc_date_planned,
        br.mabd_date + 2 AS store_date_planned,
        br.received_date AS idc_date_actual,
        
        -- Volume
        br.vnpk_ord_qty,
        br.vnpk_rcv_qty
        
    FROM booking_receipts AS br
    
    WHERE br.dc_nbr IN (
        6060, 6061, 6088, 7042, 7067, 7078,  -- Storage facilities
        7085, 7086, 7089, 7092, 7093, 7094, 8695, 9631  -- Flow facilities
    )
)

SELECT
    iv.*,
    item.acctg_dept_nbr,
    item.dept_category_nbr,
    item.vnpk_qty,
    item.vnpk_cube_qty,
    item.vnpk_weight_qty,
    item.base_unit_retail_amt,
    
    -- Calculated quantities
    iv.vnpk_ord_qty * item.vnpk_qty AS unit_ord_qty,
    iv.vnpk_rcv_qty * item.vnpk_qty AS unit_rcv_qty,
    iv.vnpk_ord_qty * item.vnpk_cube_qty AS cube_ord_qty,
    iv.vnpk_rcv_qty * item.vnpk_cube_qty AS cube_rcv_qty,
    (iv.vnpk_ord_qty * item.vnpk_qty) * item.base_unit_retail_amt AS retail_ord_qty,
    (iv.vnpk_rcv_qty * item.vnpk_qty) * item.base_unit_retail_amt AS retail_rcv_qty

FROM idc_volume AS iv

    INNER JOIN enterprise_dims.item_dim AS item
        ON item.item_nbr = iv.item_nbr
        AND item.country_code = 'US'
        AND item.current_ind = 'Y'
        AND item.dept_nbr NOT IN (15, 37, 38, 39, 49, 58, 60, 65, 69, 75, 85, 86, 88, 89, 99)  -- Exclude service depts

WHERE iv.idc_date_actual >= DATE_SUB(CURRENT_DATE, 65 * 7)  -- Last 65 weeks
