class Projections::Ledger < ES::Projection
  TECHNICAL_ACCOUNT = UUID.new("01929fef-2e55-742f-b151-000000acc000") # Technical account

  # Create necessary schema and tables
  # Simplification for the sake of the example
  # TODO: This should move to a proper migration
  def setup
    skip = @projection_database.query_one %(SELECT EXISTS (SELECT FROM pg_tables WHERE  schemaname = 'projections' AND tablename  = 'postings');), as: Bool
    return true if skip

    m = Array(String).new
    m << %( CREATE SCHEMA IF NOT EXISTS "projections"; )
    m << %( GRANT USAGE ON SCHEMA "projections" TO pg_monitor; )
    m << %( GRANT SELECT ON ALL TABLES IN SCHEMA "projections" TO pg_monitor; )
    m << %( GRANT SELECT ON ALL SEQUENCES IN SCHEMA "projections" TO pg_monitor; )
    m << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "projections" GRANT SELECT ON TABLES TO pg_monitor; )
    m << %( ALTER DEFAULT PRIVILEGES IN SCHEMA "projections" GRANT SELECT ON SEQUENCES TO pg_monitor; )
    m << %(
      CREATE TABLE "projections"."postings" (
        "id" SERIAL PRIMARY KEY,
        "posting_uuid" UUID NOT NULL,
        "transaction_uuid" UUID NOT NULL,
        "created_at" timestamptz NOT NULL,
        "account_uuid" UUID NOT NULL,
        "account_credit_uuid" UUID NOT NULL,
        "account_debit_uuid" UUID NOT NULL,
        "amount_value" int8 NOT NULL,
        "accepted_at" timestamptz NULL,
        "aggregate_version" int8 NOT NULL,
        "rejected_at" timestamptz NULL
      );
    )
    m << %( CREATE UNIQUE INDEX postings_uuid_account_idx ON "projections"."postings"(posting_uuid, account_uuid); )

    m.each { |s| @projection_database.exec s }
  end

  # Events::TransactionInitiated
  def apply(event : Events::TransactionInitiated)
    # Extract attributes to local variables
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
    # Extract attributes to local variables
    uuid = event.header.event_id
    created_at = event.header.created_at
    aggregate_id = event.header.aggregate_id
    aggregate_version = event.header.aggregate_version

    # Build internal transfer aggregate to a specific version
    aggregate = Aggregate.new(
      aggregate_id
    )
    aggregate.hydrate(version: aggregate_version)

    amount_value = aggregate.state.amount
    creditor_account = aggregate.state.creditor_account

    # Raise exceptions if the aggregate state is invalid. Although very unlikely, this is important, since the projection defines the monetary means of customers
    raise ES::Exception::InvalidState.new("Invalid aggregate state") if amount_value.nil?
    raise ES::Exception::InvalidState.new("Invalid aggregate state") if creditor_account.nil?

    # Insert the postings projection into the projection database
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
    # Extract attributes to local variables
    uuid = event.header.event_id
    created_at = event.header.created_at
    aggregate_id = event.header.aggregate_id
    aggregate_version = event.header.aggregate_version

    # Build internal transfer aggregate to a specific version
    aggregate = Aggregate.new(
      aggregate_id
    )
    aggregate.hydrate(version: aggregate_version)

    amount_value = aggregate.state.amount
    debtor_account = aggregate.state.debtor_account

    # Raise exceptions if the aggregate state is invalid. Although very unlikely, this is important, since the projection defines the monetary means of customers
    raise ES::Exception::InvalidState.new("Invalid aggregate state") if amount_value.nil?
    raise ES::Exception::InvalidState.new("Invalid aggregate state") if debtor_account.nil?

    # Insert the postings projection into the projection database
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

  # This function ensures that postings are always transactionally inserted in pairs
  private def insert_postings(
    account_credit_uuid : UUID,
    account_debit_uuid : UUID,
    aggregate_version : Int32,
    amount_value : Int64,
    created_at : Time,
    posting_uuid : UUID,
    transaction_uuid : UUID,
    accepted_at : (Time | Nil) = nil,
    rejected_at : (Time | Nil) = nil
  )
    creditor_amount_value = amount_value # Amount that is posted on creditor side
    debtor_amount_value = -amount_value  # Amount that is posted on debtor side

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
        account_credit_uuid, # -amount on creditor account
        aggregate_version,
        creditor_amount_value, # -amount
        created_at,
        posting_uuid,
        rejected_at,
        transaction_uuid
      )

      prepared_statement.exec(
        accepted_at,
        account_credit_uuid,
        account_debit_uuid,
        account_debit_uuid, # +amount on debtor account
        aggregate_version,
        debtor_amount_value, # +amount
        created_at,
        posting_uuid,
        rejected_at,
        transaction_uuid
      )
    end
  end
end
