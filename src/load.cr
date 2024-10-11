# Load third party dependencies
require "json"
require "uuid"
require "uuid/json"
require "http/status"

# Config of the library
require "./config.cr"

# Event sourcing exceptions
require "./exceptions/error.cr"
require "./exceptions/conflict.cr"
require "./exceptions/invalid_event_stream.cr"
require "./exceptions/invalid_state.cr"
require "./exceptions/not_found.cr"
require "./exceptions/not_implemented.cr"

# Event sourcing components
require "./components/aggregate.cr"
require "./components/command.cr"
require "./components/event_bus.cr"
require "./components/event_handlers.cr"
require "./components/event.cr"
require "./components/projection.cr"

# Infrastructure adapters
# # Event stores
require "./adapters/eventstores/eventstore.cr"
require "./adapters/eventstores/in_memory.cr"
require "./adapters/eventstores/postgres.cr"

# # Queues
require "./adapters/queues/queue.cr"
require "./adapters/queues/postgres.cr"
