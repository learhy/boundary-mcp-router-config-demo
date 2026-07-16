# Boundary MCP Router Configuration Demo

An AI agent (Claude Code or IBM Bob) uses a [Boundary MCP server](https://github.com/learhy/boundary-mcp) to connect to 3 FRR (Free Range Routing) routers through HashiCorp Boundary, configure BGP peering in a ring topology, and verify the configuration with diagnostic CLI commands.

## What the Demo Shows

1. **TCP targets with brokered credentials** — each router is registered as a Boundary TCP target on port 2024. Boundary brokers a username/password credential so the agent never handles credentials directly.
2. **Agent-driven network configuration** — the agent discovers targets via the MCP `list_targets` tool, connects to each router's CLI via `connect_tcp`, sends vtysh configuration commands, and runs `show bgp summary` to verify peering.
3. **Per-router host sets** — each target points to a dedicated host set containing only one router, so the agent can address a specific router by its target ID.

## Topology

```
        R1 (AS 65001)
       /              \
      /                \
  R2 (AS 65002) -- R3 (AS 65003)
```

- **R1**: 10.100.1.1, AS 65001, loopback 10.1.1.1/32, peers with R2 + R3
- **R2**: 10.100.2.1, AS 65002, loopback 10.2.2.2/32, peers with R1 + R3
- **R3**: 10.100.3.1, AS 65003, loopback 10.3.3.3/32, peers with R1 + R2

Each router runs FRR (Free Range Routing) in a Docker container with a socat-based TCP CLI on port 2024 that provides password-authenticated access to vtysh.

## Prerequisites

| Requirement | Install command |
|---|---|
| Docker + Docker Compose | [docs.docker.com](https://docs.docker.com/get-docker/) |
| Go 1.22+ | `brew install go` or [go.dev/dl](https://go.dev/dl/) |
| `boundary` CLI | [developer.hashicorp.com/boundary/install](https://developer.hashicorp.com/boundary/install) |
| `python3` | `apt install python3` / `brew install python` |
| `sshpass` | `apt install sshpass` / `brew install sshpass` |
| Claude Code | `npm install -g @anthropic-ai/claude-code` |

## Step-by-Step Reproduction

### Step 1: Clone the repos

```bash
git clone https://github.com/learhy/boundary-mcp.git
git clone https://github.com/learhy/boundary-mcp-router-config-demo.git
```

### Step 2: Build the MCP server

```bash
cd boundary-mcp
go build -o boundary-mcp ./cmd/boundary-mcp/
```

Note the path to the built binary. You will need it for the `.mcp.json` config.

### Step 3: Start the Docker stack

```bash
cd boundary-mcp-router-config-demo/docker
docker compose up -d --build
```

This starts 5 containers:

| Container | Purpose | Port |
|---|---|---|
| `bgp-demo-boundary` | Boundary controller + worker (dev mode) | 9200 (API), 9202 (proxy) |
| `bgp-demo-db` | PostgreSQL for Boundary state | internal |
| `bgp-demo-r1` | FRR Router 1 + socat TCP CLI | 2024 |
| `bgp-demo-r2` | FRR Router 2 + socat TCP CLI | 2024 |
| `bgp-demo-r3` | FRR Router 3 + socat TCP CLI | 2024 |

Wait ~15 seconds for Boundary to initialize. Verify:

```bash
curl -s http://127.0.0.1:9200/v1/scopes/global
# Should return JSON with "Unauthenticated" message (HTTP 401) — that's correct
```

### Step 4: Bootstrap Boundary resources

The bootstrap script creates all the Boundary resources the agent needs: org, project, host catalog, 3 hosts (one per router), 3 per-router host sets, a credential store with username/password, and 3 TCP targets with brokered credentials.

```bash
cd boundary-mcp-router-config-demo/scripts
BOUNDARY_ADDR=http://127.0.0.1:9200 python3 bootstrap-boundary.py
```

Expected output:

```
=== Demo 1: BGP Router Ring Bootstrap ===
Waiting for Boundary controller... OK
Authenticating... OK (token: at_xxxxx...)

=== Creating org and project ===
Org: o_xxx  Project: p_xxx

=== Creating host catalog ===
Host Catalog: hcst_xxx

=== Creating hosts and host sets ===
  Host router-1 (10.100.1.1): hst_xxx
  Host Set router-1-set: hsst_xxx
  ...

=== Creating credentials ===
Credential: credup_xxx

=== Creating TCP targets ===
  router-1-cli: ttcp_xxx
    host source + brokered credential added
  ...

=== Bootstrap complete ===
Token for .mcp.json: at_xxxxxxxxx
```

Save the token from the last line — you need it for Step 5.

### Step 5: Configure the MCP server connection

Create or update `.mcp.json` in the repo root:

```bash
cd boundary-mcp-router-config-demo
cat > .mcp.json << 'EOF'
{
  "mcpServers": {
    "boundary": {
      "command": "/absolute/path/to/boundary-mcp/boundary-mcp",
      "env": {
        "BOUNDARY_ADDR": "http://127.0.0.1:9200",
        "BOUNDARY_TOKEN": "PASTE_TOKEN_FROM_BOOTSTRAP",
        "BOUNDARY_TLS_INSECURE": "true"
      }
    }
  }
}
EOF
```

Replace `/absolute/path/to/boundary-mcp/boundary-mcp` with the actual path from Step 2.
Replace `PASTE_TOKEN_FROM_BOOTSTRAP` with the token from Step 4.

### Step 6: Run the agent

```bash
cd boundary-mcp-router-config-demo
claude --dangerously-skip-permissions -p "$(cat CLAUDE.md)"
```

Or interactively:

```bash
claude --dangerously-skip-permissions
# Then paste the contents of CLAUDE.md as your prompt
```

### Step 7: What the agent does

The agent will:

1. **Discover targets** — calls `list_targets` to find `router-1-cli`, `router-2-cli`, `router-3-cli`
2. **Connect to each router** — calls `connect_tcp` with the CLI password `fr12pass!` to authenticate to vtysh
3. **Configure BGP** — sends vtysh commands to enter config mode, create BGP instances, add neighbors, and advertise networks:
   ```
   configure terminal
   router bgp 65001
   neighbor 10.100.2.1 remote-as 65002
   neighbor 10.100.3.1 remote-as 65003
   network 10.1.1.1/32
   end
   write memory
   ```
4. **Verify** — waits for BGP convergence, then runs `show bgp summary` and `show ip route bgp` on each router

### Step 8: Verify manually (optional)

```bash
# Connect to a router CLI directly through Docker
docker exec -it bgp-demo-r1 vtysh -c "show bgp summary"

# Check active sessions in Boundary
export BOUNDARY_ADDR=http://127.0.0.1:9200
export BOUNDARY_KEYRING_TYPE=none
export BOUNDARY_TOKEN=<token from bootstrap>
boundary sessions list -scope-id <project-id> -token env://BOUNDARY_TOKEN
```

## Cleanup

```bash
cd boundary-mcp-router-config-demo/docker
docker compose down -v
```

## How It Works

### FRR Router Containers

Each FRR router runs in a Docker container built from `frrouting/frr:latest` with:
- **socat** listening on port 2024 — accepts TCP connections and pipes them to a password-authenticated vtysh session
- **SSH** on port 22 (not used in this demo, but available)
- **FRR daemons** (bgpd, ospfd, zebra, staticd) managed by FRR's built-in process supervisor

The `cli-wrapper.sh` script in each router's config directory handles the password prompt:

```bash
#!/bin/bash
read -r -p "Password: " input
if [ "$input" != "fr12pass!" ]; then
  echo "Access denied"
  exit 1
fi
exec vtysh
```

### Boundary MCP Server

The [boundary-mcp](https://github.com/learhy/boundary-mcp) server exposes 48 tools as MCP tools:

- **Read tools (35)**: list/read for scopes, targets, hosts, sessions, workers, users, groups, roles, auth methods, credentials, recordings
- **Write tools (10)**: create host catalogs, host sets, hosts, TCP/SSH targets, credential stores, credentials, credential libraries, update targets
- **Connect tools (3)**: `connect_ssh`, `connect_tcp`, `connect_ssh_interactive`

The `connect_tcp` tool:
1. Calls `boundary connect -target-id <id> -exec python3 -- -c <script> <command>`
2. Boundary starts a local TCP proxy and sets `BOUNDARY_PROXIED_IP` and `BOUNDARY_PROXIED_PORT` env vars
3. The Python script connects to the proxy port, reads the initial prompt, sends the command + newline, and reads the response

### Boundary Resource Model

```
Org: network-org
  └─ Project: network-project
       ├─ Host Catalog: routers (static)
       │    ├─ Host Set: router-1-set → [router-1 (10.100.1.1)]
       │    ├─ Host Set: router-2-set → [router-2 (10.100.2.1)]
       │    └─ Host Set: router-3-set → [router-3 (10.100.3.1)]
       ├─ Credential Store: router-creds (static)
       │    └─ Credential: router-cli-cred (username_password: frruser / fr12pass!)
       ├─ Target: router-1-cli (tcp, port 2024, host source: router-1-set, brokered cred: router-cli-cred)
       ├─ Target: router-2-cli (tcp, port 2024, host source: router-2-set, brokered cred: router-cli-cred)
       └─ Target: router-3-cli (tcp, port 2024, host source: router-3-set, brokered cred: router-cli-cred)
```

## Troubleshooting

### Boundary won't start
- Check Postgres is healthy: `docker logs bgp-demo-db`
- Check Boundary logs: `docker logs bgp-demo-boundary` — look at the **first** error, not the last
- The dev server needs 8+ char passwords (`adminadmin` / `useruseruser`) — already set in the compose file

### FRR routers won't start
- Rebuild images: `docker compose build` (the Dockerfiles were updated to use `frrouting/frr:latest`)
- Check router logs: `docker logs bgp-demo-r1`

### MCP server can't connect
- Verify the boundary-mcp binary path in `.mcp.json` is absolute
- Verify `BOUNDARY_TOKEN` is set and starts with `at_`
- Test: `BOUNDARY_ADDR=http://127.0.0.1:9200 BOUNDARY_TOKEN=<token> <path>/boundary-mcp` should print JSON on stderr

### connect_tcp returns "Connection reset"
- The router's socat CLI may not be ready yet — wait a few seconds after `docker compose up`
- Check the router is running: `docker ps | grep bgp-demo-r1`
- Test the CLI directly: `docker exec bgp-demo-r1 sh -c 'echo "fr12pass!" | nc 127.0.0.1 2024'`

### Agent connects to wrong router
- Each target has its own host set with only one router — this was fixed from an earlier version where all routers shared one host set
- Verify: `boundary targets read -id <target-id> -token env://BOUNDARY_TOKEN` should show a single `host_source_id`

## File Structure

```
boundary-mcp-router-config-demo/
├── README.md                          # This file
├── CLAUDE.md                          # Agent prompt for Claude Code
├── .mcp.json                          # MCP server config (template)
├── docker/
│   ├── docker-compose.yml             # 5 services: Boundary + Postgres + 3 FRR routers
│   └── config/
│       ├── frr-r1/                     # Router 1: Dockerfile, entrypoint, cli-wrapper, frr.conf
│       ├── frr-r2/                     # Router 2
│       └── frr-r3/                     # Router 3
└── scripts/
    └── bootstrap-boundary.py           # Python script to create all Boundary resources
```

## Using IBM Bob

This demo works with any MCP-compatible AI agent. To use IBM Bob:

1. Configure Bob's MCP client to launch the `boundary-mcp` binary with the same env vars
2. Use the `CLAUDE.md` content as the task prompt
3. The tools are the same regardless of which agent consumes them

## Related

- [boundary-mcp](https://github.com/learhy/boundary-mcp) — the MCP server (48 tools)
- [boundary-mcp-cert-rotation-demo](https://github.com/learhy/boundary-mcp-cert-rotation-demo) — Demo 2: SSH cert rotation