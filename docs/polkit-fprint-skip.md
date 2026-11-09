# Polkit: typing skips the fingerprint step

**Problem.** `/etc/pam.d/polkit-1` runs `pam_fprintd` first (3 tries × 10 s). With the
reader out of reach, a password typed into the DMS dialog sat queued for about 30 s.

**Flow**
1. The DMS dialog (patch `home/.local/bin/dms-polkit-fprint-skip-patch`, applied by
   `dms-shell-sync`) touches `/run/polkit-fprint-skip/<uid>` on the first keystroke
   while the fingerprint step is still running.
2. `polkit-fprint-skip.path` (root) → `polkit-fprint-skip.service` →
   `/usr/local/sbin/polkit-fprint-skip-kick` stops the `polkit-agent-helper@*-<uid>`
   units that started before the flag was touched.
3. Quickshell sees the session fail and immediately starts a new one. The dialog
   swallows that "failure", so no red field appears.
4. Line 1 of `/etc/pam.d/polkit-1`: `pam_exec /usr/local/sbin/polkit-fprint-skip-check`
   succeeds while the flag is fresh (≤ 120 s, owned by that uid) and jumps over
   `pam_fprintd`, so the password prompt appears at once.
5. The dialog removes the flag when it closes.

**Security.** This only skips the choice of factor; the password is still required.
A user can only stop helpers whose socket peer is their own uid.

**Files:** `root/usr/local/sbin/polkit-fprint-skip-{check,kick}`,
`root/etc/systemd/system/polkit-fprint-skip.{path,service}`,
`root/etc/tmpfiles.d/polkit-fprint-skip.conf`, `root/etc/pam.d/polkit-1`.

**Debug:** `journalctl -u polkit-fprint-skip.service -u 'polkit-agent-helper@*'`

**Revert:** restore `/etc/pam.d/polkit-1` from its `.bak-*`,
`systemctl disable --now polkit-fprint-skip.path`, delete the files above, and drop
the patch from the `dms-shell-sync` loop.
