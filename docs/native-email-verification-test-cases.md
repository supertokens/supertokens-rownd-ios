# Native Email Verification Test Cases

## Core Invariant

Once native pending email verification begins, the native verification operation owns session replacement. Hub authentication, profile hydration, lifecycle events, navigation, and stale asynchronous work must not replace, clear, or publish state from the initiating session.

Use these names throughout the scenarios:

- **S0**: session that initiated the email update.
- **S1**: replacement session returned after successful email verification.

For every successful verification scenario, assert:

- S1 has a different session handle from S0.
- S0 is revoked and S1 is the only active session.
- The SDK remains authenticated with S1.
- Access-token resolution and a protected API request succeed.
- The edited email is cached and shown as verified.
- No duplicate sign-in completion or sign-out event is emitted.
- Foregrounding and cold relaunch preserve S1 and the edited profile.

## Session Handoff Ordering

### 1. Stale authentication before S1 installation

Deliver Hub authentication for S0 before the verification response installs S1.

Expected: S1 is installed last and remains authoritative.

### 2. Authentication during S1 adoption

Deliver Hub authentication while verification response headers are being adopted locally.

Expected: session adoption is atomic; the final session is S1 and no partial token set is persisted.

### 3. Stale authentication after S1 installation

Install S1, then deliver Hub authentication for S0.

Expected: S0 cannot replace or clear S1. No refresh request is made for S0.

### 4. Authentication after verification URL cleanup

Remove pending-verification query parameters in the same Hub document, then trigger an old asynchronous authentication state update.

Expected: authentication suppression remains active for that document.

### 5. Duplicate authentication messages

Deliver multiple S0 authentication messages from startup recovery, token refresh, and state replay.

Expected: all stale messages are ignored or suppressed and S1 remains current.

### 6. Same-session token rotation

Rotate the S1 access token while replacement-state synchronization is running.

Expected: the rotated token is accepted because its stable session identity remains S1.

## Lifecycle And Navigation

### 7. Background and foreground before verification

Open the verification link, then background and foreground the app before the verification request starts.

Expected: verification starts once and no foreground profile request can invalidate it.

### 8. Background and foreground during replacement

Background and foreground after the server creates S1 but before local synchronization completes.

Expected: S1 remains authoritative and profile hydration is not duplicated destructively.

### 9. Background and foreground during profile hydration

Delay the S1 profile response and cycle the app lifecycle.

Expected: foreground hydration cannot overwrite or clear replacement state.

### 10. Force quit before local S1 persistence

Terminate the app after the server revokes S0 and creates S1 but before local persistence completes.

Expected: relaunch reaches a defined recovery state and never resurrects S0.

### 11. Hub dismissal during verification

Close, swipe-dismiss, or programmatically hide the Hub while verification is running.

Expected: cancellation is handled without publishing stale authentication or partially persisted state.

### 12. Hub navigation during verification

Navigate to another Hub page while verification or replacement synchronization is running.

Expected: stale completion cannot mutate session or UI state after navigation ownership changes.

## Competing User Actions

### 13. Sign out during verification

Sign out after verification begins but before S1 synchronization completes.

Expected: verification completion cannot resurrect either S0 or S1.

### 14. Sign in as another user during verification

Establish a newer session for a different user while the old verification request remains active.

Expected: the stale verification response cannot replace or hydrate the newer user's session.

### 15. Replay the verification link

Open the same verification link twice, concurrently and after successful completion.

Expected: only one replacement succeeds; replay does not alter S1 or clear the verified profile.

## Network And Profile Failures

### 16. Replacement profile unavailable

Return 401, 404, 5xx, timeout, and offline failures while hydrating the S1 profile.

Expected: S1 remains installed. Retry behavior is bounded and identity-aware; stale profile failures cannot sign out S1.

### 17. Verification response delayed or disconnected

Delay response headers, disconnect during response delivery, and retry the link.

Expected: no partial token set is installed and retries have a defined outcome.

### 18. Very slow asynchronous Hub work

Delay Hub startup recovery beyond normal test quiet windows.

Expected: late S0 work remains suppressed regardless of elapsed time.

## Compatibility

### 19. Normal mobile authentication

Exercise OTP, magic-link, OAuth, guest, and existing-session restoration outside pending email verification.

Expected: native authentication messages continue to be delivered normally.

### 20. Browser and unsupported-native verification

Verify email in a browser and in a native container without the native verification bridge.

Expected: existing browser behavior and unsupported-container messaging remain unchanged.

### 21. Version compatibility matrix

Record the exact iOS, Hub, plugin, and Core commit/tag or image digest with every result. Run these combinations; do not substitute `latest` for a recorded version:

| iOS | Hub | Plugin | Core | Required result |
| --- | --- | --- | --- | --- |
| `v0.1.15` | fixed commit | each supported released version | oldest and newest supported versions | Core invariant and normal authentication pass |
| current branch | fixed commit | each supported released version | oldest and newest supported versions | Core invariant and normal authentication pass |
| `v0.1.15`, then current branch | fixed commit | repository HEAD | current supported version | Core invariant passes |
| current branch | pre-fix commit `2146e7ad6f67473d7d5aadab2f94cc5373c5ff0b` | current released version | current supported version | iOS guard prevents stale authentication |
| latest supported pre-`v0.1.15` SDK | fixed commit | current released version | current supported version | pending email change is rejected before email delivery; normal authentication still passes |

Use `.github/workflows/native-email-verification.yml` to test the current iOS branch with a selected Hub ref, published plugin version, and Core image. Run it once per released-plugin/Core pair. The workflow checks the Hub out into a separate directory, installs the public plugin without changing lockfiles, and passes `E2E_CORE_IMAGE` to the harness. Hub checkout still requires the read-only `ROWND_HUB_REPOSITORY_TOKEN` because the Hub repository is private.

For a local Hub checkout, use the E2E commands already documented in `Tests/README.md` and set `IOS_LOCAL_HUB_REPO` to its path. The runner never changes that checkout's ref. Check out the desired Hub ref yourself or use a separate Git worktree. `E2E_CORE_IMAGE=supertokens/supertokens-postgresql:<version>` selects Core without credentials.

Historical iOS refs and repository-head plugins remain manual. Historical refs may not contain the current E2E runner, and the existing local-plugin command replaces installed dependencies. Use isolated clones/worktrees, record their clean starting revisions, and do not run the local-plugin command in a checkout with dependency changes that must be preserved.

Expected: fixed Hub protects existing clients without breaking normal authentication.

### 22. Cached or older Hub

Run the latest iOS SDK against a Hub version without authentication suppression.

Expected: once the iOS route-aware guard is implemented, stale Hub authentication cannot mutate the verification session.

### 23. Android native verification

Repeat session ownership, lifecycle, replay, and stale-authentication scenarios with the Android bridge.

Expected: shared Hub suppression works and Android preserves its replacement session.

## Manual Real-Device Smoke Test

This test requires an externally reachable integration; simulator loopback infrastructure is insufficient.

- Deploy the exact fixed Hub ref under test to the Hub origin used by the app and verification links. A local Hub alone cannot validate Universal Links on a device.
- Deploy the backend with the selected plugin version, or expose it through a stable HTTPS tunnel. Its public `API_DOMAIN` must route to the backend for the entire test and its `/auth` base path must match the app and Hub configuration.
- Connect that backend to the selected reachable Core version. Record the Core image tag or digest and storage mode.
- Configure Hub/app metadata so the Hub origin, public backend/tunnel origin, app key, allowed origins, and mobile client domain all describe the same environment.
- Install a development-signed build whose bundle ID and Associated Domains entitlement match the deployed Hub's valid `apple-app-site-association` entry. Do not modify or commit personal signing settings.
- Confirm the device can open the Hub and backend health endpoint without VPN, localhost, certificate, or tunnel-warning failures. Confirm the tunnel does not rewrite cookies, exposed SuperTokens headers, query parameters, or redirects.
- Use a genuinely new account and perform its first email update. Confirm a real email is delivered and its link contains non-empty `token` and `rowndPendingVerificationId` parameters without recording their values.
- Open the email on the same device. Validate Universal Link handoff first; repeat with the registered custom scheme when that path is supported. Fail the run if the link remains in Safari unexpectedly.
- Verify the core invariant immediately after verification, after a background/foreground cycle, and after a cold relaunch. Also perform one protected API request and one normal sign-out/sign-in cycle.
- Repeat once on an unrestricted fast network and once with a constrained or high-latency network. Use a new account/email for each run so a consumed link or prior pending operation cannot mask the result.
- Record device model, iOS version, app build/ref, Hub ref and deployed URL, backend/plugin ref and public URL, Core version, link type, network condition, and pass/fail. Redact tokens, cookies, API keys, app secrets, and verification-link query values.

A successful manual run validates the real integration but does not replace deterministic ordering tests.
