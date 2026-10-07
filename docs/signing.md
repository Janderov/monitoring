# Signing and Keychain prompts

The app keeps server tokens, SSH and site passwords, the GitHub token and the
admin key record in the login keychain (`KeychainSecrets`). macOS remembers
which app may read a keychain item by the app's code signature. Since macOS
10.12.5 every item also has a *partition list*: for an app signed by an
Apple-issued certificate the partition is `teamid:<Team ID>`, for anything
else (ad hoc or self-signed) it is `cdhash:<hash of this exact build>`.

So with ad hoc signing each update is a new app to Keychain, and macOS asks
for the login password once per item it reads. A self-signed certificate
does not help: it has no Team ID, the partition stays `cdhash:`.

Two things fix it:

1. **One item (always on).** All secrets live in one item, account `vault`
   (`VaultSecrets`), read once per run and cached. After an update an ad hoc
   build asks once instead of once per secret. Items from older versions are
   moved into the vault on first launch (those old items prompt one last
   time) and deleted.

2. **Stable Team ID (optional, no prompts at all).** A free Apple ID gives a
   personal team and an *Apple Development* certificate (valid for a year).
   When the repository has the secrets `MAC_CERT_P12` (the exported .p12,
   base64) and `MAC_CERT_PASSWORD` (its export password), the `app` workflow
   signs with it; without them it signs ad hoc as before. After the first
   update signed this way, choose "Always Allow" once; later updates signed
   with the same team are not asked about.

Creating the certificate (once, on the Mac, needs Xcode):

1. Xcode → Settings → Accounts → "+" → Apple ID, sign in.
2. Select the "(Personal Team)" → Manage Certificates… → "+" → Apple Development.
3. Keychain Access → login → My Certificates → right-click
   "Apple Development: …" → Export… → .p12, set a password.
4. `base64 -i Certificates.p12 | pbcopy`, then GitHub → Settings → Secrets
   and variables → Actions → New repository secret `MAC_CERT_P12` (paste),
   and `MAC_CERT_PASSWORD` (the password).

The certificate expires after a year: repeat these steps and update both
secrets. Never commit the .p12.
