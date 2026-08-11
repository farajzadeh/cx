# A disposable SSH server standing in for a real cx target.
#
# Deliberately close to a real server and deliberately not identical: it runs
# sshd as a normal user with passwordless sudo, so provisioning exercises the
# package-install path the way a fresh VM would.

ARG BASE=ubuntu:24.04
FROM ${BASE}

# openssh-server only. tmux, git, jq and curl are intentionally absent so that
# `cx provision` has real work to do — installing them is the thing under test.
RUN if command -v apt-get >/dev/null 2>&1; then \
      apt-get update -qq && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server sudo && \
      rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null 2>&1; then \
      apk add --no-cache openssh-server sudo bash; \
    fi && \
    mkdir -p /run/sshd /var/run/sshd

# An unprivileged account with passwordless sudo, matching how most people
# actually reach their servers.
RUN (getent group cxuser || groupadd cxuser) && \
    (id cxuser 2>/dev/null || useradd -m -s /bin/bash -g cxuser cxuser) && \
    printf 'cxuser ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/cxuser && \
    chmod 440 /etc/sudoers.d/cxuser

# A stub Claude Code, installed at ~/.local/bin — the same place the real
# installer puts it, and DELIBERATELY not somewhere on the default PATH.
#
# An earlier version of this image put the stub in /usr/local/bin, which is on
# the default PATH. That masked a real bug: cx invokes the agent over a
# non-interactive ssh command, which reads neither ~/.bashrc nor ~/.profile,
# so ~/.local/bin is absent and `command -v claude` fails on a server where
# Claude Code is installed and signed in. Keeping the stub here means every
# test exercises the realistic layout.
RUN printf '%s\n' \
    '#!/bin/sh' \
    '# Stub claude for cx integration tests.' \
    'case "${1:-}" in' \
    '  --version) echo "9.9.9 (Claude Code stub)" ;;' \
    '  -p|--print) shift; echo "STUB_ANSWER: $*" ;;' \
    '  --continue) echo "STUB: continuing session in $(pwd)" ;;' \
    '  --resume)   echo "STUB: resume picker in $(pwd)" ;;' \
    '  *)          echo "STUB: interactive claude in $(pwd)" ;;' \
    'esac' \
    > /tmp/claude-stub && chmod 755 /tmp/claude-stub

# Entrypoint installs the test public key with the ownership and permissions
# sshd insists on — a bind-mounted authorized_keys would carry host uid/gid
# and be rejected.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'set -e' \
    'mkdir -p /home/cxuser/.ssh /home/cxuser/.local/bin' \
    'cp /tmp/claude-stub /home/cxuser/.local/bin/claude' \
    'chmod 755 /home/cxuser/.local/bin/claude' \
    'chown -R cxuser:cxuser /home/cxuser/.local' \
    'if [ -f /pubkey/authorized_keys ]; then' \
    '  cp /pubkey/authorized_keys /home/cxuser/.ssh/authorized_keys' \
    'fi' \
    'chown -R cxuser:cxuser /home/cxuser/.ssh' \
    'chmod 700 /home/cxuser/.ssh' \
    'chmod 600 /home/cxuser/.ssh/authorized_keys 2>/dev/null || true' \
    'ssh-keygen -A >/dev/null 2>&1 || true' \
    'exec /usr/sbin/sshd -D -e' \
    > /entrypoint.sh && chmod 755 /entrypoint.sh

EXPOSE 22
CMD ["/entrypoint.sh"]
