class Projections::Ledger < ES::Projection
  include ES::ProjectionDSL

  TECHNICAL_ACCOUNT = UUID.new("01929fef-2e55-742f-b151-000000acc000")

  define_projection "ledger", "projections.postings" do
    column :id, Int32, serial: true, primary_key: true
    column :posting_uuid, UUID, null: false
    column :transaction_uuid, UUID, null: false
    column :created_at, Time, null: false
    column :account_uuid, UUID, null: false
    column :account_credit_uuid, UUID, null: false
    column :account_debit_uuid, UUID, null: false
    column :amount_value, Int64, null: false
    column :accepted_at, Time, null: true
    column :aggregate_version, Int64, null: false
    column :rejected_at, Time, null: true

    index [:posting_uuid, :account_uuid], unique: true, name: "postings_uuid_account_idx"
  end

  # Override setup to also create the schema and apply permissions before the table
  def setup
    setup_schema
    setup_table
  end

  # Events::TransactionInitiated
  def apply(event : Events::TransactionInitiated)
    uuid = event.header.event_id
    created_at = event.header.created_at
    aggregate_id = event.header.aggregate_id
    aggregate_version = event.header.aggregate_version

    b = event.body.as(Events::TransactionInitiated::Body)
    amount_value = b.amount
    creditor_account = b.creditor_account
    debtor_account = b.debtor_account

    insert_postings(
      accepted_at: nil,
      account_credit_uuid: TECHNICAL_ACCOUNT,
      account_debit_uuid: debtor_account,
      aggregate_version: aggregate_version,
      amount_value: amount_value,
      created_at: created_at,
      posting_uuid: uuid,
      transaction_uuid: aggregate_id
    )
  end

  # Events::TransactionAccepted
  def apply(event : Events::TransactionAccepted)
    uuid = event.header.event_id
    created_at = event.header.created_at
    aggregate_id = event.header.aggregate_id
    aggregate_version = event.header.aggregate_version

    aggregate = Aggregate.new(aggregate_id)
    aggregate.hydrate(version: aggregate_version)

    amount_value = aggregate.state.amount
    creditor_account = aggregate.state.creditor_account

    raise ES::Exception::InvalidState.new("Invalid aggregate state") if amount_value.nil?
    raise ES::Exception::InvalidState.new("Invalid aggregate state") if creditor_account.nil?

    insert_postings(
      accepted_at: created_at,
      account_credit_uuid: creditor_account,
      account_debit_uuid: TECHNICAL_ACCOUNT,
      aggregate_version: aggregate_version,
      amount_value: amount_value,
      created_at: created_at,
      posting_uuid: uuid,
      transaction_uuid: aggregate_id
    )
  end

  # Events::TransactionRejected
  def apply(event : Events::TransactionRejected)
    uuid = event.header.event_id
    created_at = event.header.created_at
    aggregate_id = event.header.aggregate_id
    aggregate_version = event.header.aggregate_version

    aggregate = Aggregate.new(aggregate_id)
    aggregate.hydrate(version: aggregate_version)

    amount_value = aggregate.state.amount
    debtor_account = aggregate.state.debtor_account

    raise ES::Exception::InvalidState.new("Invalid aggregate state") if amount_value.nil?
    raise ES::Exception::InvalidState.new("Invalid aggregate state") if debtor_account.nil?

    insert_postings(
      rejected_at: created_at,
      account_credit_uuid: debtor_account,
      account_debit_uuid: TECHNICAL_ACCOUNT,
      aggregate_version: aggregate_version,
      amount_value: amount_value,
      created_at: created_at,
      posting_uuid: uuid,
      transaction_uuid: aggregate_id
    )
  end

  private def setup_schema
    skip = @projection_database.query_one %(SELECT EXISTS (SELECT FROM pg_tables WHERE  schemaname = 'projections' AND tablename  = 'postings');), as: Bool
    return if skip

    m = Array(String).new
    m << %( CREATE SCHEMA IF NOT EXISTS "projections"; )
    m << %( GRANT USAGE ON SCHEMA "projections" TO pg_monitor; )
    m << %( GRANT SELECT ON ALL TABLES IN SCHEMA "projections" TO pg_monitor; )
    m << %( GRANT SELECT ON ALL SEQUENCES IN SCHEMA "projections" TO pg_monitor; )
    m << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "projections" GRANT SELECT ON TABLES TO pg_monitor; )
    m << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "projections" GRANT SELECT ON SEQUENCES TO pg_monitor; )
    m.each { |s| @projection_database.exec s }
  end

  private def insert_postings(
    account_credit_uuid : UUID,
    account_debit_uuid : UUID,
    aggregate_version : Int32,
    amount_value : Int64,
    created_at : Time,
    posting_uuid : UUID,
    transaction_uuid : UUID,
    accepted_at : (Time | Nil) = nil,
    rejected_at : (Time | Nil) = nil,
  )
    creditor_amount_value = amount_value
    debtor_amount_value = -amount_value

    @projection_database.transaction do |tx|
      cnn = tx.connection
      prepared_statement = cnn.build(%(
                INSERT INTO "projections"."postings" (
                  accepted_at,
                  account_credit_uuid,
                  account_debit_uuid,
                  account_uuid,
                  aggregate_version,
                  amount_value,
                  created_at,
                  posting_uuid,
                  rejected_at,
                  transaction_uuid
                )
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10))
      )

      prepared_statement.exec(
        accepted_at,
        account_credit_uuid,
        account_debit_uuid,
        account_credit_uuid,
        aggregate_version,
        creditor_amount_value,
        created_at,
        posting_uuid,
        rejected_at,
        transaction_uuid
      )

      prepared_statement.exec(
        accepted_at,
        account_credit_uuid,
        account_debit_uuid,
        account_debit_uuid,
        aggregate_version,
        debtor_amount_value,
        created_at,
        posting_uuid,
        rejected_at,
        transaction_uuid
      )
    end
  end
end
