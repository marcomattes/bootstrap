#!/usr/bin/env bash
set -euo pipefail

# ---------- Helpers ----------
echo_ok()   { echo -e '\033[1;32m'"$1"'\033[0m'; }
echo_warn() { echo -e '\033[1;33m'"$1"'\033[0m'; }
echo_error(){ echo -e '\033[1;31mERROR: '"$1"'\033[0m'; }
trap 'echo_error "Failed at line $LINENO"; exit 1' ERR

export HOMEBREW_CASK_OPTS="--appdir=/Applications"
export HOMEBREW_NO_ANALYTICS=1

# ---------- Xcode CLI Tools: install-and-wait ----------
ensure_xcode_clt() {
  if xcode-select -p &>/dev/null; then
    echo_ok "Xcode Command Line Tools already installed."
    return 0
  fi
  echo_warn "Xcode Command Line Tools missing. Starting installation..."
  xcode-select --install || true

  timeout_sec=900   # 15 minutes
  interval=5
  elapsed=0
  while true; do
    if xcode-select -p &>/dev/null; then
      devdir="$(xcode-select -p 2>/dev/null || true)"
      if [[ -n "${devdir:-}" && -d "/Library/Developer/CommandLineTools" ]]; then
        echo_ok "Xcode Command Line Tools installed: ${devdir}"
        break
      fi
    fi
    if pkgutil --pkg-info=com.apple.pkg.CLTools_Executables &>/dev/null; then
      echo_ok "Xcode CLT receipt found (pkgutil)."
      break
    fi
    if (( elapsed >= timeout_sec )); then
      echo_error "Timed out waiting for Xcode Command Line Tools. Please finish the installer and re-run."
      exit 1
    fi
    echo_warn "Waiting for CLT installation to complete... (${elapsed}s)"
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}
ensure_xcode_clt

# ---------- Homebrew (Apple Silicon) ----------
if ! command -v brew &>/dev/null; then
  echo_warn "Installing Homebrew (Apple Silicon)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"   # ensure brew in PATH

echo_ok "Homebrew present. Updating & health check..."
brew update
brew doctor || echo_warn "brew doctor reported notes."

install_brews() { brew install "$@" && brew upgrade "$@" || true; }
install_casks() { brew install --cask "$@" || true; }

# ---------- Packages ----------
PACKAGES=(
  curl
  git
  htop
  node
  openssl
  python
  ssh-copy-id
  tree
  wget
  zsh
  yadm
  # Dev toolchain
  gnupg pinentry-mac
  gh
)
echo_ok "Installing/upgrading brew packages..."
install_brews "${PACKAGES[@]}"
echo_ok "Cleaning up brew cache..."
brew cleanup -s || true

# Enable fzf keybindings and completion
"$(brew --prefix)/opt/fzf/install" --key-bindings --completion --no-update-rc 2>/dev/null || true

# ---------- Casks ----------
CASKS=(
  adobe-acrobat-reader
  alt-tab
  cakebrew
  clipy
  coteditor
  docker
  firefox
  google-chrome
  microsoft-edge
  iterm2
  microsoft-teams
  visual-studio-code
  vlc
  keepassxc           # KeePass added
)
echo_ok "Installing cask apps..."
install_casks "${CASKS[@]}"

# ---------- Nerd Fonts ----------
echo_ok "Installing Nerd Fonts..."
brew tap homebrew/cask-fonts || true
FONTS=(
  font-fira-code-nerd-font
  font-jetbrains-mono-nerd-font
  font-hack-nerd-font
)
install_casks "${FONTS[@]}"

# ---------- Oh My Zsh ----------
if [[ ! -f "$HOME/.zshrc" ]]; then
  echo_ok "Installing oh-my-zsh..."
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  cp "$HOME/.zshrc" "$HOME/.zshrc.orig" 2>/dev/null || true
  cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
fi

# ---------- Shell completions ----------
ZSH_COMPLETIONS_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"
mkdir -p "$ZSH_COMPLETIONS_DIR" "$HOME/.zfunc"

# Brew provides many completions under $(brew --prefix)/share
BREW_PREFIX="$(brew --prefix)"
{
  echo ''
  echo '# ----- Completions -----'
  echo "fpath+=($BREW_PREFIX/share/zsh/site-functions)"
  echo "autoload -Uz compinit && compinit -u"
  echo ''
  echo '# fzf keybindings (installed via brew fzf)'
  echo "[ -f $BREW_PREFIX/opt/fzf/shell/key-bindings.zsh ] && source $BREW_PREFIX/opt/fzf/shell/key-bindings.zsh"
  echo "[ -f $BREW_PREFIX/opt/fzf/shell/completion.zsh ] && source $BREW_PREFIX/opt/fzf/shell/completion.zsh"
  echo ''
  echo '# direnv'
  echo 'eval "$(direnv hook zsh)"'
  echo ''
  echo '# kubectl completion'
  echo 'autoload -Uz compinit'
  echo 'if command -v kubectl >/dev/null; then'
  echo '  source <(kubectl completion zsh)'
  echo 'fi'
  echo ''
  echo '# helm completion'
  echo 'if command -v helm >/dev/null; then'
  echo '  source <(helm completion zsh)'
  echo 'fi'
  echo ''
  echo '# gh completion'
  echo 'if command -v gh >/dev/null; then'
  echo '  eval "$(gh completion -s zsh)"'
  echo 'fi'
  echo ''
  echo '# terraform completion'
  echo 'if command -v terraform >/dev/null; then'
  echo '  complete -o nospace -C terraform terraform 2>/dev/null || true'
  echo 'fi'
} >> "$HOME/.zshrc"

# Prefer zsh as default shell
if [[ "$SHELL" != "/bin/zsh" ]]; then
  if command -v chsh &>/dev/null; then
    chsh -s /bin/zsh || echo_warn "Failed to set zsh as default shell."
  fi
fi

# ---------- Git Identity ----------
echo "##### Enter your Git full name:"
read -r git_name
echo "##### Enter your Git email:"
read -r git_email
[[ -z "${git_name}" || -z "${git_email}" ]] && { echo_error "Git name/email must not be empty"; exit 1; }

git config --global user.name "${git_name}"
git config --global user.email "${git_email}"
git config --global color.ui auto
git config --global push.default current
git config --global core.editor "${VISUAL:-${EDITOR:-nano}}"
git config --global credential.helper osxkeychain || true
git config --global init.defaultBranch main
git config --global gpg.program "$(brew --prefix)/bin/gpg" || true
git config --global commit.gpgsign false || true  # set true if you enforce signing

# ---------- SSH Key & Config ----------
if [[ ! -f "${HOME}/.ssh/id_ed25519" ]]; then
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  echo_ok "Generating ed25519 SSH key..."
  ssh-keygen -t ed25519 -C "${git_email}" -f "${HOME}/.ssh/id_ed25519" -N ""

  eval "$(ssh-agent -s)"
  if ssh-add --apple-use-keychain "${HOME}/.ssh/id_ed25519"; then
    :
  else
    ssh-add "${HOME}/.ssh/id_ed25519"
  fi

  pbcopy < "${HOME}/.ssh/id_ed25519.pub"
  echo_ok "SSH public key copied to clipboard. Add it to GitHub:"
  echo "https://github.com/settings/keys"
  echo "----- PUBLIC KEY -----"
  cat "${HOME}/.ssh/id_ed25519.pub"
  echo "----------------------"
fi

SSH_CFG="${HOME}/.ssh/config"
if [[ ! -f "$SSH_CFG" ]] || ! grep -qE '^Host[[:space:]]+github\.com' "$SSH_CFG"; then
  cat >> "$SSH_CFG" <<'EOF'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
EOF
  chmod 600 "$SSH_CFG"
fi

echo_ok "Git/SSH setup complete for ${git_name} <${git_email}>."

# ---------- VS Code Extensions ----------
if command -v code &>/dev/null; then
  echo_ok "Installing VS Code extensions..."
  VSCODE_EXTENSIONS=(
    EditorConfig.EditorConfig
    ms-python.python
    ms-azuretools.vscode-docker
    esbenp.prettier-vscode
    dbaeumer.vscode-eslint
    redhat.vscode-yaml
    github.vscode-pull-request-github
  )
  for ext in "${VSCODE_EXTENSIONS[@]}"; do
    code --install-extension "$ext" || echo_warn "VSCode extension $ext failed."
  done
fi

# ---------- Docker Desktop defaults ----------
# Make sure Docker Desktop is installed (cask above) before writing defaults; safe even if not yet launched
# Keys may evolve; these are sane defaults commonly used in teams.
echo_ok "Applying Docker Desktop defaults..."
# Send anonymous analytics off (if key exists)
defaults write com.docker.docker AnalyticsEnabled -bool false || true
# Auto-start at login
defaults write com.docker.docker autoStart -bool true || true
# Resource limits (example: 4 CPUs, 6 GB RAM, 1 GB swap) – adjust to your policy
defaults write com.docker.docker CPULimit -int 4 || true
defaults write com.docker.docker MemoryMiB -int 6144 || true
defaults write com.docker.docker SwapMiB -int 1024 || true
# Use Docker Compose V2
defaults write com.docker.docker UseDockerComposeV2 -bool true || true
# Enable Kubernetes off by default (toggle to true if you want it)
defaults write com.docker.docker KubernetesEnabled -bool false || true

# ---------- macOS Defaults ----------
echo_ok "Configuring macOS defaults..."

# Faster key repeat and shorter delay
defaults write NSGlobalDomain KeyRepeat -int 6
defaults write NSGlobalDomain InitialKeyRepeat -int 25

# Disable press-and-hold in favor of key repeat (requested)
defaults write -g ApplePressAndHoldEnabled -bool false

# Always show scrollbars
defaults write NSGlobalDomain AppleShowScrollBars -string "Always"

# Require password immediately after screensaver/sleep
defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0

# Show file extensions and hidden files in Finder
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults write com.apple.finder AppleShowAllFiles -bool true

# Expand Save/Open and Print dialogs
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true

# Tap-to-click; classic scroll direction
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false

# Disk Utility advanced
defaults write com.apple.DiskUtility advanced-image-options -int 1

# UI highlight color, icon size in lists, faster window animations
defaults write NSGlobalDomain AppleHighlightColor -string "0.764700 0.976500 0.568600"
defaults write NSGlobalDomain NSTableViewDefaultSizeMode -int 3
defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false

# Default to saving locally
defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false

# Screenshots folder and format
mkdir -p "${HOME}/Desktop/Screenshots"
defaults write com.apple.screencapture location -string "${HOME}/Desktop/Screenshots"
defaults write com.apple.screencapture type -string "png"

# Finder: allow quit, disable animations
defaults write com.apple.finder QuitMenuItem -bool true
defaults write com.apple.finder DisableAllAnimations -bool true

# Finder: default new window target = Desktop
defaults write com.apple.finder NewWindowTarget -string "PfDe"
defaults write com.apple.finder NewWindowTargetPath -string "file://${HOME}/Desktop/"

# Finder: desktop icon clutter off
defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool false
defaults write com.apple.finder ShowHardDrivesOnDesktop -bool false
defaults write com.apple.finder ShowMountedServersOnDesktop -bool false
defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool false

# Finder: status & path bar
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder ShowPathbar -bool true

# QuickLook text selection, POSIX path in title
defaults write com.apple.finder QLEnableTextSelection -bool true
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true

# Finder: search current folder
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"

# Finder: stop warning on extension change
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

# Finder: default view = Columns, sort by name, show item info on icons
defaults write com.apple.finder FXPreferredViewStyle -string "clmv"   # clmv=Column view
defaults write com.apple.finder FXArrangeGroupViewBy -string "Name"   # sort by Name in group views
defaults write com.apple.finder _FXSortFoldersFirst -bool true        # folders first in sorting
# Show item info near icons (for icon views)
defaults write com.apple.finder ShowItemInfo -bool true

# Spring-loading folders
defaults write NSGlobalDomain com.apple.springing.enabled -bool true
defaults write NSGlobalDomain com.apple.springing.delay -float 0

# Avoid .DS_Store on network shares
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true

# Disk image handling
defaults write com.apple.frameworks.diskimages skip-verify -bool true
defaults write com.apple.frameworks.diskimages skip-verify-locked -bool true
defaults write com.apple.frameworks.diskimages skip-verify-remote -bool true
defaults write com.apple.frameworks.diskimages auto-open-ro-root -bool true
defaults write com.apple.frameworks.diskimages auto-open-rw-root -bool true
defaults write com.apple.finder OpenWindowForNewRemovableDisk -bool true

# Dock cleanup: autohide, size, minimize effect
defaults write com.apple.dock autohide -bool true            # auto-hide Dock
defaults write com.apple.dock tilesize -int 48               # Dock icon size (pixels)
defaults write com.apple.dock mineffect -string "scale"      # minimize effect: 'scale' or 'genie'
defaults write com.apple.dock show-recents -bool false       # hide recent apps

# Hot Corners (tl=0, tr=2, bl=3, br=4 examples)
# 0: no-op, 2: Mission Control, 3: Show Application Windows, 4: Desktop, 5: Start screen saver, 6: Disable screen saver, 10: Put display to sleep
# Configure: top-left -> Mission Control, top-right -> Desktop, bottom-left -> Start screensaver, bottom-right -> Show Application Windows
defaults write com.apple.dock wvous-tl-corner -int 2; defaults write com.apple.dock wvous-tl-modifier -int 0
defaults write com.apple.dock wvous-tr-corner -int 4; defaults write com.apple.dock wvous-tr-modifier -int 0
defaults write com.apple.dock wvous-bl-corner -int 5; defaults write com.apple.dock wvous-bl-modifier -int 0
defaults write com.apple.dock wvous-br-corner -int 3; defaults write com.apple.dock wvous-br-modifier -int 0

# Show ~/Library
chflags nohidden "$HOME/Library" || true

# Expand “Get Info” panes: General, Open with, Sharing & Permissions
defaults write com.apple.finder FXInfoPanesExpanded -dict \
  General -bool true \
  OpenWith -bool true \
  Privileges -bool true

# Apply UI changes
killall Finder 2>/dev/null || true
killall Dock 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

# ---------- System-wide (sudo) ----------
if sudo -n true 2>/dev/null; then
  defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true || true
  sudo defaults write /Library/Preferences/com.apple.loginwindow AdminHostInfo HostName || true
  sudo systemsetup -setrestartfreeze on || echo_warn "systemsetup unavailable."
else
  echo_warn "No sudo without password. Skipping system-wide settings."
fi

# ---------- Software Update ----------
if sudo -n true 2>/dev/null; then
  echo_ok "Running macOS Software Updates..."
  sudo softwareupdate -ia || echo_warn "softwareupdate failed/was interrupted."
fi

# ---------- Folders ----------
echo_ok "Creating folder structure..."
mkdir -p "$HOME/development"

echo_ok "Bootstrapping complete"
