# iOS daily-login investigation

## Finding

An expired access token refreshes successfully against Core. A temporary refresh HTTP 503, however, caused the Rownd SDK to persist a signed-out state at startup while the native refresh token remained usable. This is an SDK failure path consistent with reopening an app after overnight inactivity; it does not establish that every customer report has the same cause.

The reproduction used this checkout (based on `e011174`, with existing local migration changes), SuperTokensIOS 0.5.4, Core `supertokens/supertokens-postgresql:12.0.10`, `supertokens-node` 24.0.2, and Rownd's Node plugin 0.7.2.

## Failure mechanism

1. The app starts with a persisted Rownd identity and an expired native access token.
2. `SuperTokens.getAccessToken()` calls `doesSessionExist()`, which attempts refresh when the front token has expired.
3. On a refresh API/network error, `doesSessionExist()` returns `false`; `getAccessToken()` returns `nil`. Native refresh credentials survive a 503.
4. `Rownd.reconcileStartupSession()` previously interpreted the missing usable token as a missing session, cleared auth/profile state, and persisted that logout.
5. `Authenticator.getValidToken()` also interpreted the same `nil` as `noAccessTokenPresent`. The default public `Rownd.getAccessToken()` then returned `nil` rather than reporting a retryable failure.

An hourly access token will normally have expired by the next day's first launch. A temporary refresh failure at that point can therefore appear to the user as a daily logout. No explicit 24-hour logout timer is needed for this failure.

## Changes

- Startup retains cached auth/profile state if refresh failed but the native SDK still has refresh credentials.
- The authenticator reports that unavailable-token condition as `AuthenticationError.serverError`, preserving the public API's distinction between a temporary failure and an absent session.
- A failed proactive refresh within the 60-second safety margin also reports a server error instead of pretending the still-present token is missing.
- A definitive refresh rejection still clears native credentials and the persisted Rownd login. Cached identity never substitutes for a usable access token on protected API calls.

## Reproduction

```sh
npm run test:e2e:refresh
```

Prerequisites and runner configuration are in [Tests/README.md](../Tests/README.md).

The native integration tests use real HTTP requests, Node session middleware, Core, and Postgres. Their native token storage uses the existing in-memory test adapter. Core issues a five-second access token, the test waits for its actual JWT expiry, and subsequent refreshes receive the normal one-hour lifetime. A 30-second fixture exercises proactive refresh before expiry. The baseline normal-refresh and revoked-session tests passed; the HTTP 503 test failed because persisted Rownd auth became empty despite a retained, usable refresh token.

The XCUITests additionally exercise real native credential persistence across process termination. Core issues a 90-second access token (above Rownd's 60-second proactive-refresh margin); the app stays terminated for 91 seconds. Tests cover successful startup refresh and startup during a refresh outage followed by recovery without another login. Both retain the original session handle and successfully call a protected endpoint, then relaunch again to check persistence.

Validation after the fix:

- Focused native refresh suite: three test functions, four scenarios passed.
- Cold-relaunch XCUITests: two passed.
- Authenticator unit tests: 13 passed.
- Session bridge unit tests: 73 passed.
- Harness TypeScript check and `git diff --check`: passed.

The broader native integration run passed 21 of 22 test functions, including all refresh scenarios. Its remaining failure is `migrationWithoutRefreshHeaderDoesNotCreatePartialSession`: it expects legacy credentials to survive a response missing `st-refresh-token`, while the pre-existing local `LegacySessionMigrator.swift` changes clear them through `finishInvalidSession`. That migration expectation needs reconciling separately.

## Core configuration

From the local Core checkout, `src/main/java/io/supertokens/config/CoreConfig.java`:

- `access_token_validity` is in **seconds**: `3600` = 1 hour.
- `refresh_token_validity` is in **minutes**: `144000` = 100 days.
- `getRefreshTokenValidityInMillis()` multiplies by `60 * 1000`.

`session/refreshToken/RefreshToken.java` issues refresh tokens with `now + validity`; `session/Session.java` checks stored session expiry and advances session lifetime during refresh-token rotation. The supplied settings do not impose a daily absolute session limit. The integration fixture also checks Core's stored session expiry against the 100-day lifetime.

## Confirming the customer report

Match the affected app build to its Rownd and SuperTokensIOS versions. For a failed next-day launch, correlate `/auth/session/refresh` with its HTTP status or transport failure. A 5xx/network failure followed by Rownd clearing cached auth matches this reproduction. A 401 instead calls for checking the backend/Core rejection reason, session revocation, and effective configuration for that customer's app. The test uses an accelerated access-token lifetime, not a literal 24-hour device soak.
