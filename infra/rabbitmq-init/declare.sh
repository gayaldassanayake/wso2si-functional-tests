#!/usr/bin/env bash
# declare.sh — declare RabbitMQ exchanges, queues, and bindings for TC45
# Invoked by scripts/setup.sh --rabbitmq after the container becomes healthy.

set -euo pipefail

CONTAINER="${1:-si-test-rabbitmq}"

declare_resource() {
    docker exec "${CONTAINER}" rabbitmqadmin "$@"
}

echo "  Declaring RabbitMQ topology for TC45..."

declare_resource declare exchange name=si-test-rmq-in  type=direct durable=true
declare_resource declare exchange name=si-test-rmq-out type=direct durable=true

declare_resource declare queue name=si-test-rmq-in-q  durable=true
declare_resource declare queue name=si-test-rmq-out-q durable=true

declare_resource declare binding source=si-test-rmq-in  destination=si-test-rmq-in-q  routing_key=si-test-rmq-in-q
declare_resource declare binding source=si-test-rmq-out destination=si-test-rmq-out-q routing_key=si-test-rmq-out-q

echo "  RabbitMQ topology declared: exchanges (si-test-rmq-in, si-test-rmq-out), queues (*-in-q, *-out-q)"
