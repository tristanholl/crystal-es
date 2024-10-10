# Load third party dependencies
require "json"
require "uuid"
require "uuid/json"
require "http/status"

# Config of the library
require "./config.cr"

# Event sourcing exceptions
require "./exceptions/error.cr"
require "./exceptions/invalid_state.cr"
require "./exceptions/not_found.cr"

# Event sourcing components
require "./components/aggregate.cr"
require "./components/command.cr"
require "./components/event.cr"
require "./components/projection.cr"

# Infrastructure adapters
require "./adapters/eventstores/eventstore.cr"
require "./adapters/eventstores/in_memory.cr"
require "./adapters/eventstores/postgres.cr"
