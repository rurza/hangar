import Foundation

/// The worker install script `GET /install` serves, with the server's address baked in.
///
/// The launchd plist is embedded in the script (a heredoc with the same keys as scripts/worker/app.hangar.worker.plist)
/// rather than served separately: one download fewer, and nothing on the server to keep in sync with it.
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

    /// The script for `origin`, which must come from `origin(authority:)`.
    static func render(origin: String) -> String {
        template.replacingOccurrences(of: originPlaceholder, with: origin)
    }

    static let template = #"""
        #!/bin/sh
        # Installs the Hangar worker on this Mac and enrolls it with the Hangar server at __HANGAR_ORIGIN__,
        # which serves this script:
        #
        #   curl -fsSL __HANGAR_ORIGIN__/install | sh
        #
        # Run it as the user that builds (the worker runs as a launchd agent in that user's GUI session). It
        # downloads hangar-worker, asks for the pairing code shown in Hangar under Machines > Add Mac, enrolls this
        # Mac, writes the worker configuration and starts the agent. No sudo, no checkout, no Swift build.
        #
        # Run it again to update: when this Mac is already enrolled with this server (`hangar-worker check`), it
        # replaces the binary and restarts the agent without asking for a code.
        #
        # Settings, all optional, as environment variables (put them after the pipe: ... | HANGAR_MAX_JOBS=2 sh):
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

        # Writes the launchd agent (the keys of scripts/worker/app.hangar.worker.plist) and (re)loads it.
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
            if [ "$(printf '%s' "$report" | json_value canSignWithoutPrompt)" = true ]; then
                say "  Can sign without a prompt: yes"
            else
                say "  Can sign without a prompt: not yet. Normal on a new Mac: the first archive creates the signing"
                say "  identity; then allow codesign in Keychain Access (see docs/worker-setup.md in Hangar)."
            fi
        }

        main() {
            [ "$(uname -s)" = Darwin ] || die "The Hangar worker runs on macOS only."
            say "Installing the Hangar worker from $HANGAR_SERVER"
            say "This Mac: macOS $(sw_vers -productVersion 2>/dev/null || echo unknown), $(uname -m)"
            if developer=$(xcode-select -p 2>/dev/null); then
                case $developer in
                    *.app/*) say "Xcode: $developer" ;;
                    *) warn "Only the Command Line Tools are selected ($developer). Install Xcode before building." ;;
                esac
            else
                warn "Xcode is not installed. The worker installs, but cannot build until you install Xcode."
            fi

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

            # 1. The binary: downloaded next to its final place, then renamed over it, so a running worker keeps
            #    its own copy until it restarts.
            mkdir -p "$bin_dir" 2>/dev/null || die "Cannot create $bin_dir. Set HANGAR_BIN_DIR to a directory you own."
            [ -w "$bin_dir" ] || die "$bin_dir is not writable. Set HANGAR_BIN_DIR to a directory you own."
            download="$bin_dir/.hangar-worker.download.$$"
            trap 'rm -f "$download"' EXIT
            trap 'exit 130' INT TERM HUP
            say "Downloading hangar-worker..."
            status=$(curl -sS -o "$download" -w '%{http_code}' "$HANGAR_SERVER/install/hangar-worker") \
                || die "Cannot reach $HANGAR_SERVER. Check that this Mac is on the tailnet."
            case $status in
                200) ;;
                503) die "The server has no hangar-worker to hand out. Reinstall the server with the latest scripts/server/install-server.sh, then run this again." ;;
                *) die "Downloading hangar-worker failed: HTTP $status." ;;
            esac
            chmod 755 "$download"
            xattr -d com.apple.quarantine "$download" 2>/dev/null || true
            "$download" --help >/dev/null 2>&1 \
                || die "The downloaded hangar-worker does not run on this Mac ($(uname -m)); the server may have a build for another architecture."
            mv -f "$download" "$worker"
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

            # 3. The pairing code. The script itself arrives on stdin, so the code is read from the terminal.
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

            # 4. Enroll. The body goes on stdin and the answer, which holds the token, stays in this shell.
            say "Enrolling $name..."
            body=$(printf '{"code":"%s","name":"%s","maxConcurrentJobs":%s}' "$code" "$(json_escape "$name")" "$max_jobs")
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

            # 5. The configuration. The token reaches setup through its environment, never its arguments.
            token=$(printf '%s' "$answer" | json_value token)
            unset answer
            [ -n "$token" ] || die "The server's answer holds no token."
            set -- setup --server "$HANGAR_SERVER" --max-jobs "$max_jobs"
            [ -z "$config" ] || set -- "$@" --config "$config"
            HANGAR_WORKER_TOKEN=$token "$worker" "$@" \
                || die "hangar-worker setup failed. $name is enrolled already: remove it in Hangar → Machines before running this again."
            unset token

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
        }

        # Nothing runs until the whole script has arrived: a cut-off download only defines functions.
        main "$@"

        """#
}
