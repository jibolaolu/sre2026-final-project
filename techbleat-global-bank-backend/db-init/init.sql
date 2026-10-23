-- Techbleat Global Bank schema
-- Runs once on a fresh Postgres volume via docker-entrypoint-initdb.d.
-- All tables use IF NOT EXISTS so re-runs are safe.
-- The transaction service (Spring/Hibernate, DDL-auto=update) also manages
-- the accounts and transactions tables; IF NOT EXISTS prevents conflicts.

CREATE TABLE IF NOT EXISTS users (
    id          VARCHAR(100) PRIMARY KEY,
    full_name   VARCHAR(255) NOT NULL,
    email       VARCHAR(255) NOT NULL UNIQUE,
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS accounts (
    user_id     VARCHAR(100) PRIMARY KEY,
    balance     DOUBLE PRECISION NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS transactions (
    id               BIGSERIAL PRIMARY KEY,
    user_id          VARCHAR(100) NOT NULL,
    transaction_type VARCHAR(50)  NOT NULL,
    amount           DOUBLE PRECISION NOT NULL,
    reference        TEXT,
    created_at       TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_transactions_user_id ON transactions (user_id);

CREATE TABLE IF NOT EXISTS activities (
    id            BIGSERIAL PRIMARY KEY,
    user_id       VARCHAR(100) NOT NULL,
    activity_type VARCHAR(50)  NOT NULL,
    description   TEXT,
    created_at    TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_activities_user_id ON activities (user_id);
