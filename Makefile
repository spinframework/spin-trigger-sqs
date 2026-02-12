.PHONY: help build install test-e2e clean setup-elasticmq stop-elasticmq

ELASTICMQ_CONTAINER_NAME := spin-sqs-elasticmq
ELASTICMQ_IMAGE := softwaremill/elasticmq:latest
ELASTICMQ_PORT := 9324
ELASTICMQ_CONFIG := $(shell pwd)/e2e-test/elasticmq.conf
TEST_QUEUE_NAME := test-queue
SQS_ENDPOINT := http://localhost:$(ELASTICMQ_PORT)

format:
	cargo fmt --all

lint:
	cargo clippy --all-targets -- -D warnings

build:
	cargo build --release

install: build
	spin pluginify --install

setup-elasticmq:
	@echo "Setting up ElasticMQ in Docker container..."
	@if docker ps --filter "name=$(ELASTICMQ_CONTAINER_NAME)" --format '{{.Names}}' | grep -q $(ELASTICMQ_CONTAINER_NAME); then \
		echo "ElasticMQ container is already running"; \
	else \
		if [ ! -f "$(ELASTICMQ_CONFIG)" ]; then \
			echo "Error: Configuration file not found at $(ELASTICMQ_CONFIG)"; \
			exit 1; \
		fi; \
		echo "Pulling ElasticMQ Docker image..."; \
		docker pull $(ELASTICMQ_IMAGE); \
		echo "Starting ElasticMQ container with custom configuration..."; \
		docker run -d \
			--name $(ELASTICMQ_CONTAINER_NAME) \
			-p $(ELASTICMQ_PORT):9324 \
			-v $(ELASTICMQ_CONFIG):/opt/elasticmq.conf \
			$(ELASTICMQ_IMAGE); \
		echo "Waiting for ElasticMQ to be ready..."; \
		for i in 1 2 3 4 5 6 7 8 9 10; do \
			if curl -s $(SQS_ENDPOINT)/ > /dev/null 2>&1; then \
				echo "ElasticMQ is ready!"; \
				exit 0; \
			fi; \
			echo "Waiting... ($$i/10)"; \
			sleep 2; \
		done; \
		echo "ElasticMQ is running in container: $(ELASTICMQ_CONTAINER_NAME)"; \
	fi

stop-elasticmq:
	@echo "Stopping ElasticMQ container..."
	@if docker ps -a --filter "name=$(ELASTICMQ_CONTAINER_NAME)" --format '{{.Names}}' | grep -q $(ELASTICMQ_CONTAINER_NAME); then \
		docker stop $(ELASTICMQ_CONTAINER_NAME) 2>/dev/null || true; \
		docker rm $(ELASTICMQ_CONTAINER_NAME) 2>/dev/null || true; \
		echo "ElasticMQ container stopped and removed."; \
	else \
		echo "ElasticMQ container is not running."; \
	fi

test-e2e:
	@echo "Running end-to-end tests..."
	@./e2e-test/e2e-test.sh

test-e2e-full: setup-elasticmq
	@echo "Running full e2e test with ElasticMQ setup..."
	@$(MAKE) test-e2e 
	@$(MAKE) test-e2e || ($(MAKE) stop-elasticmq && exit 1)
	@$(MAKE) stop-elasticmq
