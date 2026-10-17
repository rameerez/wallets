# frozen_string_literal: true

# Adds holds and reservations (wallets 0.4) to an existing wallets 0.1, 0.2
# or 0.3 installation: the holds table, and the wallets' ledger revision.
class AddWalletsHolds < ActiveRecord::Migration[7.2]
  def up
    # Incremented by every command, so a stale database snapshot can always
    # be told from a current one, whatever the clock or a `touch` says.
    unless column_exists?(wallets_table, :ledger_revision)
      add_column wallets_table, :ledger_revision, :bigint, null: false, default: 0
    end

    # An app that installed 0.4 directly already has the table.
    return if table_exists?(holds_table)

    # Holds keep value in the ledger but out of the available balance: a hold
    # on one credit, a hold on the whole wallet, or a reservation of an amount.
    create_table holds_table, id: holds_primary_key_type do |t|
      t.references :wallet, null: false, **key_type_of(wallets_table),
                            foreign_key: { to_table: wallets_table },
                            index: false

      # The credit a credit hold covers. Wallet holds and reservations have none.
      t.references :transaction, **key_type_of(transactions_table),
                                 foreign_key: { to_table: transactions_table },
                                 index: false

      # The debit a reservation was captured into.
      t.references :capture_transaction, **key_type_of(transactions_table),
                                         foreign_key: { to_table: transactions_table },
                                         index: { unique: true, name: index_name("holds_on_capture_tx") }

      t.bigint :amount # reservations only
      t.string :category, null: false
      t.datetime :releases_at # the scheduled end
      t.datetime :released_at # the explicit end: a release or a capture
      t.string :release_reason
      t.send(json_column_type, :metadata, null: false, default: json_column_default)
      t.send(json_column_type, :release_metadata, null: false, default: json_column_default)

      t.timestamps

      # Ordinary composite indexes, which every adapter supports; correctness
      # never depends on a partial index. They also serve the wallet_id and
      # transaction_id foreign keys, and live inside the table so that MySQL
      # can drop the table without first dropping an index a key still needs.
      t.index [:wallet_id, :released_at], name: index_name("holds_on_wallet_and_released_at")
      t.index [:transaction_id, :released_at], name: index_name("holds_on_tx_and_released_at")
      t.index :releases_at, name: index_name("holds_on_releases_at")

      t.check_constraint "amount IS NULL OR amount > 0", name: constraint_name("holds_amount_positive")
      # A credit hold holds the credit's whole remaining value, never an amount.
      t.check_constraint "transaction_id IS NULL OR amount IS NULL", name: constraint_name("holds_credit_hold_has_no_amount")
      # Only an ended reservation can name the debit it was captured into.
      t.check_constraint "capture_transaction_id IS NULL OR " \
                         "(transaction_id IS NULL AND amount IS NOT NULL AND released_at IS NOT NULL)",
                         name: constraint_name("holds_capture_ends_reservation")
    end
  end

  # Rolling back must never delete holds, including holds this migration did
  # not create (its `up` is a no-op when the table already exists). An empty
  # table goes, and the ledger revision with it: the schema is 0.3's again.
  # A table with rows stays, and says so.
  def down
    return unless table_exists?(holds_table)

    if select_value("SELECT 1 FROM #{quote_table_name(holds_table)} LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
        "#{holds_table} still has holds, and rolling back would delete them. " \
        "Drop the table deliberately if that is what you mean."
    end

    drop_table holds_table
    remove_column wallets_table, :ledger_revision if column_exists?(wallets_table, :ledger_revision)
  end

  private

  # Key types come from the tables that already exist, read when the migration
  # runs, never from today's generator settings: the ledger may predate them,
  # and MySQL refuses a foreign key whose column differs from the key it
  # references (int against bigint, signed against unsigned).
  def key_type_of(table)
    key = primary_key_column(table)
    options = { type: key.type }

    # An integer key keeps its exact width. SQLite reports none: its rowid
    # keys are 64-bit, which is what the install template declares.
    if key.type == :integer && key.limit
      options[:limit] = key.limit
    elsif key.type == :integer
      options[:type] = :bigint
    end
    options[:unsigned] = true if key.respond_to?(:unsigned?) && key.unsigned?

    options
  end

  # The holds table's own key follows the ledger's: uuid for a uuid ledger,
  # the adapter's default auto-increment key for an integer one.
  def holds_primary_key_type
    key = primary_key_column(wallets_table)
    key.type == :integer ? :primary_key : key.type
  end

  def primary_key_column(table)
    primary_key = connection.primary_key(table)
    connection.columns(table).find { |column| column.name == primary_key }
  end

  def json_column_type
    return :jsonb if connection.adapter_name.downcase.include?("postgresql")

    :json
  end

  # MySQL does not allow defaults on JSON columns, so models treat nil metadata
  # the same as an empty hash when records are loaded. Rails' Trilogy adapter
  # talks to MySQL too, under its own name.
  def json_column_default
    return nil if connection.adapter_name.match?(/mysql|trilogy/i)

    {}
  end

  def table_prefix
    Wallets.configuration.table_prefix
  end

  def wallets_table
    "#{table_prefix}wallets"
  end

  def transactions_table
    "#{table_prefix}transactions"
  end

  def holds_table
    "#{table_prefix}holds"
  end

  def index_name(suffix)
    "index_#{table_prefix}#{suffix}"
  end

  def constraint_name(suffix)
    "check_#{table_prefix}#{suffix}"
  end
end
