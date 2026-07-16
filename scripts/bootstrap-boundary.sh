#!/bin/bash
set -euo pipefail

# Demo 1 Bootstrap: Set up Boundary resources for 3 FRR routers
# Creates: org, project, host catalog, 3 hosts, 3 TCP targets with brokered credentials
#
# Usage: ./scripts/bootstrap-boundary.sh
# Requires: BOUNDARY_ADDR and BOUNDARY_TOKEN env vars set

BOUNDARY_ADDR="${BOUNDARY_ADDR:-http://127.0.0.1:9200}"
export BOUNDARY_ADDR

# Authenticate if no token set
if [ -z "${BOUNDARY_TOKEN:-}" ]; then
  echo "No BOUNDARY_TOKEN set. Authenticating as admin..."
  # Wait for boundary to be ready
  for i in $(seq 1 30); do
    if boundary scopes list -token env://BOUNDARY_TOKEN -format json >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  export BOUNDARY_KEYRING_TYPE=none
  TOKEN=$(boundary authenticate password \
    -auth-method-id ampw_1234567890 \
    -login-name admin \
    -password env://ADMIN_PW \
    -keyring-type none 2>/dev/null | grep "Token" | head -1 | awk '{print $NF}')
  if [ -z "$TOKEN" ]; then
    # Try alternate parse
    TOKEN=$(boundary authenticate password \
      -auth-method-id ampw_1234567890 \
      -login-name admin \
      -password adminadmin \
      -keyring-type none 2>&1 | grep -oP 'at_\w+' | head -1)
  fi
  export BOUNDARY_TOKEN="$TOKEN"
  echo "Authenticated. Token: ${TOKEN:0:10}..."
fi

echo "=== Creating org and project ==="

# Create org
ORG_ID=$(boundary scopes create -name "network-org" -description "Network automation org" -scope-id global -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || echo "")
if [ -z "$ORG_ID" ]; then
  # Maybe already exists
  ORG_ID=$(boundary scopes list -scope-id global -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; [print(s['id']) for s in json.load(sys.stdin)['items'] if s['name']=='network-org']" 2>/dev/null)
fi
echo "Org ID: $ORG_ID"

# Create project
PROJ_ID=$(boundary scopes create -name "network-project" -description "Network automation project" -scope-id "$ORG_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || echo "")
if [ -z "$PROJ_ID" ]; then
  PROJ_ID=$(boundary scopes list -scope-id "$ORG_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; [print(s['id']) for s in json.load(sys.stdin)['items'] if s['name']=='network-project']" 2>/dev/null)
fi
echo "Project ID: $PROJ_ID"

echo "=== Creating host catalog and hosts ==="

# Create host catalog
HC_ID=$(boundary host-catalogs create static -name "routers" -description "FRR router catalog" -scope-id "$PROJ_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || echo "")
if [ -z "$HC_ID" ]; then
  HC_ID=$(boundary host-catalogs list -scope-id "$PROJ_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; [print(h['id']) for h in json.load(sys.stdin)['items'] if h['name']=='routers']" 2>/dev/null)
fi
echo "Host Catalog ID: $HC_ID"

# Create host set
HS_ID=$(boundary host-sets create static -name "all-routers" -host-catalog-id "$HC_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || echo "")
if [ -z "$HS_ID" ]; then
  HS_ID=$(boundary host-sets list -host-catalog-id "$HC_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; [print(h['id']) for h in json.load(sys.stdin)['items'] if h['name']=='all-routers']" 2>/dev/null)
fi
echo "Host Set ID: $HS_ID"

# Create 3 hosts (one per router)
for i in 1 2 3; do
  HOST_NAME="router-${i}"
  HOST_ADDR="10.100.${i}.1"
  HOST_ID=$(boundary hosts create static -name "$HOST_NAME" -address "$HOST_ADDR" -host-catalog-id "$HC_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || echo "")
  if [ -z "$HOST_ID" ]; then
    HOST_ID=$(boundary hosts list -host-catalog-id "$HC_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; [print(h['id']) for h in json.load(sys.stdin)['items'] if h['name']=='$HOST_NAME']" 2>/dev/null)
  fi
  echo "Host $HOST_NAME ($HOST_ADDR): $HOST_ID"
  
  # Add host to the set
  boundary host-sets add-hosts -id "$HS_ID" -token env://BOUNDARY_TOKEN -host "$HOST_ID" 2>/dev/null || true
done

echo "=== Creating credential store and credentials ==="

# Create credential store
CS_ID=$(boundary credential-stores create -name "router-creds" -scope-id "$PROJ_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || echo "")
if [ -z "$CS_ID" ]; then
  CS_ID=$(boundary credential-stores list -scope-id "$PROJ_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; [print(c['id']) for c in json.load(sys.stdin)['items'] if c['name']=='router-creds']" 2>/dev/null)
fi
echo "Credential Store ID: $CS_ID"

# Create username/password credential for router CLI access
CRED_ID=$(boundary credentials create username-password \
  -name "router-cli-cred" \
  -credential-store-id "$CS_ID" \
  -username "frruser" \
  -password "fr12pass!" \
  -format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || echo "")
if [ -z "$CRED_ID" ]; then
  CRED_ID=$(boundary credentials list -credential-store-id "$CS_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; [print(c['id']) for c in json.load(sys.stdin)['items'] if c['name']=='router-cli-cred']" 2>/dev/null)
fi
echo "Credential ID: $CRED_ID"

# Create credential library for brokering
CL_ID=$(boundary credential-libraries create \
  -name "router-cli-lib" \
  -credential-store-id "$CS_ID" \
  -credential-type username_password \
  -format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || echo "")
if [ -z "$CL_ID" ]; then
  CL_ID=$(boundary credential-libraries list -credential-store-id "$CS_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; [print(c['id']) for c in json.load(sys.stdin)['items'] if c['name']=='router-cli-lib']" 2>/dev/null)
fi
echo "Credential Library ID: $CL_ID"

echo "=== Creating TCP targets for each router ==="

# Create 3 TCP targets (one per router, port 2024 for the CLI)
for i in 1 2 3; do
  TARGET_NAME="router-${i}-cli"
  TARGET_ID=$(boundary targets create tcp \
    -name "$TARGET_NAME" \
    -scope-id "$PROJ_ID" \
    -default-port 2024 \
    -host-source-id "$HS_ID" \
    -brokered-credential-source-id "$CRED_ID" \
    -format json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['item']['id'])" 2>/dev/null || echo "")
  if [ -z "$TARGET_ID" ]; then
    TARGET_ID=$(boundary targets list -scope-id "$PROJ_ID" -token env://BOUNDARY_TOKEN -format json 2>/dev/null | python3 -c "import sys,json; [print(t['id']) for t in json.load(sys.stdin)['items'] if t['name']=='$TARGET_NAME']" 2>/dev/null)
  fi
  echo "Target $TARGET_NAME: $TARGET_ID"
done

echo ""
echo "=== Bootstrap complete ==="
echo "Org: $ORG_ID  Project: $PROJ_ID"
echo "Host Catalog: $HC_ID  Host Set: $HS_ID"
echo "Credential Store: $CS_ID  Credential: $CRED_ID  Library: $CL_ID"
echo ""
echo "3 TCP targets created on port 2024 with brokered username/password credentials."
echo "The agent can now use boundary-mcp to:"
echo "  1. List targets to find router-1-cli, router-2-cli, router-3-cli"
echo "  2. Authorize sessions and connect to each router's CLI"
echo "  3. Configure BGP peering between the routers"
echo "  4. Verify with show bgp summary, show ip route, etc."