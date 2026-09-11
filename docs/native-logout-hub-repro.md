# Native logout / Hub session reproduction

Run from the repository root:

```sh
npm run test:e2e:logout-reopen
```

Requires Docker, Xcode with an iPhone 17 simulator, installed npm dependencies,
and the sibling `../supertokens-rownd-hub` checkout with its dependencies installed.
Set `IOS_LOCAL_HUB_REPO` to use a different Hub checkout. The runner builds that
Hub, starts the backend/Core harness, runs the focused XCUITest, and stops the
services afterward.

Test: `RowndRealHubAuthenticationUITests.testNativeLogoutReopensRealHubWithoutStaleSessionRetryAndCanSignInAgain`

1. Sign in through the real Hub using an email OTP captured by the test backend.
2. Tap the example app's native **Sign out** button (`Rownd.signOut()`).
3. Wait for native sign-out and backend revocation, then tap **Open Rownd auth UI**
   (`Rownd.requestSignIn()`, equivalent to a customer's **Get started** button).
4. Require the email form on the first open, with no credentialed refresh, migration, or
   passwordless authentication requests before user interaction. Check native
   state stays signed out and no extra sign-in completion occurs.
5. Sign in again in that same Hub presentation. Require exactly one additional
   completion, a new session for the same user, and a successful protected request.

The test deliberately does not relaunch, reconfigure, clear website data, or
retry opening the Hub between logout and the next sign-in. Request counters catch
a credentialed stale-session refresh even if the Hub recovers before UI assertions run.
A fresh WebView can make a tokenless refresh probe to discover an HttpOnly session;
the test permits no more probes than the isolated signed-out startup made. The
existing two-second backend observation endpoint provides a bounded idle window;
this does not prove the absence of retries scheduled beyond that window.

In `v0.1.15`, `HubWebsiteDataCleaner.clear` is called only from `Rownd.configure`
when new-installation preparation cleared a SuperTokens session. Native
`performLocalSignOut` clears the native session and dispatches signed-out state,
but does not call the Hub cleaner. This supports the reported cause; reproducing
the exact visible loop also depends on Hub behavior. The runner tests the current
SDK and local Hub checkouts, not a downloaded `0.1.15` release or the deployed Hub.

On failure, inspect the Xcode test result bundle, including the
**Native logout Hub reopen requests** attachment when the test reaches the request
assertions.

## Observed reproduction

On September 10, 2026, the iPhone 17 simulator run completed the initial OTP login
and native logout, then failed on the first Hub reopen:

- No email form appeared.
- Native state changed back to `authenticated`, with a session handle present.
- Sign-in completion count increased from `1` to `2` without user authentication.
- Passwordless consume count stayed at `1`; profile requests increased from `2`
  to `7`.

This reproduces stale-session restoration. It does not establish the exact
visible retry/failure/recovery sequence described in the report.

## Fix

All native logout overloads block Hub presentation synchronously, invalidate
pending authentication, dismiss the active Hub, revoke the native session, and
await domain-scoped Hub website-data removal before publishing signed-out state.
Queued Hub presentation resumes after all concurrent logout calls finish.

Dismissed Hub WebViews are invalidated and detached from their message handlers
and owning controller so their JavaScript session cannot be reused. Authentication
already received from a Hub carries an operation permit through native session
installation, state synchronization, and completion; logout invalidates that permit.

The focused command also runs an immediate-reopen variant (`Rownd.signOut()`
followed synchronously by `Rownd.requestSignIn()`) and the existing real
Manage Account logout test.

Validated on September 10, 2026: all three focused E2E tests passed on iPhone 17;
169 unit tests passed across the session bridge, Hub interop, website-data cleaner,
Rownd, native email verification, and Apple sign-up suites on iPhone 17 Pro.
