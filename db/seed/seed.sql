-- Demo master data for ContosoERP (manufacturing scenario).
-- Safe to re-run: all inserts are ON CONFLICT DO NOTHING.
BEGIN;

INSERT INTO warehouse(code,name,region) VALUES
 ('WH-HYD','Hyderabad Distribution Centre','centralindia'),
 ('WH-PUN','Pune Plant Store','centralindia'),
 ('WH-BLR','Bengaluru Spares Hub','southindia')
ON CONFLICT (code) DO NOTHING;

INSERT INTO supplier(code,name,lead_time_days) VALUES
 ('SUP-001','Steelworks Ltd',14),
 ('SUP-002','Precision Castings Pvt',21),
 ('SUP-003','Nippon Bearings India',30),
 ('SUP-004','Elektro Components Co',7)
ON CONFLICT (code) DO NOTHING;

INSERT INTO customer(code,name,email,credit_limit,payment_terms_days) VALUES
 ('CUST-001','Acme Industries','ap@acme.example',2500000,45),
 ('CUST-002','Bharat Heavy Fabricators','accounts@bhf.example',5000000,60),
 ('CUST-003','Deccan Motors','finance@deccan.example',1200000,30),
 ('CUST-004','Krishna Agro Equipment','purchase@krishnaagro.example',800000,30),
 ('CUST-005','Zenith Robotics','ap@zenith.example',3000000,45)
ON CONFLICT (code) DO NOTHING;

INSERT INTO product(sku,name,category,uom,unit_price,standard_cost,reorder_point) VALUES
 ('BEARING-6204','Ball bearing 6204 2RS','components','EA',250.00,180.00,200),
 ('BEARING-6205','Ball bearing 6205 2RS','components','EA',310.00,225.00,150),
 ('SHAFT-SS40','Stainless steel shaft 40mm','raw-material','M',1450.00,1100.00,50),
 ('MOTOR-3PH-5KW','3-phase induction motor 5kW','assemblies','EA',28500.00,22000.00,10),
 ('GEARBOX-GB20','Helical gearbox ratio 20:1','assemblies','EA',41200.00,33000.00,6),
 ('SEAL-NBR-40','NBR oil seal 40x62x8','components','EA',85.00,52.00,500),
 ('BOLT-M12-HT','High-tensile bolt M12x60','consumables','EA',12.50,7.80,5000),
 ('PLATE-MS-6MM','Mild steel plate 6mm','raw-material','KG',72.00,58.00,2000),
 ('COUPLING-FC90','Flexible coupling FC90','components','EA',3200.00,2400.00,25),
 ('VFD-5KW','Variable frequency drive 5kW','electronics','EA',34800.00,27500.00,8),
 ('SENSOR-PROX-M18','Inductive proximity sensor M18','electronics','EA',1850.00,1320.00,60),
 ('LUBE-EP2-18KG','EP2 grease 18kg pail','consumables','EA',4100.00,3250.00,20)
ON CONFLICT (sku) DO NOTHING;

-- Opening stock so the UI is not empty on first load.
INSERT INTO inventory_movement(product_id,warehouse_id,movement_type,quantity,reference)
SELECT p.id, w.id, 'adjustment',
       CASE p.category
         WHEN 'consumables'  THEN 4000
         WHEN 'components'   THEN 400
         WHEN 'raw-material' THEN 1500
         ELSE 15
       END,
       'OPENING-BALANCE'
FROM product p
CROSS JOIN warehouse w
WHERE w.code = 'WH-HYD'
  AND NOT EXISTS (
    SELECT 1 FROM inventory_movement m
    WHERE m.product_id = p.id AND m.warehouse_id = w.id
      AND m.reference = 'OPENING-BALANCE');

COMMIT;

\echo 'Seed complete. Row counts:'
SELECT 'product' t, count(*) FROM product
UNION ALL SELECT 'customer', count(*) FROM customer
UNION ALL SELECT 'supplier', count(*) FROM supplier
UNION ALL SELECT 'warehouse', count(*) FROM warehouse
UNION ALL SELECT 'inventory_movement', count(*) FROM inventory_movement;
