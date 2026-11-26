#if os(macOS)
    import Foundation

    /// The stub `ssh` that `SystemSSHConnectionTests` describes, and its install.
    extension SystemSSHConnectionTests {
        static let stub = #"""
            #!/bin/bash
            sock=""; request=""; master=no; prev=""
            for arg in "$@"; do
              case "$prev" in -S) sock="$arg" ;; -O) request="$arg" ;; -L) forward="$arg" ;; esac
              [ "$arg" = "ControlMaster=yes" ] && master=yes
              prev="$arg"
            done
            if [ "$master" = yes ]; then
              dir="${sock%/*}"
              echo $$ > "$dir/master.pid"
              printf '%s\n' "$@" > "$dir/args"
              printf '%s' "${SSH_ASKPASS:-}" > "$dir/askpass"
              printf '%s' "${GLIFFTOP_ASKPASS_SOCKET:-}" > "$dir/bridge"
              [ -n "$STUB_REFUSE" ] && { echo "user@omarchy: Permission denied (publickey)." >&2; exit 255; }
              [ -n "$STUB_CHANGED" ] && { printf '%s\n' "$STUB_CHANGED" >&2; exit 255; }
              if [ -n "$STUB_JUMP" ]; then
                # A jump host's ssh: it asks, and sends whatever answer it gets, even none.
                ( answer=$("$SSH_ASKPASS" "$STUB_JUMP"); printf '%s' "$answer" > "$dir/jump" ) &
                wait
                exit 255
              fi
              if [ -n "$STUB_LATE" ]; then
                # Asks once the bridge is gone, as ssh may between two questions.
                while [ -S "$GLIFFTOP_ASKPASS_SOCKET" ]; do sleep 0.02; done
                "$SSH_ASKPASS" "$STUB_LATE" > /dev/null 2>&1; echo $? > "$dir/late"
                exit 255
              fi
              if [ -n "$STUB_ASK" ]; then
                answer=$("$SSH_ASKPASS" "$STUB_ASK") || { echo "user@omarchy: Permission denied (publickey)." >&2; exit 255; }
                printf '%s' "$answer" > "$dir/answer"
                [ "$answer" = no ] && { echo "Host key verification failed." >&2; exit 255; }
              fi
              sleep "${STUB_DELAY:-0}"
              # A ProxyJump's ssh: a child that keeps the master's pipes open after it ends.
              [ -n "$STUB_HOLD_PIPES" ] && { sleep 2 & }
              trap 'rm -f "$sock"; exit ${STUB_EXIT_STATUS:-0}' USR1
              trap 'rm -f "$sock"; sleep "${STUB_DYING:-0}"; echo "Timeout, server omarchy not responding." >&2; exit 255' TERM
              echo $$ > "$sock"
              while :; do sleep 0.05; done
            fi
            if [ "$request" = check ]; then [ -f "$sock" ] && exit 0; exit 255; fi
            if [ "$request" = forward ] || [ "$request" = cancel ]; then
              [ "$request" = forward ] && echo "$forward" >> "${sock%/*}/forwards"
              echo "+$request $forward" >> "${sock%/*}/requests"
              [ -n "$STUB_FORWARD_DELAY" ] && sleep "$STUB_FORWARD_DELAY"
              [ -n "$STUB_FORWARD_ERROR" ] && echo "$STUB_FORWARD_ERROR" >&2
              echo "-$request $forward" >> "${sock%/*}/requests"
              exit ${STUB_FORWARD_STATUS:-0}
            fi
            if [ "$request" = exit ]; then
              master=$(cat "$sock"); kill -USR1 "$master"
              while kill -0 "$master" 2>/dev/null; do sleep 0.02; done
              exit 0
            fi
            [ -f "$sock" ] || { echo "kex_exchange_identification: Connection closed by remote host" >&2; exit 255; }
            pid=$(cat "$sock")
            exec 3<&0
            cat <&3 &
            echo=$!
            while kill -0 "$pid" 2>/dev/null && kill -0 "$echo" 2>/dev/null; do sleep 0.05; done
            kill -0 "$echo" 2>/dev/null || exit 0
            kill "$echo"
            echo "mux_client_read_packet: read header failed: Broken pipe" >&2
            exit 255
            """#

        func stub(_ environment: String = "") throws -> URL { try Self.install(in: root, environment) }

        /// Writes the stub, with `environment` set first, as `root`'s `ssh`.
        static func install(in root: URL, _ environment: String) throws -> URL {
            let url = root.appending(path: "ssh")
            let script = stub.replacing("#!/bin/bash\n", with: "#!/bin/bash\n\(environment)\n")
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
    }
#endif
