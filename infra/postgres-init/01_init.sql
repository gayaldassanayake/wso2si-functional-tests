-- WSO2 SI Test Suite - PostgreSQL Initialization
-- Runs automatically on first container start via docker-entrypoint-initdb.d.
-- POSTGRES_USER (sitest) is the superuser, so it already holds REPLICATION.

-- Table for TC48: CDC listening mode (Debezium logical replication)
-- REPLICA IDENTITY FULL makes Postgres emit before-images on UPDATE/DELETE;
-- with the default (primary key) the before_* fields arrive null and the
-- UPDATE/DELETE assertions cannot see old values. MySQL's binlog gives these
-- for free, which is why TC39 needs no equivalent.
CREATE TABLE IF NOT EXISTS cdc_listen_table_pg (
    order_id  INTEGER      NOT NULL PRIMARY KEY,
    product   VARCHAR(100) NOT NULL,
    quantity  INTEGER      NOT NULL DEFAULT 0,
    price     DOUBLE PRECISION NOT NULL DEFAULT 0.0
);
ALTER TABLE cdc_listen_table_pg REPLICA IDENTITY FULL;

-- Table for TC49: CDC polling mode
CREATE TABLE IF NOT EXISTS cdc_test_table_pg (
    item_id     VARCHAR(50)  NOT NULL PRIMARY KEY,
    item_name   VARCHAR(100) NOT NULL,
    quantity    INTEGER      NOT NULL DEFAULT 0,
    row_version BIGINT       NOT NULL DEFAULT 0
);
ALTER TABLE cdc_test_table_pg REPLICA IDENTITY FULL;

-- Postgres has no inline SET in triggers; polling needs row_version to advance
-- on every INSERT and UPDATE so siddhi-io-cdc sees the row as changed.
CREATE OR REPLACE FUNCTION bump_row_version() RETURNS TRIGGER AS $$
BEGIN
    NEW.row_version := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER cdc_test_pg_bump
    BEFORE INSERT OR UPDATE ON cdc_test_table_pg
    FOR EACH ROW EXECUTE FUNCTION bump_row_version();

-- Debezium's default publication name; pre-creating it keeps connector startup
-- deterministic instead of relying on auto-creation.
CREATE PUBLICATION dbz_publication FOR ALL TABLES;
