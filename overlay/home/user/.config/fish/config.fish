# =============================================================================
# ghOSt Fish Shell Configuration
# Modern terminal experience — colors, autocomplete, smart tools
# =============================================================================

# --- PATH ---
fish_add_path /usr/local/bin /opt/go/bin /opt/ghost/bin ~/.local/bin

# --- ENVIRONMENT ---
set -gx EDITOR micro
set -gx VISUAL micro
set -gx PAGER "bat --style=plain"
set -gx MANPAGER "sh -c 'col -bx | bat -l man -p'"
set -gx BAT_THEME "Catppuccin-mocha"
set -gx FZF_DEFAULT_OPTS "--color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 \
    --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc \
    --color=marker:#f5e0dc,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8"
set -gx RIPGREP_CONFIG_PATH ~/.config/ripgrep/config
set -gx GOPATH /opt/go
set -gx PYTHONDONTWRITEBYTECODE 1

# --- ALIASES: Modern replacements ---
alias ls='eza --icons --git --color=always --group-directories-first'
alias ll='eza --icons --git --color=always -la --group-directories-first'
alias lt='eza --icons --git --color=always --tree --level=2'
alias cat='bat --style=numbers,changes'
alias grep='rg --color=always'
alias diff='delta'
alias find='fd'
alias du='duf'
alias top='btop'
alias vim='micro'
alias nano='micro'

# --- ALIASES: Navigation ---
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'

# --- ALIASES: System ---
alias sysinfo='inxi -Fxz'
alias ports='ss -tulpn'
alias listening='ss -tlnp'
alias myip='curl -s ifconfig.me && echo'
alias localip='ip route get 1 | awk "{print \$7}" | head -1'
alias wifi='nmtui'
alias bt='bluetuith'
alias disk='duf'
alias mem='free -h'
alias cpu='cat /proc/cpuinfo | grep "model name" | head -1'
alias temp='cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | awk "{print \$1/1000}°C"'
alias bat='upower -i /org/freedesktop/UPower/devices/battery_axp20x_battery 2>/dev/null | grep -E "percentage|state|time"'

# --- ALIASES: ghOSt specific ---
alias intercept='open http://localhost:5050'
alias chef='open http://localhost:8000'
alias recon='cd /opt/ghost && ls'
alias wordlists='ls /opt/wordlists/'
alias tools='ls /opt/ghost/'
alias open='netsurf-gtk'

# --- ALIASES: Security tools ---
alias scan='nmap -sV -sC'
alias fastscan='rustscan -a'
alias sniff='termshark -i'
alias mitm='mitmproxy'
alias fuzz='ffuf'

# --- ALIASES: Git ---
alias g='git'
alias gs='git status'
alias ga='git add -A'
alias gc='git commit -m'
alias gp='git push'
alias gl='git log --oneline --graph --decorate'
alias gd='git diff'

# --- FUNCTIONS ---

# Quick port scan
function qs
    nmap -T4 -F $argv
end

# Show all open ports on a host
function openports
    nmap -p- --open -T4 $argv
end

# VNC over SSH tunnel
function vnc
    set host $argv[1]
    ssh -L 5901:localhost:5901 -N $host &
    sleep 2
    tigervnc-viewer localhost:5901
end

# Quick Python HTTP server
function serve
    set port (test -n "$argv[1]"; and echo $argv[1]; or echo 8080)
    echo "Serving on http://localhost:$port"
    python3 -m http.server $port
end

# Decrypt + view a file with age
function age-view
    age -d $argv[1] | bat
end

# Check if a domain/IP is up
function check
    for host in $argv
        if ping -c1 -W1 $host &>/dev/null
            echo "✓ $host is up"
        else
            echo "✗ $host is down"
        end
    end
end

# Show weather (using wttr.in in w3m)
function weather
    set loc (test -n "$argv[1]"; and echo $argv[1]; or echo "")
    curl -s "wttr.in/$loc?format=3"
end

# Extract any archive
function extract
    switch $argv[1]
        case '*.tar.bz2'; tar xjf $argv[1]
        case '*.tar.gz';  tar xzf $argv[1]
        case '*.tar.xz';  tar xJf $argv[1]
        case '*.tar.zst'; tar --zstd -xf $argv[1]
        case '*.bz2';     bunzip2 $argv[1]
        case '*.gz';      gunzip $argv[1]
        case '*.tar';     tar xf $argv[1]
        case '*.tbz2';    tar xjf $argv[1]
        case '*.tgz';     tar xzf $argv[1]
        case '*.zip';     unzip $argv[1]
        case '*.7z';      7z x $argv[1]
        case '*.rar';     unrar x $argv[1]
        case '*';         echo "'$argv[1]' cannot be extracted"
    end
end

# --- INTEGRATIONS ---

# zoxide (smart cd)
zoxide init fish | source

# atuin (shell history)
atuin init fish | source

# thefuck
thefuck --alias | source

# carapace completions
carapace _carapace | source

# fzf key bindings
fzf --fish | source

# --- GREETING ---
function fish_greeting
    # Show ghOSt status summary on new terminal
    set battery_info (upower -i /org/freedesktop/UPower/devices/battery_axp20x_battery 2>/dev/null | grep percentage | awk '{print $2}')
    set ip_info (ip route get 1 2>/dev/null | awk '{print $7}' | head -1)
    set uptime_info (uptime -p | sed 's/up //')

    echo ""
    echo -s (set_color brblue) "  ghOSt " (set_color brblack) "│ " \
         (set_color green) "🔋 $battery_info" (set_color brblack) " │ " \
         (set_color yellow) "🌐 $ip_info" (set_color brblack) " │ " \
         (set_color cyan) "⏱ $uptime_info" (set_color normal)
    echo ""
end
