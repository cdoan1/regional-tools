#!/bin/bash

# HyperFleet Port-Forward Setup Script
# Establishes kubectl port-forward tunnels to all HyperFleet services for testing

set -e

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

success() { echo -e "${GREEN}[✓]${NC} $*"; }
failure() { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${YELLOW}[i]${NC} $*"; }

# Hardcoded configuration
NAMESPACE="hyperfleet-system"
API_SVC="hyperfleet-api"
SENTINEL_SVC="hyperfleet-sentinel"
ADAPTER_SVC="hyperfleet-adapter"
PID_FILE="/tmp/hyperfleet-port-forwards.pid"

# Cleanup function
cleanup() {
  info "Cleaning up port-forwards..."
  if [[ -f "$PID_FILE" ]]; then
    while read -r pid; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
      fi
    done < "$PID_FILE"
    rm -f "$PID_FILE"
  fi
  info "Cleanup complete"
  exit 0
}

# Trap signals for cleanup
trap cleanup SIGINT SIGTERM EXIT

# Check prerequisites
check_prerequisites() {
  if ! command -v kubectl >/dev/null 2>&1; then
    failure "kubectl not found"
    exit 1
  fi

  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    failure "Namespace $NAMESPACE not found or not accessible"
    exit 1
  fi
}

# Kill existing port-forwards
kill_existing_port_forwards() {
  info "Checking for existing port-forwards..."

  # Kill processes from previous runs
  if [[ -f "$PID_FILE" ]]; then
    while read -r pid; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        info "Killed existing port-forward (PID: $pid)"
      fi
    done < "$PID_FILE"
    rm -f "$PID_FILE"
  fi

  # Kill any kubectl port-forward for hyperfleet services
  pkill -f "kubectl port-forward.*hyperfleet" || true
  sleep 1
}

# Wait for port to be ready
wait_for_port() {
  local port=$1
  local max_attempts=10
  local attempt=1

  while [[ $attempt -le $max_attempts ]]; do
    if nc -z localhost "$port" 2>/dev/null || curl -s http://localhost:"$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    ((attempt++))
  done

  return 1
}

# Setup port-forward
setup_port_forward() {
  local service=$1
  local remote_port=$2
  local local_port=$3
  local description=$4

  kubectl port-forward -n "$NAMESPACE" "svc/$service" "$local_port:$remote_port" >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" >> "$PID_FILE"

  if wait_for_port "$local_port"; then
    success "$service:$remote_port -> localhost:$local_port ($description)"
    return 0
  else
    failure "Failed to establish port-forward for $service:$remote_port"
    return 1
  fi
}

# Verify service connectivity
verify_connectivity() {
  local url=$1
  local name=$2

  if curl -s -f "$url" >/dev/null 2>&1; then
    success "$name accessible at $url"
    return 0
  else
    failure "$name not accessible at $url"
    return 1
  fi
}

# Main
main() {
  echo "Setting up HyperFleet port-forwards..."
  echo ""

  check_prerequisites
  kill_existing_port_forwards

  # Clear PID file
  > "$PID_FILE"

  # Setup port-forwards
  setup_port_forward "$API_SVC" 8000 8000 "API"
  setup_port_forward "$API_SVC" 8080 8080 "Health"
  setup_port_forward "$API_SVC" 9090 9090 "Metrics"
  setup_port_forward "$SENTINEL_SVC" 8080 8081 "Sentinel Health"
  setup_port_forward "$ADAPTER_SVC" 8081 8082 "Adapter Health"

  echo ""
  echo "Verifying connections..."

  # Verify connectivity
  verify_connectivity "http://localhost:8000/api/hyperfleet/v1/clusters" "API"
  verify_connectivity "http://localhost:8080/healthz" "API Health"
  verify_connectivity "http://localhost:8081/health" "Sentinel"
  verify_connectivity "http://localhost:8082/healthz" "Adapter"

  echo ""
  success "Port-forwards ready! Press Ctrl+C to stop."
  echo ""

  # Keep running
  while true; do
    sleep 1
  done
}

main
