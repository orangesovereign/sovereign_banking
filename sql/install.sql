-- ============================================================================
-- Sovereign Bank — full schema (tech spec §4)
-- All amounts are BIGINT minor units ("cents"). InnoDB, utf8mb4.
-- Fully idempotent: safe to run on every boot (sovereign_banking does this by default).
-- ============================================================================

CREATE TABLE IF NOT EXISTS sovereign_banking_accounts (
  id                INT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_number    VARCHAR(24)  NOT NULL,
  owner_type        ENUM('character','society','business','joint','system') NOT NULL,
  owner_id          VARCHAR(64)  NOT NULL,
  name              VARCHAR(64)  NOT NULL DEFAULT 'Checking',
  kind              ENUM('checking','savings','society','business') NOT NULL DEFAULT 'checking',
  balance_money     BIGINT NOT NULL DEFAULT 0,
  balance_gold      BIGINT NOT NULL DEFAULT 0,
  balance_rol       BIGINT NOT NULL DEFAULT 0,
  status            ENUM('active','frozen','closed') NOT NULL DEFAULT 'active',
  credit_limit      BIGINT NOT NULL DEFAULT 0,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_account_number (account_number),
  KEY idx_owner (owner_type, owner_id),
  KEY idx_status (status)
) ENGINE=InnoDB AUTO_INCREMENT=1001 DEFAULT CHARSET=utf8mb4;
-- ^ ids 1-1000 (and the account numbers branded from them) are reserved for
--   government and system accounts. Organic accounts start at 1001.

CREATE TABLE IF NOT EXISTS sovereign_banking_access (
  id             INT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id     INT UNSIGNED NOT NULL,
  charidentifier VARCHAR(64) NOT NULL,
  access_level   ENUM('owner','admin','withdraw','deposit','read') NOT NULL,
  granted_by     VARCHAR(64) NULL,
  created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_acct_char (account_id, charidentifier),
  KEY idx_char (charidentifier),
  CONSTRAINT fk_access_acct FOREIGN KEY (account_id)
    REFERENCES sovereign_banking_accounts(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_transactions (
  id                       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  tx_uuid                  CHAR(36) NOT NULL,
  account_id               INT UNSIGNED NULL,
  counterparty_account_id  INT UNSIGNED NULL,
  currency                 TINYINT NOT NULL,
  direction                ENUM('credit','debit') NOT NULL,
  amount                   BIGINT NOT NULL,
  balance_after            BIGINT NULL,
  category                 VARCHAR(40) NOT NULL,
  source_resource          VARCHAR(48) NULL,
  memo                     VARCHAR(140) NULL,
  created_at               TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_tx_uuid (tx_uuid),
  KEY idx_account_time (account_id, created_at),
  KEY idx_category (category)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_loans (
  id                INT UNSIGNED NOT NULL AUTO_INCREMENT,
  charidentifier    VARCHAR(64) NOT NULL,
  account_id        INT UNSIGNED NOT NULL,
  principal         BIGINT NOT NULL,
  total_due         BIGINT NOT NULL,
  balance_remaining BIGINT NOT NULL,
  interest_flat     DECIMAL(5,4) NOT NULL,
  due_by            DATETIME NULL,
  status            ENUM('pending','active','paid','defaulted','denied') NOT NULL DEFAULT 'pending',
  approved_by       VARCHAR(64) NULL,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_char (charidentifier),
  KEY idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_savings_accrual (
  account_id       INT UNSIGNED NOT NULL,
  last_accrued_at  DATETIME NOT NULL,
  PRIMARY KEY (account_id),
  CONSTRAINT fk_accrual_acct FOREIGN KEY (account_id)
    REFERENCES sovereign_banking_accounts(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_sdb (
  id              INT UNSIGNED NOT NULL AUTO_INCREMENT,
  account_id      INT UNSIGNED NULL,
  owner_id        VARCHAR(64) NOT NULL,
  size            ENUM('small','medium','large') NOT NULL,
  stash_id        VARCHAR(64) NOT NULL,
  rent_paid_until DATETIME NULL,
  created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_stash (stash_id),
  KEY idx_owner (owner_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_bills (
  id                 INT UNSIGNED NOT NULL AUTO_INCREMENT,
  bill_uuid          CHAR(36) NOT NULL,
  issuer_type        ENUM('character','society','system') NOT NULL,
  issuer_id          VARCHAR(64) NOT NULL,
  target_charid      VARCHAR(64) NOT NULL,
  kind               ENUM('invoice','fine','tax') NOT NULL,
  currency           TINYINT NOT NULL,
  amount             BIGINT NOT NULL,
  balance_remaining  BIGINT NOT NULL,
  status             ENUM('pending','overdue','in_collections','warrant','paid','cancelled','expired') NOT NULL DEFAULT 'pending',
  due_at             DATETIME NULL,
  assigned_collector VARCHAR(64) NULL,
  memo               VARCHAR(140) NULL,
  created_at         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  paid_at            TIMESTAMP NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_bill_uuid (bill_uuid),
  KEY idx_target (target_charid),
  KEY idx_status (status),
  KEY idx_kind (kind)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_business_tax (
  business_id      VARCHAR(64) NOT NULL,
  building_price   BIGINT NOT NULL,
  license_rate     DECIMAL(5,4) NOT NULL DEFAULT 0.2500,
  assessed         BIGINT NOT NULL DEFAULT 0,
  remitted         BIGINT NOT NULL DEFAULT 0,
  balance_owed     BIGINT NOT NULL DEFAULT 0,
  last_assessed_at DATETIME NULL,
  last_remit_at    DATETIME NULL,
  next_due_at      DATETIME NULL,
  PRIMARY KEY (business_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_seizures (
  id               INT UNSIGNED NOT NULL AUTO_INCREMENT,
  bill_id          INT UNSIGNED NOT NULL,
  collector_charid VARCHAR(64) NOT NULL,
  debtor_charid    VARCHAR(64) NOT NULL,
  items_json       JSON NOT NULL,
  assessed_value   BIGINT NOT NULL,
  applied_amount   BIGINT NOT NULL,
  surplus_returned BIGINT NOT NULL DEFAULT 0,
  created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_bill (bill_id),
  KEY idx_debtor (debtor_charid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_liens (
  id            INT UNSIGNED NOT NULL AUTO_INCREMENT,
  bill_id       INT UNSIGNED NULL,
  account_id    INT UNSIGNED NULL,
  debtor_charid VARCHAR(64) NOT NULL,
  amount        BIGINT NOT NULL,
  status        ENUM('active','released','satisfied') NOT NULL DEFAULT 'active',
  placed_by     VARCHAR(64) NOT NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  released_at   TIMESTAMP NULL,
  PRIMARY KEY (id),
  KEY idx_debtor (debtor_charid),
  KEY idx_status (status),
  KEY idx_bill (bill_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_reserves (
  branch_id        VARCHAR(48) NOT NULL,
  currency         TINYINT NOT NULL DEFAULT 0,
  balance          BIGINT NOT NULL DEFAULT 0,
  cap              BIGINT NOT NULL,
  last_refilled_at DATETIME NULL,
  last_claimed_at  DATETIME NULL,
  PRIMARY KEY (branch_id, currency)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sovereign_banking_meta (
  meta_key   VARCHAR(32) NOT NULL,
  meta_value VARCHAR(64) NOT NULL,
  PRIMARY KEY (meta_key)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
