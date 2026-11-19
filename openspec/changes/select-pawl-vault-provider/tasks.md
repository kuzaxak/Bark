# Tasks

## 1. Browser settings and startup

- [x] 1.1 Route Profiles password management to the running provider and distinguish refusal, lock and unavailability in Privacy. Exercise both profile routes and a pending provider change.
- [ ] 1.2 Publish the saved choice before Chromium starts and hold it for the process lifetime in the native vault service. Verify against both the pinned consumer SDK and a provider-capable engine, including a disposable verification launch.
  The signed vault walk requires the launch-time selection and connected Pawl status for official qualification. The signed Intel app on the older SDK showed the compatibility notice and failed this check as expected. A run with the provider-capable SDK remains pending.

## 2. Signed Pawl client

- [ ] 2.1 Admit the signed Bark identifier on the authorized Apple team alongside the legacy Nook client. Derive consent labels from the verified peer. Check signed Bark and Nook acceptance, same-team wrong identifiers, and ad hoc client rejection.
  macOS evaluated the proposed requirement against genuine signed Bark and Nook. Both matched. A different signed app on the same team and an ad hoc executable with Bark's identifier were refused. Pawl build 7 still enforces its original requirement; the companion update and live socket checks remain open.
- [ ] 2.2 Verify the shipped sandbox and socket with a separately signed Bark and Pawl using a disposable database. Exercise a locked vault and denied owner approval.

## 3. Chromium passwords

- [ ] 3.1 Separate parsing and validated submissions from stock credential delivery. Seed distinct synthetic matching logins and verify only the selected manager fills, auto-signs in, suggests, generates or writes, including when Pawl is closed and before a tab is attached.
  Both signed Intel walks on the pinned SDK inspected Chromium's profile and account login databases after quit. The conditional provider created and updated an account, and the legacy provider offered manual management. All Chromium login stores had zero rows in both disposable runs. The seeded Chromium credential and disconnected-provider checks still require the exclusive engine.
- [ ] 3.2 Preserve native field, frame, origin and profile checks. Verify scripted focus alone cannot open the chooser, genuine keyboard and mouse input can, and a stale pane or private session cannot receive a late write.
  The engine candidate binds mouse or Tab focus to the document and field. A native Down Arrow on that field reopens the picker. The gesture and cross-frame regressions still need a run with that engine.
- [ ] 3.3 Add a safely targeted password update with owner approval and explicit old-provider handling. Verify two matching usernames, a concurrent edit and a redirect, and check both stores after cancellation and success.
  Bark implements conditional creates and updates after consent. A v1 companion offers manual management for new and existing accounts. The in-memory provider exercises expiry, conflicts and replay. Signed companion persistence and the joint two-store qualification remain open.
- [ ] 3.4 Prove stock mode still works and unrelated address and payment Autofill retain their behavior in both modes. Run the pinned engine browser tests and a signed shell walk.

- [ ] 3.5 Route direct password-manager URLs and any remaining context-menu actions to the running provider. Verify an existing Chromium login cannot be offered through those entry points.
  In exclusive mode, submitting a password-manager URL from Bark's address bar or command palette opens Privacy settings. The palette labels the destination before the user presses Return. The shell regression covers both Chromium URL spellings, provider modes, search and placement overrides, and a window change during dismissal. The engine candidate filters password context-menu commands, gives other navigations directions to Bark's settings, and gates the private password API. The signed exclusive-provider walk now exercises the typed command. Running it and the linked engine checks remains open.

## 4. Passkeys and qualification

- [ ] 4.1 Isolate browser-managed passkey suggestions from Pawl in Pawl mode. Verify a disposable relying party accepts a signed modal assertion and that separately chosen hardware security keys work.
  On the pinned Intel SDK, the signed app opened the Pawl account picker for a discoverable modal request. After account selection the disposable vault signed once. The loopback site verified the signature, challenge, origin, RP hash, presence and verification flags, credential ID and user handle. The exclusive engine, installed companion and physical security key still need qualification.
- [ ] 4.2 Qualify conditional passkeys on Chromium before claiming parity with WebKit. Verify account suggestions, opt-out, cancellation and navigation using a disposable relying party.
- [ ] 4.3 Pass the unchanged upstream patch budget and qualify a signed pair on Intel and Apple Silicon with password, OTP and passkey flows, and promote the matching SDK receipts through the tracked recipe after results pass.
  Signed Intel Bark with the pinned SDK and an in-memory provider updated one existing account, created another and filled both from fresh documents. The legacy-provider walk offered manual management for both submissions and recorded zero write attempts. The checked-provider walk also filled a code, cancelled a passkey request and exercised the connected provider’s management button. The signed companion and provider-capable engine still need joint qualification.
