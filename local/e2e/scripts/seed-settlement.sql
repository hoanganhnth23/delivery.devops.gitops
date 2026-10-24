\set ON_ERROR_STOP on

BEGIN;

WITH inserted AS (
    INSERT INTO transactions (
        entity_id,
        entity_type,
        order_id,
        direction,
        reason,
        amount,
        description,
        status,
        wallet_type,
        processed_at,
        created_at
    )
    SELECT
        :shipper_id,
        'SHIPPER',
        NULL,
        'CREDIT',
        'DEPOSIT_TOPUP',
        :deposit_amount,
        'LOCAL_SEED_DEPOSIT',
        'COMPLETED',
        'DEPOSIT',
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
    WHERE NOT EXISTS (
        SELECT 1
        FROM transactions
        WHERE entity_id = :shipper_id
          AND entity_type = 'SHIPPER'
          AND description = 'LOCAL_SEED_DEPOSIT'
    )
    RETURNING amount
)
INSERT INTO balances (
    entity_id,
    entity_type,
    available_balance,
    pending_balance,
    holding_balance,
    deposit_balance,
    total_deposited,
    total_cod_collected,
    created_at,
    updated_at
)
SELECT
    :shipper_id,
    'SHIPPER',
    0,
    0,
    0,
    amount,
    amount,
    0,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
FROM inserted
ON CONFLICT (entity_id, entity_type) DO UPDATE
SET deposit_balance = balances.deposit_balance + EXCLUDED.deposit_balance,
    total_deposited = balances.total_deposited + EXCLUDED.total_deposited,
    updated_at = CURRENT_TIMESTAMP;

COMMIT;
