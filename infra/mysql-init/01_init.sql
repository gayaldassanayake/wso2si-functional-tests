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
FLUSH PRIVILEGES;
