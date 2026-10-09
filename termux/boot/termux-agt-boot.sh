#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot entry for Termux-AGT — starts the worker supervisor when the
# phone boots.
#
# Installed to ~/.termux/boot/termux-agt.sh by termux/setup-termux.sh.
# Requires the Termux:Boot app (F-Droid). Runs with a minimal environment;
# PATH and HOME are set explicitly because boot-time env is sparse.
export HOME="/data/data/com.termux/files/home"
export PREFIX="/data/data/com.termux/files/usr"
export PATH="$PREFIX/bin:$PATH"

SUP="$HOME/agent-host/supervisor/termux-supervisor.sh"
LOG="$HOME/agent-host/logs/supervisor.log"

[ -x "$SUP" ] || exit 0
mkdir -p "$HOME/agent-host/logs"
# Detach fully: the boot context must not wait on us.
nohup bash "$SUP" >>"$LOG" 2>&1 &
