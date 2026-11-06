import Foundation

/// The worker install script `GET /install` serves, with the server's address baked in.
///
/// The worker runs as whoever runs the script, the Mac's owner, as a launch agent in their login session. Its launchd
/// plist is embedded in the script (a heredoc) rather than served
/// separately: one download fewer, and nothing on the server to keep in sync with it.
enum InstallScript {
    static let originPlaceholder = "__HANGAR_ORIGIN__"

    /// `http://<host>[:<port>]` for a request's Host, nil when the host is not a plain DNS name or IP address or the
    /// port is out of range. Only these characters reach the script, so the origin needs no shell quoting beyond
    /// the single quotes around it.
    static func origin(authority: String) -> String? {
        guard let (host, port) = HostName.split(authority), !host.isEmpty else { return nil }
        if let port, !(1...65535).contains(port) { return nil }
        let renderedHost: String
        if host.contains(":") {
            guard host.wholeMatch(of: /[0-9a-f:.]+/) != nil else { return nil }
            renderedHost = "[\(host)]"
        } else {
            guard host.wholeMatch(of: /[a-z0-9]([a-z0-9.-]*[a-z0-9])?/) != nil else { return nil }
            renderedHost = host
        }
        return "http://\(renderedHost)" + (port.map { ":\($0)" } ?? "")
    }

    static let sha256Placeholder = "__HANGAR_WORKER_SHA256__"

    /// The script for `origin`, which must come from `origin(authority:)`. `workerSHA256` is the hex SHA-256 of the
    /// binary `GET /install/hangar-worker` serves; the script refuses a download that does not match it. Nil (no
    /// binary to hash) leaves the check out; the download then fails on its own with 503.
    static func render(origin: String, workerSHA256: String? = nil) -> String {
        let digest = workerSHA256.flatMap { $0.wholeMatch(of: /[0-9a-f]{64}/) != nil ? $0 : nil } ?? ""
        return template.replacingOccurrences(of: originPlaceholder, with: origin)
            .replacingOccurrences(of: sha256Placeholder, with: digest)
    }

    static let template = #"""
        #!/bin/sh
        # Installs the Hangar worker on this Mac and enrolls it with the Hangar server at __HANGAR_ORIGIN__,
        # which serves this script:
        #
        #   curl -fsSL __HANGAR_ORIGIN__/install | sh
        #
        # Run it in Terminal on the Mac, as the user whose login session the worker should run in. It checks this Mac
        # first (Apple silicon, Xcode, free space, Tailscale), downloads hangar-worker into ~/.local/bin, asks for the
        # pairing code shown in Hangar under Machines > Add Mac, enrolls this Mac and starts the worker as your launch
        # agent. No checkout, no Swift build.
        #
        # A Mac builds in one of two ways, asked once for a new Mac on Apple silicon:
        #   VM     a fresh macOS VM per build, which cannot see this Mac (the default). The Mac is enrolled with its
        #          builds paused, and the script then runs `sudo hangar-worker vm setup`, which sets up VM builds in
        #          about 15 minutes; it resumes nothing itself: resume builds on the Mac's card once it says VM builds
        #          are ready. Setting them up needs an administrator.
        #   local  directly on this Mac, as you, signing with your login keychain: a build can read your files.
        # An Intel Mac builds locally.
        #
        # Run it again to update: when this Mac is already enrolled with this server (`hangar-worker check`), it
        # replaces the binary and restarts the agent without asking for a code.
        #
        # Settings, all optional, as environment variables (put them after the pipe: ... | HANGAR_MAX_JOBS=2 sh):
        #   HANGAR_VM             1 builds in VMs, 0 builds locally (enrolled with builds on, no VM setup); asked when
        #                         unset, and VMs without a terminal to ask on
        #   HANGAR_VM_SETUP       1 runs `vm setup` without asking, 0 skips it (it prints the command); asked when unset
        #   HANGAR_PAIRING_CODE   the pairing code; asked for on the terminal when unset
        #   HANGAR_MACHINE_NAME   how this Mac appears in Hangar (default: its local host name)
        #   HANGAR_BIN_DIR        where hangar-worker goes (default: ~/.local/bin; must be writable by you)
        #   HANGAR_MAX_JOBS       builds this Mac runs at once, 1 to 99 (default: 1)
        #   HANGAR_WORKER_CONFIG  the worker configuration file (default: hangar-worker's own,
        #                         ~/Library/Application Support/Hangar/worker/config.json)
        #   HANGAR_NO_LAUNCHD=1   for testing: download, enroll and write the configuration, but neither write nor
        #                         load the launchd agent, and skip the doctor
        #
        # The machine token never appears in a command line or in the output: it goes from the server's answer to
        # `hangar-worker setup` in the environment.
        set -eu

        HANGAR_SERVER='__HANGAR_ORIGIN__'
        # SHA-256 of the hangar-worker the server hands out, as of this script; empty when it had none to hash.
        HANGAR_WORKER_SHA256='__HANGAR_WORKER_SHA256__'
        LABEL='app.hangar.worker'

        say() { printf '%s\n' "$*"; }
        warn() { printf 'warning: %s\n' "$*" >&2; }
        die() { printf 'error: %s\n' "$*" >&2; exit 1; }

        # Escapes a value for use as XML text.
        xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

        # Escapes a value for use in a JSON string; control characters are refused before.
        json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

        # Prints the value at a key path of the JSON on stdin (an array prints its count); nothing when absent.
        json_value() { /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null || true; }

        # Makes a path absolute, expanding a leading ~.
        absolute() {
            case $1 in
                "~") set -- "$HOME" ;;
                "~/"*) set -- "$HOME/${1#"~/"}" ;;
            esac
            case $1 in /*) printf '%s' "$1" ;; *) printf '%s' "$PWD/$1" ;; esac
        }

        # Succeeds when the file's SHA-256 is the expected hex digest, or when there is no digest to compare with.
        # verify_sha256 <file> <expected hex>
        verify_sha256() {
            [ -n "$2" ] || return 0
            actual=$(/usr/bin/shasum -a 256 "$1" 2>/dev/null | cut -d ' ' -f 1) || return 1
            [ "$actual" = "$2" ]
        }

        # Writes the launchd agent and (re)loads it. ExitTimeOut (two minutes; launchd's default is 20 s) lets a stopping
        # worker cancel its jobs and report their results before launchd's SIGKILL.
        install_agent() {
            plist="$HOME/Library/LaunchAgents/$LABEL.plist"
            logs="$HOME/Library/Logs/Hangar"
            mkdir -p "$logs" "$HOME/Library/LaunchAgents"
            config_arguments=''
            if [ -n "$config" ]; then
                config_arguments="
                <string>--config</string>
                <string>$(xml_escape "$config")</string>"
            fi
            cat >"$plist" <<EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>$LABEL</string>
            <key>ProgramArguments</key>
            <array>
                <string>$(xml_escape "$worker")</string>
                <string>run</string>$config_arguments
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ExitTimeOut</key>
            <integer>120</integer>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
            <key>ProcessType</key>
            <string>Standard</string>
            <key>StandardOutPath</key>
            <string>$(xml_escape "$logs")/worker.log</string>
            <key>StandardErrorPath</key>
            <string>$(xml_escape "$logs")/worker.log</string>
        </dict>
        </plist>
        EOF
            plutil -lint "$plist" >/dev/null || die "The launchd agent $plist is not a valid plist."

            domain="gui/$(id -u)"
            launchctl bootout "$domain/$LABEL" 2>/dev/null || true
            # bootout can return before the job is gone; wait up to 10 s so bootstrap does not fail with an I/O error.
            waited=0
            while [ "$waited" -lt 20 ] && launchctl print "$domain/$LABEL" >/dev/null 2>&1; do
                sleep 0.5
                waited=$((waited + 1))
            done
            # Retry a few times in case the unload is still finishing.
            attempt=1
            until launchctl bootstrap "$domain" "$plist"; do
                [ "$attempt" -lt 5 ] || die "launchctl bootstrap failed. The agent runs in the GUI session: log in to this Mac's desktop as this user and run the command again."
                attempt=$((attempt + 1))
                sleep 1
            done
            say "Started the $LABEL launchd agent. Log: $logs/worker.log"
        }

        # Runs the doctor and prints the Xcode versions and whether this Mac can sign without a prompt.
        summary() {
            say "Checking this Mac (hangar-worker doctor)..."
            if ! report=$("$worker" doctor 2>/dev/null); then
                warn "hangar-worker doctor failed; run it yourself to see why."
                return 0
            fi
            count=$(printf '%s' "$report" | json_value xcodes)
            case $count in '' | *[!0-9]*) count=0 ;; esac
            versions=''
            index=0
            while [ "$index" -lt "$count" ]; do
                version=$(printf '%s' "$report" | json_value "xcodes.$index.version")
                versions="${versions:+$versions, }$version"
                index=$((index + 1))
            done
            say "  Xcode: ${versions:-none found}"
            if [ -n "$(printf '%s' "$report" | json_value vm.configuredSlots)" ] || vm_planned; then
                say "  Builds: in VMs (they sign with Hangar's certificate, Settings > Signing)"
            elif [ "$(printf '%s' "$report" | json_value canSignWithoutPrompt)" = true ]; then
                say "  Can sign without a prompt: yes"
            else
                say "  Can sign without a prompt: not yet. Normal on a new Mac: the first archive creates the signing"
                say "  identity; then allow codesign in Keychain Access (see docs/worker-setup.md in Hangar)."
            fi
        }

        # Downloads hangar-worker to <path>: next to its final place, then renamed over it, so a running worker keeps
        # its own copy until it restarts.
        download_worker() {
            target=$1
            download="$(dirname "$target")/.hangar-worker.download.$$"
            say "Downloading hangar-worker..."
            status=$(curl -sS -o "$download" -w '%{http_code}' "$HANGAR_SERVER/install/hangar-worker") \
                || die "Cannot reach $HANGAR_SERVER. Check that this Mac is on the tailnet."
            case $status in
                200) ;;
                503) die "The server has no hangar-worker to hand out. Reinstall the server with the latest scripts/server/install-server.sh, then run this again." ;;
                *) die "Downloading hangar-worker failed: HTTP $status." ;;
            esac
            # The script and the binary come from the same server; a binary that differs from the one the server
            # described (cut off, altered on the way, or replaced since) is never run.
            verify_sha256 "$download" "$HANGAR_WORKER_SHA256" \
                || die "The downloaded hangar-worker is not the one the server announced (SHA-256 mismatch). Run this again; if it keeps failing, reinstall the server."
            chmod 755 "$download"
            xattr -d com.apple.quarantine "$download" 2>/dev/null || true
            "$download" --help >/dev/null 2>&1 \
                || die "The downloaded hangar-worker does not run on this Mac ($(uname -m)); the server may have a build for another architecture."
            mv -f "$download" "$target"
        }

        # Asks for the pairing code, enrolls this Mac and writes the configuration with `hangar-worker setup`.
        # enroll [setup arguments...]
        enroll() {
            # The pairing code. The script itself arrives on stdin, so the code is read from the terminal.
            code=${HANGAR_PAIRING_CODE:-}
            if [ -z "$code" ]; then
                (: </dev/tty) 2>/dev/null || die "No terminal to ask for the pairing code. Set HANGAR_PAIRING_CODE."
                printf 'Pairing code (from Hangar → Machines → Add Mac): ' >/dev/tty
                IFS= read -r code </dev/tty || [ -n "$code" ] || die "No pairing code entered."
            fi
            code=$(printf '%s' "$code" | tr -d ' \t-' | tr '[:lower:]' '[:upper:]')
            case $code in
                '' | *[!A-Z0-9]*) die "That is not a pairing code. It looks like ABCD-EFGH: 8 letters and digits." ;;
            esac

            # Enroll. The body goes on stdin and the answer, which holds the token, stays in this shell.
            say "Enrolling $name..."
            # A Mac meant for VM builds takes none until they are ready: it is enrolled paused, never building on the host.
            paused=false
            ! vm_planned || paused=true
            body=$(printf '{"code":"%s","name":"%s","maxConcurrentJobs":%s,"paused":%s}' "$code" "$(json_escape "$name")" "$max_jobs" "$paused")
            response=$(printf '%s' "$body" | curl -sS -X POST -H 'Content-Type: application/json' \
                --data-binary @- -w '\n%{http_code}' "$HANGAR_SERVER/api/v1/enroll") \
                || die "Cannot reach $HANGAR_SERVER. Check that this Mac is on the tailnet."
            status=$(printf '%s\n' "$response" | tail -n 1)
            answer=$(printf '%s\n' "$response" | sed '$d')
            unset response
            case $status in
                201) ;;
                409) die "Hangar already has a machine named \"$name\". The code is still valid; run this again with another name, e.g.: curl -fsSL $HANGAR_SERVER/install | HANGAR_MACHINE_NAME=mini-2 sh" ;;
                403) die "The pairing code was not accepted: mistyped, already used or expired (codes last 15 minutes). Get a new one in Hangar → Machines → Add Mac." ;;
                429) die "Too many wrong pairing codes from this Mac. Wait 10 minutes, then run this again." ;;
                *)
                    message=$(printf '%s' "$answer" | json_value message)
                    die "Enrolling failed: HTTP $status${message:+: $message}"
                    ;;
            esac

            # The configuration. The token reaches setup through its environment, never its arguments.
            token=$(printf '%s' "$answer" | json_value token)
            unset answer
            [ -n "$token" ] || die "The server's answer holds no token."
            HANGAR_WORKER_TOKEN=$token "$worker" setup --server "$HANGAR_SERVER" --max-jobs "$max_jobs" "$@" \
                || die "hangar-worker setup failed. $name is enrolled already: remove it in Hangar → Machines before running this again."
            unset token
            enrolled_now=1
        }

        # How a new Mac builds: build_mode=vm (a fresh macOS VM per build) or local (on this Mac, as this user). Only
        # Apple silicon runs VMs. HANGAR_VM answers it; otherwise it is asked on the terminal, and without one it is
        # VM builds. Answering the question sets mode_chosen, which also answers whether to run VM setup now.
        choose_mode() {
            build_mode=vm
            if [ "$(uname -m)" != arm64 ]; then
                build_mode=local
                return 0
            fi
            case ${HANGAR_VM:-} in
                0) build_mode=local; return 0 ;;
                1) return 0 ;;
            esac
            (: </dev/tty) 2>/dev/null || return 0
            me=$(id -un)
            {
                printf '\nHow should %s build?\n' "$name"
                printf '  1) In a fresh macOS VM per build (recommended): a build cannot see this Mac or your files.\n'
                printf '     Set up next with sudo, in about 15 minutes (a 26 GB download).\n'
                printf '  2) Directly on this Mac, as %s: nothing more to set up, but a build can read your files.\n' "$me"
                printf 'Choose 1 or 2 [1]: '
            } >/dev/tty
            IFS= read -r answer </dev/tty || answer=none
            case $answer in
                2) build_mode=local ;;
                '' | 1) mode_chosen=1 ;;
            esac
            if [ "$build_mode" = local ]; then
                say "$name builds on this Mac, as $me."
            else
                say "$name builds in VMs."
            fi
        }

        # Whether this Mac is being enrolled for VM builds.
        vm_planned() { [ "${build_mode:-}" = vm ]; }

        is_admin() { id -Gn | tr ' ' '\n' | grep -qx admin; }

        # One line of the preflight checklist. check_line <mark> <title> <detail>
        check_line() { say "  $1 $2: $3"; }

        # What this Mac has before anything is installed. Nothing here stops the install: `vm setup` checks again.
        preflight() {
            say "Checking this Mac:"
            if [ "$(uname -m)" = arm64 ]; then
                check_line ✓ "Apple silicon" "yes"
            else
                check_line ! "Apple silicon" "no ($(uname -m)): macOS VMs need Apple silicon, so this Mac builds on the host"
            fi
            check_line ✓ macOS "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
            xcode=''
            if [ -d /Applications/Xcode.app ]; then
                xcode=/Applications/Xcode.app
            else
                for candidate in /Applications/Xcode*.app; do [ -d "$candidate" ] && xcode=$candidate; done
            fi
            if [ -n "$xcode" ]; then
                version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$xcode/Contents/version.plist" 2>/dev/null || true)
                check_line ✓ Xcode "${version:-?} at $xcode"
                if DEVELOPER_DIR="$xcode/Contents/Developer" xcodebuild -license check >/dev/null 2>&1; then
                    check_line ✓ "Xcode license" accepted
                else
                    check_line ! "Xcode license" "not accepted yet (VM setup accepts it)"
                fi
            else
                check_line ✗ Xcode "not in /Applications: install it from the App Store and open it once; the worker cannot build without it"
            fi
            free=$(df -g / 2>/dev/null | awk 'NR == 2 { print $4 }')
            case $free in '' | *[!0-9]*) free='' ;; esac
            if [ -z "$free" ]; then
                check_line ! "Free space" unknown
            elif [ "$free" -ge 105 ]; then
                check_line ✓ "Free space" "$free GB on the startup disk (VM builds need about 105)"
            else
                check_line ! "Free space" "$free GB on the startup disk; VM builds need about 105 (images, a job, a 40 GB floor): free some, or use an external SSD with vm setup --storage"
            fi
            tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
            if [ -x "$tailscale" ] && "$tailscale" status >/dev/null 2>&1; then
                check_line ✓ Tailscale connected
            elif [ -x "$tailscale" ]; then
                check_line ! Tailscale "installed but not connected: open it and log in to the tailnet"
            else
                check_line ! Tailscale "not found in /Applications (fine if the server is reachable another way)"
            fi
            if curl -fsS -o /dev/null --max-time 5 "$HANGAR_SERVER/install" 2>/dev/null; then
                check_line ✓ Hangar "reachable at $HANGAR_SERVER"
            else
                check_line ✗ Hangar "cannot reach $HANGAR_SERVER: check that this Mac is on the tailnet"
            fi
        }

        # After a new Mac's install: sets up VM builds with `sudo hangar-worker vm setup` in the same Terminal, so sudo
        # usually does not ask again. Asked unless HANGAR_VM_SETUP says; skipped (with the command) when declined.
        # offer_vm_setup <installed hangar-worker>
        offer_vm_setup() {
            [ "$enrolled_now" = 1 ] && vm_planned || return 0
            command="sudo $1 vm setup"
            if [ "${HANGAR_NO_LAUNCHD:-}" = 1 ] || ! is_admin; then
                say "Next, an administrator sets up VM builds on this Mac (builds stay paused until then): $command"
                return 0
            fi
            answer=${HANGAR_VM_SETUP:-}
            # Picking VM builds a moment ago was the answer.
            [ -n "$answer" ] || [ "${mode_chosen:-}" != 1 ] || answer=y
            if [ -z "$answer" ]; then
                if (: </dev/tty) 2>/dev/null; then
                    printf 'Set up VM builds now? It takes about 15 minutes (a 26 GB download). [Y/n] ' >/dev/tty
                    IFS= read -r answer </dev/tty || answer=n
                else
                    answer=n
                fi
            fi
            case $answer in
                '' | [Yy]* | 1) ;;
                *)
                    say "Builds stay paused on $name until VM builds are set up. When you are ready, run: $command"
                    say "To build directly on this Mac instead, resume builds on its card in Hangar."
                    return 0
                    ;;
            esac
            sudo "$1" vm setup </dev/tty || die "VM setup did not finish. Run it again to pick up where it stopped: $command"
        }

        main() {
            [ "$(uname -s)" = Darwin ] || die "The Hangar worker runs on macOS only."
            say "Installing the Hangar worker from $HANGAR_SERVER"
            enrolled_now=''
            build_mode=''
            mode_chosen=''
            preflight

            bin_dir=$(absolute "${HANGAR_BIN_DIR:-$HOME/.local/bin}")
            bin_dir=${bin_dir%/}
            [ -n "$bin_dir" ] || bin_dir=/
            worker="$bin_dir/hangar-worker"

            name=${HANGAR_MACHINE_NAME:-}
            [ -n "$name" ] || name=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
            case $name in
                '' | *[[:cntrl:]]*) die "Set HANGAR_MACHINE_NAME to a name for this Mac (no control characters)." ;;
            esac

            max_jobs=${HANGAR_MAX_JOBS:-1}
            case $max_jobs in
                [1-9] | [1-9][0-9]) ;;
                *) die "HANGAR_MAX_JOBS must be a whole number from 1 to 99." ;;
            esac

            config=''
            [ -z "${HANGAR_WORKER_CONFIG:-}" ] || config=$(absolute "$HANGAR_WORKER_CONFIG")

            # 1. The binary.
            mkdir -p "$bin_dir" 2>/dev/null || die "Cannot create $bin_dir. Set HANGAR_BIN_DIR to a directory you own."
            [ -w "$bin_dir" ] || die "$bin_dir is not writable. Set HANGAR_BIN_DIR to a directory you own."
            trap 'rm -f "$bin_dir/.hangar-worker.download.$$"' EXIT
            trap 'exit 130' INT TERM HUP
            download_worker "$worker"
            say "Installed $worker"

            # 2. Already enrolled with this server? Then this run is an update: no code, no new machine.
            config_file=${config:-"$HOME/Library/Application Support/Hangar/worker/config.json"}
            if [ -f "$config_file" ]; then
                configured=$(/usr/bin/plutil -extract serverURL raw -o - "$config_file" 2>/dev/null || true)
                if [ "$configured" = "$HANGAR_SERVER" ]; then
                    if enrolled=$("$worker" check --config "$config_file"); then
                        finish "$enrolled" "Updated $enrolled."
                        return 0
                    else
                        result=$?
                        case $result in
                            3) say "This Mac was removed in Hangar, so it is enrolled again." ;;
                            4) die "Cannot reach $HANGAR_SERVER to check this Mac's enrollment. Nothing was enrolled; run this again once the server is reachable." ;;
                            *) die "Checking this Mac's enrollment failed (hangar-worker check exited $result). Nothing was enrolled." ;;
                        esac
                    fi
                else
                    warn "This Mac's worker is set up for ${configured:-another server}; it is enrolled with $HANGAR_SERVER instead, and $config_file is replaced."
                fi
            fi

            # Enrolling creates the machine in Hangar, so make sure setup can write its configuration first.
            config_dir=$(dirname "$config_file")
            if ! { (umask 077 && mkdir -p "$config_dir") 2>/dev/null && [ -w "$config_dir" ] \
                && { [ ! -e "$config_file" ] || [ -w "$config_file" ]; }; }; then
                die "Cannot write the worker configuration $config_file. Fix its permissions (or set HANGAR_WORKER_CONFIG), then run this again."
            fi

            # 3. How this Mac builds, then the pairing code, the enrollment and the configuration.
            choose_mode
            if [ -n "$config" ]; then enroll --config "$config"; else enroll; fi

            finish "$name" "Done — $name should appear in Hangar within a few seconds."
        }

        # The last steps of both an install and an update: the launchd agent and a health check.
        # finish <name> <closing line>
        finish() {
            case ":$PATH:" in
                *":$bin_dir:"*) ;;
                *) say "Note: $bin_dir is not on your PATH; the launchd agent does not need it." ;;
            esac
            if [ "${HANGAR_NO_LAUNCHD:-}" = 1 ]; then
                say "HANGAR_NO_LAUNCHD=1: the launchd agent was neither written nor loaded, and the doctor was skipped."
                say "$2"
                say "Run the worker by hand with: $worker run${config:+ --config $config}"
                return 0
            fi
            install_agent
            summary
            say "$2"
            offer_vm_setup "$worker"
        }

        # Nothing runs until the whole script has arrived: a cut-off download only defines functions.
        main "$@"

        """#
}
