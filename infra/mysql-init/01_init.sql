-- WSO2 SI Test Suite - MySQL Initialization
-- Runs automatically on first container start via docker-entrypoint-initdb.d

USE si_test_db;

-- Table for TC11: CDC Polling source test
-- updated_at is the polling column; CDC detects rows changed since last poll
CREATE TABLE IF NOT EXISTS cdc_test_table (
    item_id       VARCHAR(50)  NOT NULL,
    item_name     VARCHAR(100) NOT NULL,
    quantity      INT          NOT NULL DEFAULT 0,
    updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (item_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Grant CDC polling permission (SELECT on the table)
GRANT SELECT ON si_test_db.cdc_test_table TO 'sitest'@'%';

-- Grant replication privileges needed for CDC listening mode (TC23 — Debezium binlog)
-- RELOAD and SHOW DATABASES are required by Debezium for the initial snapshot phase
GRANT RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'sitest'@'%';

-- Table for TC23: CDC listening mode (Debezium binlog-based capture)
CREATE TABLE IF NOT EXISTS cdc_listen_table (
    order_id  INT          NOT NULL,
    product   VARCHAR(100) NOT NULL,
    quantity  INT          NOT NULL DEFAULT 0,
    price     DOUBLE       NOT NULL DEFAULT 0.0,
    PRIMARY KEY (order_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

GRANT SELECT ON si_test_db.cdc_listen_table TO 'sitest'@'%';
FLUSH PRIVILEGES;
