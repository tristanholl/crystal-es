# Load third party dependencies
require "json"
require "uuid"
require "uuid/json"
require "http/status"
require "digest/sha256"
require "log"

# Config of the library
require "./config.cr"

# Event sourcing exceptions
require "./exceptions/error.cr"
require "./exceptions/conflict.cr"
require "./exceptions/dependency_unavailable.cr"
require "./exceptions/invalid_event_stream.cr"
require "./exceptions/invalid_state.cr"
require "./exceptions/not_found.cr"
require "./exceptions/not_implemented.cr"

# Event sourcing components
require "./components/aggregate.cr"
require "./components/command.cr"
require "./components/command_handler.cr"
require "./components/event_declaration.cr"
require "./components/reactor.cr"
require "./components/event_bus.cr"
require "./components/event_dsl.cr"
require "./components/event_handlers.cr"
require "./components/event.cr"
require "./components/projection.cr"
require "./components/projection_meta.cr"
require "./exceptions/schema_drift.cr"
require "./components/projection_dsl.cr"
require "./components/projection_registry.cr"

# Infrastructure adapters
# # Event stores
require "./adapters/eventstores/eventstore.cr"
require "./adapters/eventstores/in_memory.cr"
require "./adapters/eventstores/postgres.cr"

# # Queues
require "./adapters/queues/queue.cr"
require "./adapters/queues/in_memory.cr"
require "./adapters/queues/postgres.cr"
