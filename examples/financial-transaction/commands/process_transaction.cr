# Data-record command — pure intent carrier, no behaviour.
# Used by TransactionDecider + ES::CommandHandler.
record ProcessTransaction, aggregate_id : UUID

alias TransactionCommand = ProcessTransaction
