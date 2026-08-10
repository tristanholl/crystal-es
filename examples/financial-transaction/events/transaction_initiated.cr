# Carries the two account identifiers involved in a transaction, so it is
# declared `encrypted: true`: the body is sealed under a data key chosen at
# construction, and destroying that key later erases both accounts at once.
class Events::TransactionInitiated < ES::Event
  include ES::EventDSL

  define_event "Transaction", "transaction.initiated", encrypted: true do
    attribute :amount, Int64
    attribute :creditor_account, UUID
    attribute :debtor_account, UUID
  end
end
