#!/bin/sh
# VAL clock fix — run ONCE on valiant-node:   sudo sh t.sh
# No secrets. Read it before running.
#
# The MacBook's hardware clock (RTC) does not keep time across power loss (it reads
# 2001), so after every boot the system clock is only as good as network time.
# Cloudflare Access tokens are checked against this clock, so a wrong clock breaks
# both val.valiantlux.com (502) and val-admin ("JWT is more than 5m0s in the future").
#
#   1. save diagnostics (nothing changed yet)
#   2. find out why systemd-timesyncd is not synchronizing (DNS? UDP 123? config?)
#   3. set reliable NTP servers; force a sync now (HTTPS time as a bounded fallback)
#   4. install boot behavior: network -> time check (bounded, ~2 min) -> cloudflared,
#      plus a 10-minute re-check timer; nothing can block remote access forever
#   5. verify, then re-run the val-admin self-test
set -u
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG=/home/jim/val-diag/clock-$TS.txt
say() { printf '\n=== %s\n' "$*" | tee -a "$LOG"; }
ok()  { printf '  PASS  %s\n' "$*" | tee -a "$LOG"; }
warn(){ printf '  WARN  %s\n' "$*" | tee -a "$LOG"; }
die() { printf '\n  STOP  %s\n' "$*" | tee -a "$LOG"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run with sudo: sudo sh t.sh"; exit 1; }
install -d -m 700 -o jim -g jim /home/jim/val-diag
: > "$LOG"; chown jim:jim "$LOG"; chmod 600 "$LOG"

# Probe helpers (python3 is present on the node; no packages needed).
cat > /usr/local/sbin/valiant-netclock <<'PY'
#!/usr/bin/python3
"""Print network time evidence. `sntp HOST...` queries NTP (UDP 123) directly;
`https` reads the Date header from two independent HTTPS sites and prints their
agreed UTC epoch, or exits 1 if they are unreachable or disagree by > 5 s."""
import email.utils, socket, ssl, struct, sys, time, urllib.error, urllib.request
def sntp(host):
    pkt = b'\x1b' + 47 * b'\0'
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(4)
        addr = socket.getaddrinfo(host, 123, socket.AF_INET)[0][4]
        t0 = time.time(); s.sendto(pkt, addr); data, _ = s.recvfrom(48); t1 = time.time()
    secs, frac = struct.unpack('!II', data[40:48])
    server = secs - 2208988800 + frac / 2**32
    return server - (t0 + t1) / 2
def https_now():
    # Certificate-verified only: a clock off by hours still validates certificates
    # (they last months), and an unverified Date header could be forged.
    got = []
    for url in ('https://www.cloudflare.com/cdn-cgi/trace', 'https://www.google.com/generate_204'):
        try:
            with urllib.request.urlopen(url, timeout=8, context=ssl.create_default_context()) as r:
                hdr = r.headers['Date']
        except urllib.error.HTTPError as e:   # an error reply is still a verified TLS reply
            hdr = e.headers.get('Date')
        except Exception:
            continue
        if hdr: got.append(email.utils.parsedate_to_datetime(hdr).timestamp())
    if len(got) < 2 or abs(got[0] - got[1]) > 5: sys.exit(1)
    print(int(sum(got) / 2))
if sys.argv[1] == 'sntp':
    for h in sys.argv[2:]:
        try: print(f'{h}: reachable, offset {sntp(h):+.1f} s')
        except socket.gaierror: print(f'{h}: DNS FAILED')
        except (socket.timeout, OSError) as e: print(f'{h}: NO REPLY on UDP 123 ({type(e).__name__})')
elif sys.argv[1] == 'https':
    https_now()
PY
chmod 755 /usr/local/sbin/valiant-netclock

# ─────────────────────── 1. evidence ───────────────────────
say "1. diagnostics (nothing changed yet)"
{
  echo "system UTC now: $(date -u)"; timedatectl; echo; timedatectl timesync-status 2>&1
  echo; systemctl status systemd-timesyncd --no-pager 2>&1 | head -20
  echo; journalctl -u systemd-timesyncd --no-pager -n 60 2>&1
  echo; echo "## timesyncd config"; grep -hv '^\s*#' /etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf.d/*.conf 2>/dev/null | grep -v '^\s*$'
  echo; echo "## resolv.conf"; head -5 /etc/resolv.conf
  echo; echo "## ufw"; ufw status verbose 2>&1 | head -8
  echo; echo "## hwclock"; command -v hwclock && hwclock --show 2>&1
} >> "$LOG" 2>&1
ok "saved to $LOG"

# ─────────────────────── 2. cause ───────────────────────
say "2. why is timesyncd not synchronizing?"
PROBE=$(/usr/local/sbin/valiant-netclock sntp time.cloudflare.com time.google.com 0.debian.pool.ntp.org 2>&1); echo "$PROBE" | tee -a "$LOG"
HTTPS_NOW=$(/usr/local/sbin/valiant-netclock https 2>/dev/null) && echo "  HTTPS time agrees across two sites: $(date -u -d "@$HTTPS_NOW")" | tee -a "$LOG" || echo "  HTTPS time: unavailable" | tee -a "$LOG"
if echo "$PROBE" | grep -q reachable; then CAUSE="udp123-ok"; ok "NTP (UDP 123) works from here — timesyncd itself is the problem (config/state)"
elif echo "$PROBE" | grep -q "DNS FAILED"; then CAUSE="dns"; warn "NTP server names do not resolve (DNS)"
else CAUSE="udp123-blocked"; warn "NTP servers resolve but never answer: outbound UDP 123 is blocked on this network"; fi
if ufw status verbose 2>/dev/null | grep -qi "deny (outgoing)"; then warn "UFW denies outgoing traffic by default"; CAUSE="$CAUSE+ufw-out"; fi
echo "  cause: $CAUSE" >> "$LOG"

# ─────────────────────── 3. configure + sync now ───────────────────────
say "3. configure NTP and synchronize now"
install -d /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/60-valiant.conf <<'EOF'
# VAL: explicit, reliable time sources (the RTC cannot be trusted after power loss).
[Time]
NTP=time.cloudflare.com time.google.com 0.debian.pool.ntp.org 1.debian.pool.ntp.org
FallbackNTP=2.debian.pool.ntp.org 3.debian.pool.ntp.org
ConnectionRetrySec=15
EOF
timedatectl set-ntp true 2>/dev/null
systemctl restart systemd-timesyncd
i=0; until [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] || [ $i -ge 45 ]; do sleep 2; i=$((i + 1)); done
if [ "$(timedatectl show -p NTPSynchronized --value)" = yes ]; then ok "NTP synchronized: $(date -u)"
else
  warn "NTP did not synchronize within 90 s (cause: $CAUSE) — using HTTPS time now"
  N=$(/usr/local/sbin/valiant-netclock https) || die "no network time source reachable at all (NTP and HTTPS both failed)"
  date -u -s "@$N" >/dev/null && ok "clock set from HTTPS time: $(date -u)"
fi

# ─────────────────────── 4. boot behavior ───────────────────────
say "4. permanent boot behavior"
cat > /usr/local/sbin/valiant-timecheck <<'EOF'
#!/bin/sh
# Wait (bounded) for NTP; if it never syncs, set the clock from HTTPS time.
# Always exits 0 so it can never block cloudflared (remote access) forever.
for i in $(seq 1 60); do
  [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && { echo "valiant-timecheck: NTP synchronized"; exit 0; }
  sleep 2
done
N=$(/usr/local/sbin/valiant-netclock https) || { echo "valiant-timecheck: WARNING no network time (NTP and HTTPS failed); continuing"; exit 0; }
DIFF=$(( N - $(date -u +%s) ))
if [ ${DIFF#-} -le 30 ]; then echo "valiant-timecheck: NTP not synced; clock within 30s of HTTPS time"
elif date -u -s "@$N" >/dev/null; then echo "valiant-timecheck: NTP not synced; clock stepped ${DIFF}s from HTTPS time"
else echo "valiant-timecheck: WARNING could not set the clock"; fi
command -v hwclock >/dev/null && hwclock --systohc 2>/dev/null
exit 0
EOF
chmod 755 /usr/local/sbin/valiant-timecheck
cat > /etc/systemd/system/valiant-timecheck.service <<'EOF'
[Unit]
Description=VAL: make sure the clock is right before Cloudflare starts (bounded)
Wants=network-online.target systemd-timesyncd.service
After=network-online.target systemd-timesyncd.service
Before=cloudflared-valiant.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/valiant-timecheck
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/valiant-timecheck.timer <<'EOF'
[Unit]
Description=VAL: re-check the clock every 10 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
EOF
install -d /etc/systemd/system/cloudflared-valiant.service.d
cat > /etc/systemd/system/cloudflared-valiant.service.d/10-after-timecheck.conf <<'EOF'
# VAL: start the tunnel only after the (bounded) clock check.
[Unit]
Wants=valiant-timecheck.service
After=valiant-timecheck.service
EOF
systemctl daemon-reload
systemctl enable --quiet valiant-timecheck.service valiant-timecheck.timer systemd-timesyncd.service
systemctl start valiant-timecheck.timer
systemctl list-dependencies --after cloudflared-valiant.service 2>/dev/null | grep -q valiant-timecheck && ok "cloudflared-valiant now starts after valiant-timecheck (max ~2 min wait, then continues regardless)" || die "ordering was not applied"
command -v hwclock >/dev/null && { hwclock --systohc 2>/dev/null && ok "hardware clock written (it may still reset on power loss; the boot check covers that)"; } || echo "  (no hwclock tool; the boot check covers the RTC)" | tee -a "$LOG"

# ─────────────────────── 5. verify ───────────────────────
say "5. verify"
timedatectl | tee -a "$LOG"
N=$(/usr/local/sbin/valiant-netclock https 2>/dev/null) && D=$(( N - $(date -u +%s) )) && { [ ${D#-} -le 5 ] && ok "UTC matches HTTPS time (difference ${D}s)" || warn "UTC differs from HTTPS time by ${D}s"; }
[ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && ok "System clock synchronized: yes" || warn "System clock synchronized: no (cause: $CAUSE; the HTTPS fallback keeps the clock right every 10 min)"
[ "$(systemctl is-active systemd-timesyncd)" = active ] && ok "NTP service active"

say "6. val-admin self-test (sign in on your phone if a link appears)"
OUT=$(runuser -u jim -- ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
       -o ProxyCommand="cloudflared access ssh --hostname %h" jim@val-admin.valiantlux.com true 2>&1)
echo "$OUT" | tail -3 | tee -a "$LOG"
echo "$OUT" | grep -q "Permission denied (publickey" && ok "val-admin public path works (Cloudflare -> Access -> tunnel -> sshd)" || warn "val-admin self-test did not reach sshd"

say "DONE — log: $LOG"
echo "  Tell Claude the PASS/WARN lines from steps 2, 3, 5 and 6."
