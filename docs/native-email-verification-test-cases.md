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

Test the fixed Hub with iOS 0.1.15, the latest iOS SDK, supported older SDKs, released and repository-head plugins, and supported Core versions.

Expected: fixed Hub protects existing clients without breaking normal authentication.

### 22. Cached or older Hub

Run the latest iOS SDK against a Hub version without authentication suppression.

Expected: once the iOS route-aware guard is implemented, stale Hub authentication cannot mutate the verification session.

### 23. Android native verification

Repeat session ownership, lifecycle, replay, and stale-authentication scenarios with the Android bridge.

Expected: shared Hub suppression works and Android preserves its replacement session.

## Manual Real-Device Smoke Test

Use a genuinely new account and perform its first email update. Open the real verification email on the device and return to the app through the configured universal link or custom scheme. Verify the core invariant immediately after verification, after a background/foreground cycle, and after a cold relaunch.

Because production timing is uncontrolled, repeat the smoke test across fast and slow networks. A successful manual run validates the real integration but does not replace deterministic ordering tests.
