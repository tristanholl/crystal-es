class Events::TransactionRejected < ES::Event
  include ES::EventDSL

  define_event "Transaction", "transaction.rejected", encrypted: true do
    attribute :reason, String
  end
end
