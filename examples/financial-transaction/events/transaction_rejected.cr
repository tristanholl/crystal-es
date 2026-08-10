class Events::TransactionRejected < ES::Event
  include ES::EventDSL

  define_event "Transaction", "transaction.rejected" do
    attribute :reason, String
  end
end
