# Demo 1: BGP Router Configuration via Boundary MCP

## Your Role
You are a network automation agent. You have access to a Boundary MCP server that lets you connect to network routers through HashiCorp Boundary. Your task is to configure BGP peering on a 3-router ring topology.

## Network Topology
Three FRR (Free Range Routing) routers form a ring:
- **R1** (10.100.1.1, AS 65001, loopback 10.1.1.1/32) - peers with R2 and R3
- **R2** (10.100.2.1, AS 65002, loopback 10.2.2.2/32) - peers with R1 and R3
- **R3** (10.100.3.1, AS 65003, loopback 10.3.3.3/32) - peers with R1 and R2

Each router has a TCP CLI interface exposed on port 2024. Boundary brokers access through TCP targets with brokered credentials. The CLI requires a password (fr12pass!) before accepting commands.

## Your Task
1. List the available Boundary targets to find the 3 router CLI targets
2. For each router, use connect_tcp to send the password and verify connectivity
3. Configure BGP on each router:
   - R1: Enable BGP AS 65001, add neighbors R2 (10.100.2.1) and R3 (10.100.3.1), advertise loopback network
   - R2: Enable BGP AS 65002, add neighbors R1 (10.100.1.1) and R3 (10.100.3.1), advertise loopback network
   - R3: Enable BGP AS 65003, add neighbors R1 (10.100.1.1) and R2 (10.100.2.1), advertise loopback network
4. Verify BGP peering:
   - Run `show bgp summary` on each router to confirm all peers are established
   - Run `show ip route bgp` on each router to confirm route exchange

## How to Use the Boundary MCP Tools

### Finding targets
Use `list_targets` with the project scope ID. The targets are named `router-1-cli`, `router-2-cli`, `router-3-cli`.

### Connecting to a router CLI
The TCP CLI on each router requires a password first. Use `connect_tcp` with:
- `target_id`: the target ID from list_targets
- `command`: the password "fr12pass!" to authenticate to the CLI
- `read_timeout`: 3 seconds is enough for the password response

After authenticating, send actual vtysh commands using `connect_tcp` with the same target_id:
- `command`: the vtysh command (e.g., "show version", "show bgp summary")
- `read_timeout`: 5-10 seconds for command output

### Configuring a router
FRR vtysh configuration commands need to be sent as a sequence. Use `connect_tcp` for each command:
1. Send the password: `connect_tcp` with command="fr12pass!"
2. Enter config mode: `connect_tcp` with command="configure terminal"
3. Configure BGP: `connect_tcp` with command="router bgp 65001"
4. Add neighbors: `connect_tcp` with command="neighbor 10.100.2.1 remote-as 65002"
5. Add network: `connect_tcp` with command="network 10.1.1.1/32"
6. Exit and save: `connect_tcp` with command="end", then "write memory"

Note: Each `connect_tcp` call opens a new session to the CLI. The password must be sent first in each call that needs authenticated access. For multi-command sequences, include the password followed by a newline and the command in the command field.

### Verifying configuration
After configuring all 3 routers, wait 15-20 seconds for BGP convergence, then:
1. `connect_tcp` to each router with `show bgp summary`
2. `connect_tcp` to each router with `show ip route bgp`
3. Report the results

## Important Notes
- The router CLI is vtysh (FRR's CLI). Commands are similar to Cisco IOS.
- BGP neighbors use the direct interface IPs (10.100.X.1), not loopbacks.
- The `network` command in BGP requires the exact prefix from the routing table.
- After configuration, allow 15-20 seconds for BGP sessions to establish before running verification commands.
- If a command times out, try again with a longer read_timeout.
- Credentials are brokered automatically by Boundary - you don't need to handle passwords for the Boundary connection. The CLI password (fr12pass!) is for the vtysh CLI wrapper, not for Boundary.