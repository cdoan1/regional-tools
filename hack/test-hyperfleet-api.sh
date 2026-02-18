#!/bin/bash

# HyperFleet API Test Script
# Validates HyperFleet API functionality using curl commands

set -e

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

success() { echo -e "  ${GREEN}[✓]${NC} $*"; }
failure() { echo -e "  ${RED}[✗]${NC} $*"; }
info() { echo -e "  ${YELLOW}[i]${NC} $*"; }
test_header() { echo -e "\n${BLUE}[$1]${NC} $2"; }

# Hardcoded configuration
API_BASE="http://localhost:8000"
HEALTH_BASE="http://localhost:8080"
METRICS_BASE="http://localhost:9090"
TEST_CLUSTER_ID="test-cluster-001"

# Test counters
PASSED=0
FAILED=0
TOTAL=0

# Check prerequisites
check_prerequisites() {
  local missing=0

  if ! command -v curl >/dev/null 2>&1; then
    failure "curl not found"
    missing=1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    failure "jq not found"
    missing=1
  fi

  if ! curl -s -f "$HEALTH_BASE/healthz" >/dev/null 2>&1; then
    failure "HyperFleet API not reachable at $HEALTH_BASE"
    failure "Run setup-hyperfleet-port-forwards.sh first"
    missing=1
  fi

  if [[ $missing -eq 1 ]]; then
    exit 1
  fi
}

# HTTP request helper
http_request() {
  local method=$1
  local url=$2
  local data=${3:-}
  local expected_status=${4:-200}

  local response
  if [[ -n "$data" ]]; then
    response=$(curl -s -w "\n%{http_code}" -X "$method" \
      -H "Content-Type: application/json" \
      -d "$data" \
      "$url" 2>&1)
  else
    response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" 2>&1)
  fi

  local body=$(echo "$response" | head -n -1)
  local status=$(echo "$response" | tail -n 1)

  if [[ "$status" == "$expected_status" ]]; then
    echo "$body"
    return 0
  else
    echo "ERROR: Expected $expected_status, got $status" >&2
    echo "Response: $body" >&2
    return 1
  fi
}

# Test result tracker
record_result() {
  ((TOTAL++))
  if [[ $1 -eq 0 ]]; then
    ((PASSED++))
    return 0
  else
    ((FAILED++))
    return 1
  fi
}

# Test 1: Health Checks
test_health_checks() {
  test_header "1/8" "Testing health endpoints..."

  # Liveness
  if curl -s -f "$HEALTH_BASE/healthz" >/dev/null 2>&1; then
    success "GET /healthz - healthy"
    record_result 0
  else
    failure "GET /healthz - failed"
    record_result 1
  fi

  # Readiness
  if curl -s -f "$HEALTH_BASE/readyz" >/dev/null 2>&1; then
    success "GET /readyz - ready"
    record_result 0
  else
    failure "GET /readyz - failed"
    record_result 1
  fi

  # Metrics
  local metrics=$(curl -s "$METRICS_BASE/metrics")
  local bytes=${#metrics}
  if [[ $bytes -gt 0 ]]; then
    success "GET /metrics - $bytes bytes"
    record_result 0
  else
    failure "GET /metrics - empty response"
    record_result 1
  fi
}

# Test 2: List Clusters (Empty State)
test_list_clusters_empty() {
  test_header "2/8" "Testing list clusters..."

  local response
  if response=$(http_request GET "$API_BASE/api/hyperfleet/v1/clusters"); then
    local count=$(echo "$response" | jq -r '.items | length' 2>/dev/null || echo "0")
    success "GET /api/hyperfleet/v1/clusters - $count items"
    record_result 0
  else
    failure "GET /api/hyperfleet/v1/clusters - request failed"
    record_result 1
  fi
}

# Test 3: Create Test Cluster
test_create_cluster() {
  test_header "3/8" "Testing create cluster..."

  local payload=$(cat <<EOF
{
  "kind": "Cluster",
  "id": "$TEST_CLUSTER_ID",
  "name": "$TEST_CLUSTER_ID",
  "external_id": "test-external-001",
  "region": "us-east-1",
  "multi_az": true,
  "provision_shard_id": "test-shard",
  "cloud_provider": "aws",
  "status": "installing"
}
EOF
)

  local response
  if response=$(http_request POST "$API_BASE/api/hyperfleet/v1/clusters" "$payload" 201); then
    success "POST /api/hyperfleet/v1/clusters - 201 Created"
    record_result 0

    local cluster_id=$(echo "$response" | jq -r '.id' 2>/dev/null)
    if [[ "$cluster_id" == "$TEST_CLUSTER_ID" ]]; then
      success "Response contains cluster ID: $TEST_CLUSTER_ID"
      record_result 0
    else
      failure "Response missing cluster ID (got: $cluster_id)"
      record_result 1
    fi
  else
    failure "POST /api/hyperfleet/v1/clusters - request failed"
    record_result 1
    record_result 1  # Also fail the ID check
  fi
}

# Test 4: Get Test Cluster
test_get_cluster() {
  test_header "4/8" "Testing get cluster..."

  local response
  if response=$(http_request GET "$API_BASE/api/hyperfleet/v1/clusters/$TEST_CLUSTER_ID"); then
    success "GET /api/hyperfleet/v1/clusters/$TEST_CLUSTER_ID - 200 OK"
    record_result 0

    local name=$(echo "$response" | jq -r '.name' 2>/dev/null)
    if [[ "$name" == "$TEST_CLUSTER_ID" ]]; then
      success "Cluster name matches: $TEST_CLUSTER_ID"
      record_result 0
    else
      failure "Cluster name mismatch (got: $name)"
      record_result 1
    fi
  else
    failure "GET cluster - request failed"
    record_result 1
    record_result 1  # Also fail the name check
  fi
}

# Test 5: List Clusters (With Data)
test_list_clusters_with_data() {
  test_header "5/8" "Testing list clusters (with data)..."

  local response
  if response=$(http_request GET "$API_BASE/api/hyperfleet/v1/clusters"); then
    local count=$(echo "$response" | jq -r '.items | length' 2>/dev/null || echo "0")
    if [[ $count -gt 0 ]]; then
      success "GET /api/hyperfleet/v1/clusters - $count item(s) found"
      record_result 0
    else
      failure "Expected at least 1 cluster, got $count"
      record_result 1
    fi
  else
    failure "GET /api/hyperfleet/v1/clusters - request failed"
    record_result 1
  fi

  # Test pagination
  if response=$(http_request GET "$API_BASE/api/hyperfleet/v1/clusters?page=1&size=10"); then
    success "Pagination works (page=1&size=10)"
    record_result 0
  else
    failure "Pagination failed"
    record_result 1
  fi
}

# Test 6: Update Cluster Status
test_update_cluster_status() {
  test_header "6/8" "Testing update cluster status..."

  local payload=$(cat <<EOF
{
  "status": "ready",
  "condition": "healthy"
}
EOF
)

  local response
  if response=$(http_request POST "$API_BASE/api/hyperfleet/v1/clusters/$TEST_CLUSTER_ID/statuses" "$payload" 200); then
    success "POST statuses - status updated to ready"
    record_result 0
  else
    failure "Status update failed"
    record_result 1
  fi
}

# Test 7: Delete Test Cluster
test_delete_cluster() {
  test_header "7/8" "Testing delete cluster..."

  if http_request DELETE "$API_BASE/api/hyperfleet/v1/clusters/$TEST_CLUSTER_ID" "" 204 >/dev/null 2>&1; then
    success "DELETE - 204 No Content"
    record_result 0
  else
    failure "DELETE failed"
    record_result 1
  fi

  # Verify deletion
  if ! curl -s -f "$API_BASE/api/hyperfleet/v1/clusters/$TEST_CLUSTER_ID" >/dev/null 2>&1; then
    success "Cluster no longer exists (404 confirmed)"
    record_result 0
  else
    failure "Cluster still exists after deletion"
    record_result 1
  fi
}

# Test 8: Idempotency Check
test_idempotency() {
  test_header "8/8" "Testing idempotency..."

  # Try to delete already-deleted cluster
  local status_code=$(curl -s -w "%{http_code}" -X DELETE \
    "$API_BASE/api/hyperfleet/v1/clusters/$TEST_CLUSTER_ID" \
    -o /dev/null)

  if [[ "$status_code" == "404" || "$status_code" == "204" ]]; then
    success "Delete non-existent cluster handled gracefully (status: $status_code)"
    record_result 0
  else
    failure "Unexpected status code: $status_code"
    record_result 1
  fi
}

# Print summary
print_summary() {
  echo ""
  echo "=== Test Results ==="
  echo "Passed:  $PASSED/$TOTAL"
  echo "Failed:  $FAILED/$TOTAL"
  echo ""

  if [[ $FAILED -eq 0 ]]; then
    success "All tests passed! ✓"
    return 0
  else
    failure "Some tests failed"
    return 1
  fi
}

# Main
main() {
  echo "=== HyperFleet API Test Suite ==="

  check_prerequisites

  test_health_checks
  test_list_clusters_empty
  test_create_cluster
  test_get_cluster
  test_list_clusters_with_data
  test_update_cluster_status
  test_delete_cluster
  test_idempotency

  print_summary
}

main
exit $?
