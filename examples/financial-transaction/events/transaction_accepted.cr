class Events::TransactionAccepted < ES::Event
  include ES::EventDSL

  define_event "Transaction", "transaction.accepted"
end
