const { Pool } = require('pg');

const pool = new Pool({
  host: process.env.DB_HOST || 'postgres',
  port: Number(process.env.DB_PORT || 5432),
  user: process.env.DB_USER || 'fintech',
  password: process.env.DB_PASSWORD || 'fintech',
  database: process.env.DB_NAME || 'fintech',
  max: 10,
});

async function init() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS accounts (
      id           SERIAL PRIMARY KEY,
      owner_name   TEXT NOT NULL,
      email        TEXT UNIQUE NOT NULL,
      balance_cents BIGINT NOT NULL DEFAULT 0,
      created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
    );
  `);
}

module.exports = { pool, init };
