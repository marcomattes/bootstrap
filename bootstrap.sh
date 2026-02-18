#!/usr/bin/env bash
set -euo pipefail

# ---------- Helpers ----------
echo_ok()   { echo -e '\033[1;32m'"$1"'\033[0m'; }
echo_warn() { echo -e '\033[1;33m'"$1"'\033[0m'; }
echo_error(){ echo -e '\033[1;31mERROR: '"$1"'\033[0m'; }
trap 'echo_error "Failed at line $LINENO"; exit 1' ERR

export HOMEBREW_CASK_OPTS="--appdir=/Applications"
export HOMEBREW_NO_ANALYTICS=1

# ---------- Sudo bootstrap (ask once, keep alive) ----------
if ! sudo -v; then
  echo_error "Sudo required to apply system-wide settings."
  exit 1
fi
( while true; do sudo -n true; sleep 60; kill -0 "$" || exit; done ) 2>/dev/null &

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
      echo_error "Timed out waiting for Xcode Command Line Tools."
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
# runtime PATH
eval "$(/opt/homebrew/bin/brew shellenv)"
# persistent PATH for future shells
if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
fi

echo_ok "Homebrew present. Updating & health check..."
brew update
brew doctor || echo_warn "brew doctor reported notes."

install_brews() { brew install "$@" && brew upgrade "$@" || true; }
install_casks() { brew install --cask "$@" || true; }

# ---------- Packages ----------
PACKAGES=(
  # basics
  curl git htop node openssl python ssh-copy-id tree wget zsh yadm
  # cli tooling
  jq yq ripgrep fd bat fzf direnv
  gnupg pinentry-mac
  gh
  # k8s & IaC
  kubectl kubectx k9s helm
  terraform tflint
)
echo_ok "Installing/upgrading brew packages..."
install_brews "${PACKAGES[@]}"
echo_ok "Cleaning up brew cache..."
brew cleanup -s || true

# fzf keybindings/completion
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
  keepassxc
)
echo_ok "Installing cask apps..."
install_casks "${CASKS[@]}"

# ---------- Nerd Fonts (no deprecated tap) ----------
echo_ok "Installing Nerd Fonts..."
NERD_FONTS=(
  font-fira-code-nerd-font
  font-jetbrains-mono-nerd-font
  font-hack-nerd-font
)
install_casks "${NERD_FONTS[@]}"

# ---------- Oh My Zsh ----------
if [[ ! -f "$HOME/.zshrc" ]]; then
  echo_ok "Installing oh-my-zsh..."
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  cp "$HOME/.zshrc" "$HOME/.zshrc.orig" 2>/dev/null || true
  cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
fi

# ---------- Shell completions ----------
BREW_PREFIX="$(brew --prefix)"
{
  echo ''
  echo '# ----- Completions & bindings -----'
  echo "fpath+=($BREW_PREFIX/share/zsh/site-functions)"
  echo "autoload -Uz compinit && compinit -u"
  echo "[ -f $BREW_PREFIX/opt/fzf/shell/key-bindings.zsh ] && source $BREW_PREFIX/opt/fzf/shell/key-bindings.zsh"
  echo "[ -f $BREW_PREFIX/opt/fzf/shell/completion.zsh ] && source $BREW_PREFIX/opt/fzf/shell/completion.zsh"
  echo 'eval "$(direnv hook zsh)"'
  echo 'if command -v kubectl >/dev/null; then source <(kubectl completion zsh); fi'
  echo 'if command -v helm >/dev/null; then source <(helm completion zsh); fi'
  echo 'if command -v gh >/dev/null; then eval "$(gh completion -s zsh)"; fi'
  echo 'if command -v terraform >/dev/null; then complete -o nospace -C terraform terraform 2>/dev/null || true; fi'
} >> "$HOME/.zshrc"

# Ensure default shell
if [[ "$SHELL" != "/bin/zsh" ]]; then
  chsh -s /bin/zsh || echo_warn "Failed to set zsh as default shell."
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
git config --global commit.gpgsign false || true

# ---------- SSH Key & Config ----------
if [[ ! -f "${HOME}/.ssh/id_ed25519" ]]; then
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  echo_ok "Generating ed25519 SSH key..."
  ssh-keygen -t ed25519 -C "${git_email}" -f "${HOME}/.ssh/id_ed25519" -N ""
  eval "$(ssh-agent -s)"
  ssh-add --apple-use-keychain "${HOME}/.ssh/id_ed25519" || ssh-add "${HOME}/.ssh/id_ed25519"
  pbcopy < "${HOME}/.ssh/id_ed25519.pub"
  echo_ok "SSH public key copied to clipboard. Add it to GitHub: https://github.com/settings/keys"
  cat "${HOME}/.ssh/id_ed25519.pub"
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
echo_ok "Applying Docker Desktop defaults..."
# analytics off, autostart on
defaults write com.docker.docker AnalyticsEnabled -bool false || true
defaults write com.docker.docker autoStart -bool true || true
# resources (adjust to policy)
defaults write com.docker.docker CPULimit -int 4 || true
defaults write com.docker.docker MemoryMiB -int 6144 || true
defaults write com.docker.docker SwapMiB -int 1024 || true
# compose v2, k8s off by default
defaults write com.docker.docker UseDockerComposeV2 -bool true || true
defaults write com.docker.docker KubernetesEnabled -bool false || true

# ---------- macOS Defaults ----------
echo_ok "Configuring macOS defaults..."

# Keyboard repeat
defaults write NSGlobalDomain KeyRepeat -int 6
defaults write NSGlobalDomain InitialKeyRepeat -int 25
# Prefer key repeat over press-and-hold
defaults write -g ApplePressAndHoldEnabled -bool false

# Scrollbars always visible
defaults write NSGlobalDomain AppleShowScrollBars -string "Always"

# Require password after sleep/screensaver
defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0

# Show extensions and hidden files
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults write com.apple.finder AppleShowAllFiles -bool true

# Expand Save/Open and Print dialogs
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true

# Trackpad tap-to-click; classic scroll
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
defaults write NSGlobalDomain com.apple.swipescrolldirection -bool false

# Disk Utility advanced
defaults write com.apple.DiskUtility advanced-image-options -int 1

# UI tweaks
defaults write NSGlobalDomain AppleHighlightColor -string "0.764700 0.976500 0.568600"
defaults write NSGlobalDomain NSTableViewDefaultSizeMode -int 3
defaults write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false

# Screenshots
mkdir -p "${HOME}/Desktop/Screenshots"
defaults write com.apple.screencapture location -string "${HOME}/Desktop/Screenshots"
defaults write com.apple.screencapture type -string "png"

# Finder basics
defaults write com.apple.finder QuitMenuItem -bool true
defaults write com.apple.finder DisableAllAnimations -bool true
defaults write com.apple.finder NewWindowTarget -string "PfDe"
defaults write com.apple.finder NewWindowTargetPath -string "file://${HOME}/Desktop/"
defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool false
defaults write com.apple.finder ShowHardDrivesOnDesktop -bool false
defaults write com.apple.finder ShowMountedServersOnDesktop -bool false
defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool false
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder QLEnableTextSelection -bool true
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false

# Finder: default view Columns, sort by name, show item info
defaults write com.apple.finder FXPreferredViewStyle -string "clmv"
defaults write com.apple.finder FXArrangeGroupViewBy -string "Name"
defaults write com.apple.finder _FXSortFoldersFirst -bool true
defaults write com.apple.finder ShowItemInfo -bool true

# Spring-loading folders
defaults write NSGlobalDomain com.apple.springing.enabled -bool true
defaults write NSGlobalDomain com.apple.springing.delay -float 0

# .DS_Store off on network shares
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true

# Disk images
defaults write com.apple.frameworks.diskimages skip-verify -bool true
defaults write com.apple.frameworks.diskimages skip-verify-locked -bool true
defaults write com.apple.frameworks.diskimages skip-verify-remote -bool true
defaults write com.apple.frameworks.diskimages auto-open-ro-root -bool true
defaults write com.apple.frameworks.diskimages auto-open-rw-root -bool true
defaults write com.apple.finder OpenWindowForNewRemovableDisk -bool true

# Dock cleanup + Hot Corners
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock tilesize -int 48
defaults write com.apple.dock mineffect -string "scale"
defaults write com.apple.dock show-recents -bool false
# Hot Corners:
# TL=Mission Control(2), TR=Desktop(4), BL=Start screensaver(5), BR=App Windows(3)
defaults write com.apple.dock wvous-tl-corner -int 2; defaults write com.apple.dock wvous-tl-modifier -int 0
defaults write com.apple.dock wvous-tr-corner -int 4; defaults write com.apple.dock wvous-tr-modifier -int 0
defaults write com.apple.dock wvous-bl-corner -int 5; defaults write com.apple.dock wvous-bl-modifier -int 0
defaults write com.apple.dock wvous-br-corner -int 3; defaults write com.apple.dock wvous-br-modifier -int 0

# Show ~/Library
chflags nohidden "$HOME/Library" || true

# Expand Get Info panes
defaults write com.apple.finder FXInfoPanesExpanded -dict \
  General -bool true \
  OpenWith -bool true \
  Privileges -bool true

# Apply UI changes
killall Finder 2>/dev/null || true
killall Dock 2>/dev/null || true
killall SystemUIServer 2>/dev/null || true

# ---------- System-wide ----------
# Software Update preferences and loginwindow host info
defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true || true
sudo defaults write /Library/Preferences/com.apple.loginwindow AdminHostInfo HostName || true
sudo systemsetup -setrestartfreeze on || echo_warn "systemsetup unavailable."

# ---------- Software Update ----------
echo_ok "Running macOS Software Updates..."
sudo softwareupdate -ia || echo_warn "softwareupdate failed/was interrupted."

# ---------- Folders ----------
echo_ok "Creating folder structure..."
mkdir -p "$HOME/development"

echo_ok "Bootstrapping complete"
