-- =====================================================================
-- Mini Project: Data Warehouse E-commerce (Star Schema) di BigQuery
-- Sumber : bigquery-public-data.thelook_ecommerce
-- Target : dataset dwh_thelook (lokasi harus US, sama dengan dataset sumber)
-- Jalankan satu blok per satu, sesuai urutan.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Buat dataset
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS dwh_thelook
OPTIONS (location = 'US');


-- ---------------------------------------------------------------------
-- 1. DIMENSI
-- ---------------------------------------------------------------------

-- dim_customer
CREATE OR REPLACE TABLE dwh_thelook.dim_customer AS
SELECT
  id            AS user_id,
  first_name,
  last_name,
  age,
  gender,
  country,
  state,
  city,
  traffic_source,
  DATE(created_at) AS registered_date
FROM `bigquery-public-data.thelook_ecommerce.users`;

-- dim_product
CREATE OR REPLACE TABLE dwh_thelook.dim_product AS
SELECT
  id            AS product_id,
  name          AS product_name,
  category,
  brand,
  department,
  cost,
  retail_price
FROM `bigquery-public-data.thelook_ecommerce.products`;

-- dim_date
CREATE OR REPLACE TABLE dwh_thelook.dim_date AS
SELECT
  CAST(FORMAT_DATE('%Y%m%d', d) AS INT64) AS date_key,
  d                                       AS full_date,
  EXTRACT(YEAR FROM d)                    AS year,
  EXTRACT(QUARTER FROM d)                 AS quarter,
  EXTRACT(MONTH FROM d)                   AS month,
  FORMAT_DATE('%B', d)                    AS month_name,
  EXTRACT(ISOWEEK FROM d)                 AS week_of_year,
  FORMAT_DATE('%A', d)                    AS day_name,
  EXTRACT(DAYOFWEEK FROM d) IN (1, 7)     AS is_weekend
FROM UNNEST(GENERATE_DATE_ARRAY(DATE '2019-01-01', CURRENT_DATE())) AS d;


-- ---------------------------------------------------------------------
-- 2. FAKTA
-- CATATAN: BigQuery Sandbox menghapus partisi tanggal yang lebih tua dari
-- 60 hari, sehingga data lama hilang. Karena itu di Sandbox tabel fakta
-- TIDAK dipartisi, hanya di-cluster. Di akun berbayar (production), pakai:
--   PARTITION BY order_date
--   CLUSTER BY product_id, user_id
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dwh_thelook.fact_sales
CLUSTER BY order_date, product_id, user_id
AS
SELECT
  oi.id                                                    AS order_item_id,
  oi.order_id,
  oi.user_id,
  oi.product_id,
  DATE(oi.created_at)                                      AS order_date,
  CAST(FORMAT_DATE('%Y%m%d', DATE(oi.created_at)) AS INT64) AS date_key,
  oi.status,
  oi.sale_price,
  p.cost,
  (oi.sale_price - p.cost)                                 AS gross_profit
FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
JOIN `bigquery-public-data.thelook_ecommerce.products` p
  ON oi.product_id = p.id;


-- ---------------------------------------------------------------------
-- 3. QUALITY CHECK (screenshot hasilnya untuk README)
-- ---------------------------------------------------------------------
-- 3a. Jumlah baris fakta harus sama dengan sumber
SELECT
  (SELECT COUNT(*) FROM dwh_thelook.fact_sales) AS fact_rows,
  (SELECT COUNT(*) FROM `bigquery-public-data.thelook_ecommerce.order_items`) AS source_rows;

-- 3b. Tidak boleh ada order tanpa pelanggan atau produk (orphan)
SELECT COUNT(*) AS orphan_rows
FROM dwh_thelook.fact_sales f
LEFT JOIN dwh_thelook.dim_customer c USING (user_id)
LEFT JOIN dwh_thelook.dim_product  p USING (product_id)
WHERE c.user_id IS NULL OR p.product_id IS NULL;


-- ---------------------------------------------------------------------
-- 4. VIEW ANALITIK (dipakai Looker Studio)
-- Revenue dihitung hanya dari order yang tidak dibatalkan/diretur.
-- ---------------------------------------------------------------------

-- 4a. Revenue & profit bulanan
CREATE OR REPLACE VIEW dwh_thelook.vw_monthly_revenue AS
SELECT
  DATE_TRUNC(order_date, MONTH) AS month,
  COUNT(DISTINCT order_id)      AS total_orders,
  SUM(sale_price)               AS revenue,
  SUM(gross_profit)             AS profit,
  SAFE_DIVIDE(SUM(gross_profit), SUM(sale_price)) AS profit_margin
FROM dwh_thelook.fact_sales
WHERE status NOT IN ('Cancelled', 'Returned')
GROUP BY month;

-- 4b. Performa per kategori
CREATE OR REPLACE VIEW dwh_thelook.vw_category_performance AS
SELECT
  p.department,
  p.category,
  COUNT(*)            AS items_sold,
  SUM(f.sale_price)   AS revenue,
  SUM(f.gross_profit) AS profit
FROM dwh_thelook.fact_sales f
JOIN dwh_thelook.dim_product p USING (product_id)
WHERE f.status NOT IN ('Cancelled', 'Returned')
GROUP BY p.department, p.category;

-- 4c. Performa per negara
CREATE OR REPLACE VIEW dwh_thelook.vw_country_performance AS
SELECT
  c.country,
  COUNT(DISTINCT f.user_id) AS customers,
  SUM(f.sale_price)         AS revenue,
  SUM(f.gross_profit)       AS profit
FROM dwh_thelook.fact_sales f
JOIN dwh_thelook.dim_customer c USING (user_id)
WHERE f.status NOT IN ('Cancelled', 'Returned')
GROUP BY c.country;

-- 4d. Repeat customer rate per bulan pertama order
CREATE OR REPLACE VIEW dwh_thelook.vw_repeat_customer AS
WITH orders_per_user AS (
  SELECT user_id, COUNT(DISTINCT order_id) AS n_orders
  FROM dwh_thelook.fact_sales
  WHERE status NOT IN ('Cancelled', 'Returned')
  GROUP BY user_id
)
SELECT
  COUNT(*)                                   AS total_customers,
  COUNTIF(n_orders > 1)                      AS repeat_customers,
  SAFE_DIVIDE(COUNTIF(n_orders > 1), COUNT(*)) AS repeat_rate
FROM orders_per_user;

-- 4e. Top 20 produk berdasarkan profit
CREATE OR REPLACE VIEW dwh_thelook.vw_top_products AS
SELECT
  p.product_name,
  p.brand,
  p.category,
  COUNT(*)            AS items_sold,
  SUM(f.sale_price)   AS revenue,
  SUM(f.gross_profit) AS profit
FROM dwh_thelook.fact_sales f
JOIN dwh_thelook.dim_product p USING (product_id)
WHERE f.status NOT IN ('Cancelled', 'Returned')
GROUP BY p.product_name, p.brand, p.category
ORDER BY profit DESC
LIMIT 20;
