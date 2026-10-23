-- Baseline schema for transaction-service.
-- Flyway applies this on a fresh database. On an existing database,
-- baseline-on-migrate=true marks V0 as already applied so this file runs once.

CREATE TABLE IF NOT EXISTS accounts (
    user_id VARCHAR(100) PRIMARY KEY,
    balance DOUBLE PRECISION NOT NULL DEFAULT 0
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
