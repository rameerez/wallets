# frozen_string_literal: true

class CreateWalletsTables < ActiveRecord::Migration[7.2]
  def change
    create_table :wallets_wallets do |t|
      t.references :owner, polymorphic: true, null: false
      t.string :asset_code, null: false
      t.bigint :balance, null: false, default: 0
      t.json :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :wallets_wallets, [:owner_type, :owner_id, :asset_code], unique: true, name: "index_wallets_on_owner_and_asset_code"

    create_table :wallets_transfers do |t|
      t.references :from_wallet, null: false, foreign_key: { to_table: :wallets_wallets }
      t.references :to_wallet, null: false, foreign_key: { to_table: :wallets_wallets }
      t.string :asset_code, null: false
      t.bigint :amount, null: false
      t.string :category, null: false, default: "transfer"
      t.json :metadata, null: false, default: {}
      t.timestamps
    end

    create_table :wallets_transactions do |t|
      t.references :wallet, null: false, foreign_key: { to_table: :wallets_wallets }
      t.bigint :amount, null: false
      t.string :category, null: false
      t.datetime :expires_at
      t.references :transfer, foreign_key: { to_table: :wallets_transfers }
      t.json :metadata, null: false, default: {}
      t.timestamps
    end

    create_table :wallets_allocations do |t|
      t.references :transaction, null: false, foreign_key: { to_table: :wallets_transactions }
      t.references :source_transaction, null: false, foreign_key: { to_table: :wallets_transactions }
      t.bigint :amount, null: false
      t.timestamps
    end

    add_reference :wallets_transfers, :outbound_transaction, foreign_key: { to_table: :wallets_transactions }
    add_reference :wallets_transfers, :inbound_transaction, foreign_key: { to_table: :wallets_transactions }

    add_index :wallets_transactions, :category
    add_index :wallets_transactions, :expires_at
    add_index :wallets_transactions, [:wallet_id, :amount], name: "index_wallet_transactions_on_wallet_id_and_amount"
    add_index :wallets_transactions, [:expires_at, :id], name: "index_wallet_transactions_on_expires_at_and_id"
    add_index :wallets_allocations, [:transaction_id, :source_transaction_id], name: "index_wallet_allocations_on_tx_and_source_tx"
  end
end
