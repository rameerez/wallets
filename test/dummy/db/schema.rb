# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2025_02_12_181807) do
  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "wallets_allocations", force: :cascade do |t|
    t.bigint "amount", null: false
    t.datetime "created_at", null: false
    t.integer "source_transaction_id", null: false
    t.integer "transaction_id", null: false
    t.datetime "updated_at", null: false
    t.index ["source_transaction_id"], name: "index_wallets_allocations_on_source_transaction_id"
    t.index ["transaction_id", "source_transaction_id"], name: "index_wallet_allocations_on_tx_and_source_tx"
    t.index ["transaction_id"], name: "index_wallets_allocations_on_transaction_id"
  end

  create_table "wallets_transactions", force: :cascade do |t|
    t.bigint "amount", null: false
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.json "metadata", default: {}, null: false
    t.integer "transfer_id"
    t.datetime "updated_at", null: false
    t.integer "wallet_id", null: false
    t.index ["category"], name: "index_wallets_transactions_on_category"
    t.index ["expires_at", "id"], name: "index_wallet_transactions_on_expires_at_and_id"
    t.index ["expires_at"], name: "index_wallets_transactions_on_expires_at"
    t.index ["transfer_id"], name: "index_wallets_transactions_on_transfer_id"
    t.index ["wallet_id", "amount"], name: "index_wallet_transactions_on_wallet_id_and_amount"
    t.index ["wallet_id"], name: "index_wallets_transactions_on_wallet_id"
  end

  create_table "wallets_transfers", force: :cascade do |t|
    t.bigint "amount", null: false
    t.string "asset_code", null: false
    t.string "category", default: "transfer", null: false
    t.datetime "created_at", null: false
    t.integer "from_wallet_id", null: false
    t.integer "inbound_transaction_id"
    t.json "metadata", default: {}, null: false
    t.integer "outbound_transaction_id"
    t.integer "to_wallet_id", null: false
    t.datetime "updated_at", null: false
    t.index ["from_wallet_id"], name: "index_wallets_transfers_on_from_wallet_id"
    t.index ["inbound_transaction_id"], name: "index_wallets_transfers_on_inbound_transaction_id"
    t.index ["outbound_transaction_id"], name: "index_wallets_transfers_on_outbound_transaction_id"
    t.index ["to_wallet_id"], name: "index_wallets_transfers_on_to_wallet_id"
  end

  create_table "wallets_wallets", force: :cascade do |t|
    t.string "asset_code", null: false
    t.bigint "balance", default: 0, null: false
    t.datetime "created_at", null: false
    t.json "metadata", default: {}, null: false
    t.integer "owner_id", null: false
    t.string "owner_type", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "asset_code"], name: "index_wallets_on_owner_and_asset_code", unique: true
    t.index ["owner_type", "owner_id"], name: "index_wallets_wallets_on_owner"
  end

  add_foreign_key "wallets_allocations", "wallets_transactions", column: "source_transaction_id"
  add_foreign_key "wallets_allocations", "wallets_transactions", column: "transaction_id"
  add_foreign_key "wallets_transactions", "wallets_transfers", column: "transfer_id"
  add_foreign_key "wallets_transactions", "wallets_wallets", column: "wallet_id"
  add_foreign_key "wallets_transfers", "wallets_transactions", column: "inbound_transaction_id"
  add_foreign_key "wallets_transfers", "wallets_transactions", column: "outbound_transaction_id"
  add_foreign_key "wallets_transfers", "wallets_wallets", column: "from_wallet_id"
  add_foreign_key "wallets_transfers", "wallets_wallets", column: "to_wallet_id"
end
