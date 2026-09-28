#!/bin/sh
# VAL home-visit bootstrap — run ONCE on valiant-node, at its keyboard:
#
#     sudo sh home-visit.sh
#
# It contains no secrets. Read it before running; every step says what it does.
#
#   PHASE 1  read-only evidence capture (nothing restarted, nothing changed)
#   PHASE 2  safety checks, then:
#              a. Access-protected admin route  val-admin.valiantlux.com -> ssh://127.0.0.1:22
#                 added to the EXISTING locally-managed tunnel (no migration, no open port)
#              b. least-privilege rights for user jim: read the journal; passwordless
#                 `systemctl restart` of exactly four VAL units — nothing else
#   PHASE 3  self-test of the public path from the node itself (sign in on your phone)
#
# Stops at the first failed check. The tunnel change rolls itself back if the tunnel
# does not reconnect cleanly or val.valiantlux.com stops routing to Caddy.
set -u

ADMIN_AUD="de0e638d4863568b5136ae004b6c8a9576b69041f53854e62a0391a00ceb1a77"                       # Access app "VAL admin" AUD tag (not secret)
ADMIN_HOST="val-admin.valiantlux.com"
OFFICE_KEY_FP="SHA256:FkZTWfDED8tpu+ld+rL/cJwvR6C42rMOhKXImGOqyew"   # office PC key (public fingerprint)
TUNNEL_UNIT="cloudflared-valiant"
RESTART_UNITS="cloudflared-valiant caddy valiant-bridge valiant-ui"
SUDOERS=/etc/sudoers.d/60-valiant-restart
TS=$(date -u +%Y%m%dT%H%M%SZ)
WORK=/root/valiant-home-visit/$TS
say()  { printf '\n=== %s\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; }
die()  { printf '\n  STOP  %s\n  Nothing after this point was changed. Tell Claude what this says.\n' "$*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run it with sudo:  sudo sh home-visit.sh"
case "$ADMIN_AUD" in *[!0-9a-f]*|"") die "this copy has no AUD tag filled in";; esac
umask 077
mkdir -p "$WORK"

# ───────────────────────────── PHASE 1: evidence ─────────────────────────────
say "PHASE 1 — read-only capture (nothing restarts)"
DIAG=/root/val-diag-$TS.txt
W1="2026-09-28 16:20:00 UTC"; W2="2026-09-28 17:00:00 UTC"
{
echo "## host / time"; hostname; date -u; uptime; timedatectl 2>/dev/null | grep -E "synchronized|NTP"
echo; echo "## boots"; journalctl --list-boots --no-pager 2>/dev/null | tail -5
echo; echo "## units"
for u in $RESTART_UNITS; do systemctl show "$u" -p Id -p ActiveState -p SubState -p ActiveEnterTimestamp -p NRestarts -p MemoryCurrent -p MemoryMax -p Result -p User --no-pager | tr '\n' ' '; echo; done
echo; echo "## cloudflared"; pgrep -a cloudflared; cloudflared --version
CONF=$(systemctl show -p ExecStart "$TUNNEL_UNIT" | grep -o -- '--config[= ][^ ;]*' | head -1 | sed 's/--config[= ]//'); [ -n "$CONF" ] || CONF=$(ls /etc/cloudflared/config.y*ml 2>/dev/null | head -1)
echo "config: $CONF"; systemctl show -p ExecStart "$TUNNEL_UNIT" --no-pager
echo; echo "## ingress"; grep -v -iE "secret|token" "$CONF"
for u in https://val.valiantlux.com/ https://val.valiantlux.com/health; do cloudflared tunnel --config "$CONF" ingress rule "$u"; done
echo; echo "## tunnel connections (metrics)"
for p in $(ss -ltnp 2>/dev/null | awk '/cloudflared/ {n=split($4,a,":"); print a[n]}'); do
  echo "metrics :$p"; curl -s -m 5 "http://127.0.0.1:$p/ready"; echo
  curl -s -m 5 "http://127.0.0.1:$p/metrics" | grep -E "^cloudflared_tunnel_(ha_connections|server_locations|request_errors|total_requests|tunnel_register_success|tunnel_register_fail|timer_retries)" | head -40
done
echo; echo "## registrations since boot"
journalctl -u "$TUNNEL_UNIT" -b --no-pager -o short-iso-precise 2>/dev/null | grep -iE "Registered tunnel connection|Unregistered|Lost connection|Retrying|failed to serve|terminated|protocol|fallback|timeout|reconnect|error" | tail -80
echo; echo "## cloudflared journal $W1 .. $W2"; journalctl -u "$TUNNEL_UNIT" --since "$W1" --until "$W2" --no-pager -o short-iso-precise 2>/dev/null | tail -200
echo; echo "## caddy journal";           journalctl -u caddy --since "$W1" --until "$W2" --no-pager -o short-iso-precise 2>/dev/null | tail -200
echo; echo "## bridge/ui journal";       journalctl -u valiant-bridge -u valiant-ui --since "$W1" --until "$W2" --no-pager -o short-iso-precise 2>/dev/null | tail -100
echo; echo "## caddy config (no secrets expected)"; for f in /etc/caddy/Caddyfile; do [ -f "$f" ] && sed 's/\(key\|secret\|token\|password\)[^ ]*/[redacted]/Ig' "$f"; done
echo; echo "## sockets"; ss -ltnp 2>/dev/null
echo; echo "## local origin"
curl -s -m 5 -o /dev/null -w "caddy :8080/          %{http_code} %{time_total}s\n" http://127.0.0.1:8080/
curl -s -m 5 -o /dev/null -w "caddy :8080/ (Host)   %{http_code} %{time_total}s\n" -H "Host: val.valiantlux.com" http://127.0.0.1:8080/
curl -s -m 5 -w "  <- bridge :8787/health %{http_code}\n" http://127.0.0.1:8787/health
curl -s -m 5 -o /dev/null -w "ui :5173/             %{http_code}\n" http://127.0.0.1:5173/
echo; echo "## memory / OOM"; free -m; journalctl -k -b --no-pager 2>/dev/null | grep -iE "oom|killed process|out of memory" | tail -10
echo; echo "## network"; ip -br addr; ip route; head -3 /etc/resolv.conf
} > "$DIAG" 2>&1
[ -s "$DIAG" ] || die "diagnostic file is empty"
[ -f "$CONF" ] || die "could not find the tunnel config for $TUNNEL_UNIT (evidence was saved: $DIAG)"
install -d -m 700 -o jim -g jim /home/jim/val-diag
install -m 600 -o jim -g jim "$DIAG" /home/jim/val-diag/
ok "evidence saved: $DIAG ($(wc -c < "$DIAG") bytes); readable copy for jim: /home/jim/val-diag/$(basename "$DIAG")"

# ───────────────────────────── PHASE 2: checks ───────────────────────────────
say "PHASE 2 — safety checks (still nothing changed)"

# SSH stays key-only, no root, no password; the office key is authorized; sshd answers on loopback.
SSHD=$(sshd -T 2>/dev/null)
echo "$SSHD" | grep -qx "passwordauthentication no"      || die "sshd allows password login"
echo "$SSHD" | grep -qx "permitrootlogin no"             || die "sshd allows root login"
echo "$SSHD" | grep -qx "pubkeyauthentication yes"       || die "sshd public-key login is off"
echo "$SSHD" | grep -qx "kbdinteractiveauthentication no" || die "sshd keyboard-interactive login is on"
ok "sshd: key-only, no root, no password"
ssh-keygen -lf /home/jim/.ssh/authorized_keys 2>/dev/null | grep -qF "$OFFICE_KEY_FP" || die "the office PC key ($OFFICE_KEY_FP) is not in jim's authorized_keys"
ok "office PC key is authorized for jim"
ss -ltn | awk '{print $4}' | grep -qE '^(0\.0\.0\.0|127\.0\.0\.1|\*|\[::\]):22$' || die "sshd is not listening where the tunnel can reach it (127.0.0.1:22)"
ok "sshd reachable on 127.0.0.1:22 (tunnel will connect locally; no port opened)"

# Nothing that runs for these four units — or as root on their behalf — may be writable by jim.
say "PHASE 2 — can jim modify anything these services run? (fixing if so)"
PATHS="$WORK/paths"; : > "$PATHS"
for u in $RESTART_UNITS; do
  systemctl show "$u" -p FragmentPath -p DropInPaths -p EnvironmentFiles -p WorkingDirectory -p ExecStartPre -p ExecStart -p ExecStartPost -p ExecReload --no-pager \
   | sed 's/^[A-Za-z]*=//' | tr ' ;' '\n\n' | sed 's/^path=//; s/^-//; s/^@//' | grep '^/' >> "$PATHS"
done
printf '%s\n' "$CONF" /etc/cloudflared /etc/caddy /etc/valiant /opt/valiant /etc/systemd/system /usr/lib/systemd/system >> "$PATHS"
sort -u "$PATHS" -o "$PATHS"
FIXED=0; BAD=0
check_path() {   # the path itself and every parent directory up to /
  p=$1
  while [ -n "$p" ]; do
    if [ -e "$p" ] && runuser -u jim -- test -w "$p" 2>/dev/null; then
      echo "  jim can write: $p  -> chown root:root, chmod go-w" | tee -a "$WORK/fixes"
      chown root:root "$p" && chmod go-w "$p" && FIXED=$((FIXED + 1))
      runuser -u jim -- test -w "$p" 2>/dev/null && { echo "  STILL writable: $p"; BAD=$((BAD + 1)); }
    fi
    [ "$p" = / ] && break
    p=$(dirname "$p")
  done
}
while read -r p; do check_path "$p"; done < "$PATHS"
for d in /opt/valiant /etc/valiant /etc/caddy /etc/cloudflared; do          # whole trees, not just the top
  [ -d "$d" ] && runuser -u jim -- find "$d" -writable 2>/dev/null | while read -r w; do echo "$w"; done >> "$WORK/writable-trees"
done
if [ -s "$WORK/writable-trees" ]; then
  while read -r w; do echo "  jim can write: $w -> chown root:root, chmod go-w" | tee -a "$WORK/fixes"; chown root:root "$w"; chmod go-w "$w"; done < "$WORK/writable-trees"
  runuser -u jim -- find /opt/valiant /etc/valiant /etc/caddy /etc/cloudflared -writable 2>/dev/null | grep -q . && BAD=$((BAD + 1))
fi
[ "$BAD" -eq 0 ] || die "some service files are still writable by jim (see $WORK/fixes)"
ok "jim cannot modify unit files, drop-ins, environment files, ExecStart programs, Caddy or cloudflared config ($(wc -l < "$PATHS") paths + 4 trees checked; fixes: $( [ -f "$WORK/fixes" ] && wc -l < "$WORK/fixes" || echo 0))"

# The journal jim will be able to read must not contain secrets. Counts only — matches are never printed.
say "PHASE 2 — does the journal hold secrets? (counts only)"
HITS=$(journalctl --no-pager -o cat 2>/dev/null | grep -ciE "sk-[a-z0-9_-]{16,}|sk-proj-|ya29\.|1//0[a-z0-9_-]{20,}|authorization: *bearer|cf-access-client-secret|client_secret|refresh_token\"? *[:=]|GOCSPX-|password *[:=] *[^ *]{4,}")
if [ "$HITS" -eq 0 ]; then JOURNAL_OK=1; ok "no secret-shaped strings in the whole journal"
else JOURNAL_OK=0; echo "  WARN  $HITS secret-shaped lines in the journal — journal access will NOT be granted (Claude will look into it with you)"; fi

# ─────────────────────── PHASE 2a: admin route on the tunnel ───────────────────────
say "PHASE 2a — add $ADMIN_HOST to the existing tunnel (evidence already saved)"
if grep -q "$ADMIN_HOST" "$CONF"; then ok "route already present"
else
  grep -q '^[[:space:]]*- service: http_status:404' "$CONF" || die "tunnel config has no catch-all rule; refusing to edit it by script"
  cp -a "$CONF" "$WORK/"
  NEW=$WORK/new-config.yml
  awk -v a="$ADMIN_AUD" -v h="$ADMIN_HOST" '
    /^[[:space:]]*- service: http_status:404/ && !done {
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      print ind "- hostname: " h
      print ind "  service: ssh://127.0.0.1:22"
      print ind "  originRequest:"
      print ind "    access: { required: true, teamName: valiantlux, audTag: [" a "] }"
      done = 1
    }
    { print }' "$CONF" > "$NEW"
  cloudflared tunnel --config "$NEW" ingress validate >/dev/null 2>&1 || die "new tunnel config did not validate (unchanged)"
  cloudflared tunnel --config "$NEW" ingress rule "https://$ADMIN_HOST/" | grep -q "ssh://127.0.0.1:22" || die "admin route does not resolve as expected (unchanged)"
  cloudflared tunnel --config "$NEW" ingress rule https://val.valiantlux.com/ | grep -q "127.0.0.1:8080" || die "val route would change (unchanged)"
  install -m "$(stat -c %a "$CONF")" -o "$(stat -c %U "$CONF")" -g "$(stat -c %G "$CONF")" "$NEW" "$CONF"
  SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl restart "$TUNNEL_UNIT"
  i=0
  until [ "$(journalctl -u "$TUNNEL_UNIT" --since "$SINCE" --no-pager 2>/dev/null | grep -c 'Registered tunnel connection')" -ge 2 ]; do
    i=$((i + 1))
    if [ $i -gt 45 ]; then
      cp -a "$WORK/$(basename "$CONF")" "$CONF"; systemctl restart "$TUNNEL_UNIT"
      die "tunnel did not reconnect after the change — original config RESTORED and tunnel restarted"
    fi
    sleep 2
  done
  ok "tunnel reconnected with the admin route; val.valiantlux.com still -> Caddy (backup: $WORK/)"
fi

# ─────────────────────── PHASE 2b: least-privilege rights ───────────────────────
say "PHASE 2b — rights for jim"
if [ "$JOURNAL_OK" = 1 ]; then usermod -aG systemd-journal jim && ok "jim can read the journal (systemd-journal group)"; fi
TMP=$WORK/sudoers
cat > "$TMP" <<'SUDO'
# VAL: user jim may restart exactly these four units without a password. Nothing else.
# Installed by home-visit.sh. Everything else still requires Jim's password.
Cmnd_Alias VALIANT_RESTART = /usr/bin/systemctl restart cloudflared-valiant, \
                             /usr/bin/systemctl restart caddy, \
                             /usr/bin/systemctl restart valiant-bridge, \
                             /usr/bin/systemctl restart valiant-ui
jim ALL=(root) NOPASSWD: VALIANT_RESTART
SUDO
visudo -cf "$TMP" >/dev/null || die "sudoers rule failed validation (not installed)"
install -m 440 -o root -g root "$TMP" "$SUDOERS"
visudo -c >/dev/null || { rm -f "$SUDOERS"; die "full sudoers check failed — rule REMOVED"; }
ok "installed $SUDOERS"

say "PHASE 2b — prove it: allowed commands work, everything else is refused"
as_jim() { runuser -u jim -- sudo -n "$@" >/dev/null 2>&1; }
for u in valiant-ui valiant-bridge caddy; do as_jim /usr/bin/systemctl restart "$u" && ok "allowed: systemctl restart $u" || die "allowed restart of $u failed"; done
as_jim -l /usr/bin/systemctl restart cloudflared-valiant && ok "allowed (listed, not re-run): systemctl restart cloudflared-valiant" || die "cloudflared-valiant restart not permitted"
FAILS=0
for cmd in "/usr/bin/systemctl stop caddy" "/usr/bin/systemctl restart ssh" "/usr/bin/systemctl restart caddy --now" \
           "/usr/bin/systemctl daemon-reload" "/usr/bin/systemctl edit caddy" "/usr/bin/systemctl restart caddy.service" \
           "/bin/sh -c id" "/usr/bin/bash" "/usr/bin/tee /etc/x" "/usr/bin/cp /etc/shadow /tmp/x" "/usr/bin/chmod 777 /etc" \
           "/usr/bin/apt-get install x" "/usr/sbin/reboot" "/usr/bin/id"; do
  if as_jim $cmd; then echo "  FAIL  was allowed: sudo $cmd"; FAILS=$((FAILS + 1)); else echo "  PASS  refused: sudo $cmd"; fi
done
if [ "$FAILS" -ne 0 ]; then rm -f "$SUDOERS"; die "$FAILS unapproved commands were allowed — sudoers rule REMOVED"; fi
for u in $RESTART_UNITS; do systemctl is-active --quiet "$u" || die "$u is not active after the tests"; done
ok "all four services active"

# ─────────────────────────────── PHASE 3 ───────────────────────────────────────
# The office cannot test this yet (its resolver blocks *.valiantlux.com until the
# categorization is fixed), so the node tests the full public path itself:
# node -> Cloudflare -> Access (Jim signs in on his phone) -> tunnel -> sshd.
# Reaching sshd and being refused for lack of a key proves every hop works;
# jim has no key for himself here, so "Permission denied (publickey)" is the PASS.
say "PHASE 3 — self-test through Cloudflare"
echo "  cloudflared will print a sign-in link. Open it on your phone and sign in"
echo "  with jim@valiantlux.com (the 'Jim emergency' policy). Then come back here."
OUT3=$(runuser -u jim -- ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
        -o ProxyCommand="cloudflared access ssh --hostname %h" "jim@$ADMIN_HOST" true 2>&1)
echo "$OUT3" | tail -3
if echo "$OUT3" | grep -q "Permission denied (publickey"; then
  ok "public path works: Cloudflare -> Access -> tunnel -> sshd (key-only refusal as expected)"
else
  echo "  WARN  self-test did not reach sshd. The route and rights are installed; tell Claude what it printed."
fi

say "READY"
cat <<EOF
  Evidence:   $DIAG   (copy: /home/jim/val-diag/)
  Backups:    $WORK/
  Admin path: $ADMIN_HOST -> ssh://127.0.0.1:22 (Cloudflare Access; key-only SSH as jim)

  Tell Claude Code "node ready" and what PHASE 3 printed. You can leave the node now:
  office access starts working as soon as the office resolver stops blocking
  valiantlux.com (Talos re-categorization or IT allow-list). Nothing more is needed here.
EOF
