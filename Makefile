# Project configuration
PROJECT_NAME := crystal-es
COMPOSE_FILE := docker-compose.yml
COMPOSE_TEST_FILE := docker-compose.test.yml
COMPOSE_PROJECT_NAME := $(PROJECT_NAME)
COMPOSE_CMD := docker compose

# Docker image configuration
SERVICE_IMAGE := $(PROJECT_NAME):dev

# Environment files
ENV_FILE := .env-dev
ENV_FILE_TEST := .env-test
ENV_TEMPLATE := .env-dev.template

# Compose arguments
COMPOSE_ARGS := -f $(COMPOSE_FILE) -p $(COMPOSE_PROJECT_NAME)
COMPOSE_TEST_ARGS := -f $(COMPOSE_TEST_FILE) -p $(COMPOSE_PROJECT_NAME)

# Docker compose command helpers
dc        = $(COMPOSE_CMD) $(COMPOSE_ARGS) $(1)
dct       = $(COMPOSE_CMD) $(COMPOSE_TEST_ARGS) $(1)
dc-run    = $(call dc, run --entrypoint "bash -c" --rm cmd $(1))
# Same as dc-run but without starting linked services, for targets that need the
# mounted working tree and nothing else (no database).
dc-run-solo = $(call dc, run --no-deps --entrypoint "bash -c" --rm cmd $(1))
dct-run    = $(call dct, run --entrypoint "bash -c" --rm cmd $(1))
dc-exec   = $(call dc, exec console $(1))

# Function to check if image exists
check_image_exists = $(shell docker image inspect $(SERVICE_IMAGE) >/dev/null 2>&1 && echo "true" || echo "false")

# Default target
all: help

# Help target
help:
	@echo "Available targets:"
	@echo "  build   			- Build docker image if it doesn't exist"
	@echo "  clean   			- Remove all persisted data"
	@echo "  console 			- Open a console in the web container"
	@echo "  dev     			- Run development environment (default)"
	@echo "  docker-info  - Outputs the current docker and docker-compose version"
	@echo "  down    			- Stop and remove containers and networks"
	@echo "  env     			- Create .env-dev and .env-test files if they don't exist"
	@echo "  lint    			- Runs the formatter check and Ameba"
	@echo "  lint-ameba 		- Runs Ameba static analysis only"
	@echo "  lint-fix 			- Formats the code and auto-corrects Ameba offences"
	@echo "  lint-format 		- Runs the formatter check only"
	@echo "  logs    			- Tail docker logs"
	@echo "  rebuild 			  - Force rebuild of the Docker image"
	@echo "  reset   			- Reset the local environment and rebuild from scratch"
	@echo "  restart 			- Restart the development environment"
	@echo "  shards  			- Install dependencies"
	@echo "  start   			- Start the app"
	@echo "  status  			- Check container status"
	@echo "  stop    			- Stop docker services"
	@echo "  test    			- Run tests"

# Development environment
dev: env build up setup-db console

# Start app, jobs, and css containers
start: env build up setup-db
	$(call dc, up -d --scale app=1)

# Build image if it doesn't exist
build-image:
	@if [ "$(call check_image_exists)" = "false" ]; then \
		echo "Building Docker image $(SERVICE_IMAGE)..."; \
		docker build -t $(SERVICE_IMAGE) -f Dockerfile.dev .; \
	else \
		echo "Docker image $(SERVICE_IMAGE) already exists. Skipping build."; \
	fi

# Build target (now just an alias for build-image)
build: build-image

# Force rebuild of the Docker image
rebuild:
	@echo "Forcing rebuild of Docker image $(SERVICE_IMAGE)..."
	docker build --no-cache -t $(SERVICE_IMAGE) -f Dockerfile.dev .

# Start services
up:
	$(call dc, up -d database console)

# Open console
console:
	$(call dc-exec, bash)

# Stop services
stop:
	$(call dc, stop)

# Stop and remove containers
down:
	$(call dc, down --remove-orphans)

# Remove all persisted data
clean:
	$(call dc, down --remove-orphans -v)

# Restart development environment
restart: down dev

# restart the database
restart-db:
	$(call dc, restart database)

# Reset everything to a clean state
reset: clean rebuild dev

# Check container status
ps: status
status:
	$(call dc, ps)

# Tail logs
logs:
	$(call dc, logs -f)

# Create .env-dev file if it doesn't exist
env:
	@test -f $(ENV_FILE) || cp $(ENV_TEMPLATE) $(ENV_FILE)
	@test -f $(ENV_FILE_TEST) || cp $(ENV_TEMPLATE) $(ENV_FILE_TEST)

# Install dependencies
shards:
	$(call dc-run, "shards install")

# TODO: Setup the database
setup-db:
# #  $(call dc-run, "")

# Run tests
test:
	$(call dct-run, "crystal spec spec/")

# Remove all persisted test data
test-clean:
	$(call dct, down --remove-orphans -v)

# Run all linters
lint: lint-format lint-ameba

# Verify formatting without rewriting any file
lint-format:
	$(call dct-run, "crystal tool format --check")

# Static analysis with Ameba (https://github.com/crystal-ameba/ameba).
# The binary is baked into the dev image; it is only built here when the image
# predates that or when the target is run against a bare checkout.
lint-ameba:
	$(call dct-run, "[ -x ./bin/ameba ] || shards build ameba; ./bin/ameba")

# Format the code and auto-correct every Ameba offence that can be corrected.
# This one runs on the dev compose file because that is the one that mounts the
# working tree, so the rewrites land on the host instead of in a discarded layer.
lint-fix: env
	$(call dc-run-solo, "shards check >/dev/null 2>&1 || shards install; [ -x ./bin/ameba ] || shards build ameba; crystal tool format; ./bin/ameba --fix")

docker-info:
	docker -v
	docker-compose -v
