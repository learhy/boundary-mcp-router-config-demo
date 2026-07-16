FROM frrouting/frr:latest
RUN apk add --no-cache socat openssh-server bash
RUN mkdir -p /run/sshd
# Create frr user with password
RUN adduser -D -s /bin/bash frruser
# TCP CLI wrapper script: exposes vtysh over TCP with password auth
COPY cli-wrapper.sh /usr/local/bin/cli-wrapper.sh
RUN chmod +x /usr/local/bin/cli-wrapper.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22 2024
ENTRYPOINT ["/entrypoint.sh"]
