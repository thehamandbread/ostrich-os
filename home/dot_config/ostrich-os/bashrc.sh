# ~/.config/ostrich-os/bashrc.sh: shell additions from Ostrich OS.
# Sourced from ~/.bashrc by a single line; your own ~/.bashrc stays yours.

case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) export PATH="$HOME/.local/bin:$PATH" ;;
esac

[[ -f $HOME/.cargo/env ]] && . "$HOME/.cargo/env"
command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"

# GPU switching on hybrid-graphics machines (log out to apply).
if command -v prime-select >/dev/null 2>&1; then
	alias gpu-nvidia='sudo prime-select nvidia && gnome-session-quit --logout --no-prompt'
	alias gpu-hybrid='sudo prime-select on-demand && gnome-session-quit --logout --no-prompt'
	alias gpu-intel='sudo prime-select intel && gnome-session-quit --logout --no-prompt'
	alias gpu-status='prime-select query'
fi
