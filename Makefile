PROJECT_NAME           ?= crystal-es
PROJECT                ?= tristanholl/$(PROJECT_NAME)
BUILD_TAG              ?= build-local
# CACHE_TAG              ?= $(BUILD_TAG)
DOCKER_COMPOSE_PROJECT ?= $(PROJECT_NAME)
SERVICE_IMAGE						= $(PROJECT):$(BUILD_TAG)

revision:
	$(eval GIT_COMMIT = $(shell git rev-parse HEAD))
	echo $(GIT_COMMIT) > ./REVISION.txt

build-service: revision
	docker build \
		--platform=linux/amd64 \
		--label "git_commit=$(GIT_COMMIT)" \
		--tag $(SERVICE_IMAGE) \
		--target service \
		.

build: build-service

# Development
dev: revision dev-up dev-prepare
	docker-compose exec $(PROJECT_NAME) bash
dev-down:
	docker-compose down --remove-orphans -v

dev-up:
	docker-compose up --build -d

# Test
test: test-up test-setup test-run test-down

test-lint:
	docker-compose -f docker-compose.test.yml -p $(DOCKER_COMPOSE_PROJECT) run --rm $(PROJECT_NAME) crystal tool format --check

test-down:
	docker-compose -f docker-compose.test.yml -p $(DOCKER_COMPOSE_PROJECT) down --remove-orphans --volumes

test-run:
	docker-compose -f docker-compose.test.yml -p $(DOCKER_COMPOSE_PROJECT) run --rm $(PROJECT_NAME) crystal spec ./spec

test-setup:
	# No setup

test-up: revision
	docker-compose -f docker-compose.test.yml -p $(DOCKER_COMPOSE_PROJECT) up -d --force-recreate

test-info:
	docker-compose -v
