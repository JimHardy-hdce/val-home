# val-home

Temporary, one-time bootstrap for the VAL node (valiant-node). **No secrets.**
This repo will be made private or deleted once the admin path is verified.

`h.sh` is plain text. Read it before running it. Run it once, at the node's keyboard:

    sudo sh h.sh

It:
1. saves read-only diagnostics first (nothing restarts);
2. checks SSH is key-only, with no root and no password login;
3. adds the Cloudflare-Access-protected `val-admin.valiantlux.com` route to the existing tunnel, rolling back on failure;
4. grants user `jim` journal reading plus passwordless restart of exactly four VAL services, and proves that other commands are refused;
5. self-tests the public path.

What it contains: commands, hostnames, the "VAL admin" Access AUD tag and an SSH public-key *fingerprint*. None of these are secret. It contains no credentials, keys, tokens or passwords.
