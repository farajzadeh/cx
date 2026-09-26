# The laptop in the demo GIFs: VHS, plus what the cx client needs.
#
# cx runs here, against the throwaway sshd nodes that docs/demo/setup.sh
# starts, and VHS records the terminal it runs in. Everything is inside
# containers so recording needs Docker and nothing else — no vhs, ffmpeg or
# fzf on the machine doing the recording, and nothing of that machine's own
# ~/.ssh or ~/.config/cx anywhere near the pictures.
#
# The repository is bind-mounted at /cx at run time rather than copied in, so
# the GIFs always show the cx in the working tree without a rebuild.

FROM ghcr.io/charmbracelet/vhs

# fzf and bash-completion are the point of two of the GIFs. gifsicle squeezes
# the result: VHS writes GIFs that are several times larger than they need to
# be, and these are committed to the repository.
#
# gawk because Debian's default awk is mawk, which counts bytes rather than
# characters: cx's tables pad by awk's length(), and every row holding a ●
# came out two columns short.
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      bash bash-completion ca-certificates fzf gawk git gifsicle jq \
      openssh-client procps tmux && \
    rm -rf /var/lib/apt/lists/*

# A normal user named `demo`, with the recording machine's uid so the GIFs
# written to the bind-mounted output directory are owned by whoever ran
# record.sh rather than by root.
#
# A real account rather than root with HOME pointed elsewhere: OpenSSH reads
# ~/.ssh from the passwd database, not $HOME, and a prompt reading `root` in
# every GIF would be a strange thing to teach people.
ARG UID=1000
ARG GID=1000
RUN (getent group "$GID" >/dev/null || groupadd -g "$GID" demo) && \
    (getent passwd "$UID" >/dev/null && userdel -r "$(getent passwd "$UID" | cut -d: -f1)" || true) && \
    useradd -m -u "$UID" -g "$GID" -s /bin/bash demo && \
    mkdir -p /out && chown "$UID:$GID" /out

ENV CX_HOME=/cx \
    PATH=/cx/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    TERM=xterm-256color

USER demo
WORKDIR /home/demo
