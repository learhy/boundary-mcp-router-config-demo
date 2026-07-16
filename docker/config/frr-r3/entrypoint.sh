#!/bin/bash
set -e

# Generate SSH host keys if not present
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
  ssh-keygen -A 2>/dev/null || true
fi

# Start SSH daemon (for SSH target access)
/usr/sbin/sshd 2>/dev/null || true

# Start socat TCP CLI wrapper on port 2024 (for TCP target access)
# This pipes incoming TCP connections to vtysh with password auth
socat TCP-LISTEN:2024,reuseaddr,fork EXEC:/usr/local/bin/cli-wrapper.sh,pty,stderr &

# Start FRR daemons using the default FRR entrypoint
exec /usr/lib/frr/docker-start