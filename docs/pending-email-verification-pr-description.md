# Pending Email Verification

## Why

Mobile email-change verification previously ran in the browser, where the initiating native SuperTokens session was unavailable. Pending email changes require the session that started the operation, so browser verification could not complete the change or safely install the replacement session.

## Email Verification Flow

### 1. The user starts an email change

Hub sends the profile update through `PUT /plugin/rownd/user` or `PUT /plugin/rownd/user/field?field=email`.

The request includes routing context such as `rowndDisplayContext` and `rowndClientDomain`. Native SDKs that support this flow also advertise `rowndNativeEmailVerification: true`.

The plugin rejects unsupported mobile SDKs before creating pending state or sending an unusable email.

### 2. The plugin creates a pending email change

The plugin validates the initiating session, target email ownership, tenant, account type, and configured email sign-in methods. It updates the account's sole existing Passwordless method, including phone-only methods, or creates and links a tenant-local Passwordless method for an account containing only real third-party methods. Guest, instant, ambiguous, and unsupported mixed-method accounts return HTTP 409.

It records the target email, initiating session handle, verification recipe user, tenant, purpose, and a generated `pendingVerificationId`. The existing email remains active until verification completes.

### 3. SuperTokens creates its normal verification token

The plugin calls the standard SuperTokens EmailVerification recipe. SuperTokens Core creates its opaque, single-use email-verification token for the target recipe user and email.

This token remains the proof that the user opened the email. It is not an access token or session token.

### 4. The plugin creates the verification link

The email-delivery override places the raw, non-empty SuperTokens EmailVerification token in the link's `token` parameter. The link also contains `rowndPendingVerificationId`, `apiDomain`, and `apiBasePath`. The pending ID identifies the operation, while the API values provide routing context; they are not additional verification credentials.

The plugin does not encrypt, decrypt, or wrap this token. It has no cryptography or encryption-key configuration and does not use `rowndAppSecret` for token handling.

### 5. The user opens the link

Browser links continue through the regular Hub verification page.

Mobile-originated links return the user to the app through Universal Links, App Links, or the configured custom scheme. The native SDK maps the link onto the trusted Hub URL while preserving its verification parameters.

### 6. Hub selects browser or native verification

In a normal browser, Hub calls the SuperTokens verification endpoint directly and forwards `rowndPendingVerificationId`.

In a supported native container, Hub sends a credential-free request:

```json
{
  "type": "verify_email",
  "payload": {
    "request_id": "<correlation id>"
  }
}
```

Native derives the verification data from the currently loaded, validated URL. Older native SDKs show an upgrade-required error instead of entering a broken browser/app loop.

### 7. Native performs the authenticated request

iOS and Android validate the Hub origin, page path, query cardinality, configured API origin, API base path, and HTTPS transport.

Native then sends:

```http
POST {apiDomain}{apiBasePath}/user/email/verify
    ?rowndPendingVerificationId=<pending id>

{
  "method": "token",
  "token": "<SuperTokens EmailVerification token>"
}
```

The request goes through the native SuperTokens networking interceptor. The initiating native session authorizes the request without exposing its access token to WebView JavaScript.

### 8. The plugin validates and completes the operation

The plugin requires:

- A non-empty SuperTokens EmailVerification token and `rowndPendingVerificationId`.
- The active session to belong to the same user and tenant.
- The active session handle to match the session that initiated the change.
- The pending operation to remain active with a supported purpose.

Only after these correlation and session checks does the plugin pass the raw token to SuperTokens. After Core consumes it, the plugin checks the returned email and recipe user against pending state, rechecks ownership and account shape, and then applies the change.

For an existing Passwordless method, SuperTokens verifies that recipe user and the plugin updates it. For a third-party-only account, the initiating third-party recipe user is the verification subject because the Passwordless method does not exist yet; after proof, the plugin may promote that account to a primary user, creates and links a new tenant-local Passwordless method, and leaves the provider identity unchanged. The replacement session continues to use the initiating recipe user.

The plugin revokes existing account sessions, updates Rownd compatibility metadata, and creates a replacement session for the initiating client. If replacement-session creation fails, it attempts to roll back the credential, verification, and metadata changes and leaves all old sessions revoked. A failed compensation is reported as requiring account reconciliation.

### 9. Native adopts the replacement session

SuperTokens' native interceptor processes the replacement session headers.

The SDK requires the access token to change and requires valid refresh and front tokens before reporting success. It then synchronizes Rownd auth state and emits a credential-free `rownd:native-email-verification` result event.

Hub renders the result and closes the native view only after session adoption succeeds.

## Plugin Files

- `packages/rownd-nodejs/README.md`: Documents pending email changes, native capability requirements, raw EmailVerification token semantics, exact-session binding, Passwordless-method eligibility, and metadata concurrency limitations.
- `packages/rownd-nodejs/src/constants.ts`: Defines the shared pending-verification query parameter and unsupported-native-SDK error message.
- `packages/rownd-nodejs/src/plugin.ts`: Adds pending operation context to generated verification links, preserves ordinary verification, completes pending changes, and creates replacement sessions.
- `packages/rownd-nodejs/src/pluginImplementation.ts`: Applies email-change validation to both profile-update endpoints, sanitizes client context, gates native capability, validates session age, and starts the pending operation.
- `packages/rownd-nodejs/src/supertokens-repository.ts`: Implements pending state, session binding, ownership checks, Passwordless-method eligibility, credential updates, session revocation, rollback, cleanup, and concurrency behavior.
- `packages/rownd-nodejs/src/types.ts`: Types the accepted email-change request context. Pending metadata contains no token material.
- `packages/rownd-nodejs/src/utils.ts`: Gives the field-level update endpoint the same validated context handling as the full profile update.
- `packages/rownd-nodejs/src/plugin.test.ts`: Covers both routes, capability gating, Passwordless-method eligibility, ordinary verification, missing tokens and markers, exact-session enforcement, session replacement, replay, duplicate requests, ownership conflicts, rollback, cleanup failures, crash recovery, and superseding operations.

## Hub Files

- `src/scripts/Components/EmailVerificationPage/EmailVerificationPage.tsx`: Chooses browser verification, native delegation, external-browser handoff, or unsupported-native messaging. It adopts complete browser replacement sessions and waits for native adoption before closing.
- `src/scripts/utils/mobile-app.ts`: Defines mobile deep-link construction, explicit native verification capability detection, and the correlated credential-free native RPC.
- `src/scripts/utils/supertokens.ts`: Defines the pending marker, advertises native support only when explicitly enabled, and removes completed verification parameters.
- `src/scripts/Context.tsx`: Treats changes to access, refresh, front, or anti-CSRF tokens as native session changes.
- `src/scripts/Login.tsx`: Reuses shared mobile deep-link generation.
- `public/static/locales/en.json`: Adds English unsupported-native upgrade copy and adjacent cross-device strings.
- `public/static/locales/es.json`: Adds Spanish unsupported-native upgrade copy and adjacent cross-device strings.
- `docs/pending-email-verification-protocol.md`: Documents the cross-repository protocol, security boundaries, rollout, and credential ownership.
- `package.json`: Adds the focused cross-repository pending-email integration command.
- `test/globals.d.ts`: Types the native verification capability marker.
- `test/e2e/harness/supertokens-harness.ts`: Adds authenticated account inspection for final-state assertions.
- `test/e2e/helpers/common.ts`: Mocks capability advertisement and credential-free native verification responses.
- `test/e2e/user.spec.ts`: Tests browser and mobile links, native delegation, replacement sessions, persistence, and final account state.
- `test/unit/scripts/Components/EmailVerificationPage/EmailVerificationPage.test.tsx`: Covers browser, native, unsupported-client, error, redirect, cancellation, and duplicate-request behavior.
- `test/unit/scripts/utils/mobile-app.test.ts`: Covers capability detection, request correlation, minimal payloads, stale events, errors, timeout, abort, and deep-link generation.
- `test/unit/scripts/utils/supertokens.test.ts`: Covers conditional capability advertisement.
- `test/unit/scripts/Context.test.tsx`: Covers complete replacement-session propagation.
- `test/unit/scripts/Login.test.tsx`: Updates mocks for shared deep-link construction.

## iOS Files

- `Sources/Rownd/Models/RowndHubInteropMessage.swift`: Decodes the credential-free `verify_email` message and request ID.
- `Sources/Rownd/Rownd.swift`: Makes Hub page selection deterministic before presentation, isolates presentation on the main actor, and redacts deep-link logs.
- `Sources/Rownd/Views/HubViewController.swift`: Handles cold- and warm-launch deep links without consuming or replacing the pending URL incorrectly.
- `Sources/Rownd/Views/HubWebView/HubWebViewController.swift`: Implements capability injection, trusted message handling, URL and transport validation, native requests, replacement-session validation, result events, cancellation, and navigation invalidation.
- `Sources/Rownd/framework/SmartLinks.swift`: Maps verification links onto the trusted Hub origin, preserves parameters, redacts logs, and permits retries.
- `Sources/Rownd/framework/DeepLinkHandlerModifier.swift`: Redacts custom-link and Universal Link logs.
- `Sources/Rownd/framework/Redact.swift`: Removes URL query and fragment values from logs and redacts additional SuperTokens credential fields.
- `Sources/Rownd/framework/SuperTokensSessionBridge.swift`: Reports whether SuperTokens state was synchronized into Rownd state.
- `Sources/Rownd/framework/LegacySessionMigrator.swift`: Adapts migration to the synchronization method's Boolean result.
- `Tests/RowndTests/NativeEmailVerificationTests.swift`: Covers capability injection, message decoding, trusted origins, parameters, HTTPS, request shape, interception, replacement sessions, cancellation, and response correlation.
- `Tests/RowndTests/SmartLinksTests.swift`: Covers parameter preservation, absence of session credentials, and link retries.
- `Tests/RowndIntegrationTests/SuperTokensSessionIntegrationTests.swift`: Uses generated links and verifies initiating-session authorization and replacement-session creation.
- `example/ios native/AppDelegate.swift`: Routes E2E verification through smart links and exposes the active session handle.
- `example/rownd_ios_exampleUITests/RowndManageAccountEmailUITests.swift`: Tests the complete app flow, pending marker, replacement headers, session rotation, updated email, and relaunch persistence.
- `test-server/server.ts`: Captures pending markers and replacement-session headers.
- `package.json`: Rebuilds and installs the local plugin before iOS E2E tests.
- `rownd.xcworkspace/xcshareddata/swiftpm/Package.resolved`: Updates SuperTokens iOS to the version required for reliable replacement-session adoption.

## Android Files

- `android/src/main/java/io/rownd/android/Rownd.kt`: Exposes the authenticated API client used by native verification.
- `android/src/main/java/io/rownd/android/models/RowndHubInteropMessage.kt`: Adds the `verify_email` message and typed payload.
- `android/src/main/java/io/rownd/android/models/network/SignInLink.kt`: Maps links to the trusted Hub origin, preserves parameters, and prevents stale intent replay without blocking retries.
- `android/src/main/java/io/rownd/android/util/NativeEmailVerification.kt`: Validates the current URL and API destination, builds the request, disables retries, applies timeout, and validates the response.
- `android/src/main/java/io/rownd/android/views/RowndWebView.kt`: Adds trusted WebMessage handling, capability injection, secure/legacy separation, verification orchestration, session validation, result delivery, and cancellation.
- `android/src/main/java/io/rownd/android/views/HubComposableBottomSheet.kt`: Invalidates verification work before dismissal.
- `android/src/main/java/io/rownd/android/util/SuperTokensSessionBridge.kt`: Reports whether adopted SuperTokens state was synchronized into Rownd state.
- `android/src/main/java/io/rownd/android/util/Redact.kt`: Redacts verification and session credentials from logs.
- `android/src/test/java/io/rownd/android/NativeEmailVerificationTest.kt`: Covers message parsing, origins, duplicate parameters, HTTPS, API matching, request construction, and logging.

## Rollout

Release the components in this order:

1. Hub capability detection and native RPC support.
2. iOS and Android SDKs that advertise and implement native verification.
3. Plugin capability enforcement.

Once plugin enforcement is enabled, older mobile SDKs receive HTTP 426 before an email change starts rather than receiving a link they cannot complete.

## Verification

- Plugin: 187 tests passed.
- Hub browser/mobile integration: 2 tests passed.
- Hub unit tests and type checks passed.
- iOS focused native verification and smart-link tests passed. Local-plugin integration, example E2E, and manage-account UI E2E await completion of the plugin task.
- Android unit suite passed.
- Lint, builds, and `git diff --check` passed.

## Unrelated Worktree Changes

Exclude or review these separately:

- Hub `Dockerfile`, `README.md`, `docs/app-config.md`, and `findings.md`.
- Hub `public/.well-known/**` association-file changes.
- Android `.gitignore`, `.idea/**`, `.kotlin/**`, and `LICENSE`.
- iOS `docs/hub-session-adoption-fix-plan.md` and `docs/supertokens-migration-follow-up-plan.md`.
- Plugin `ROWND_OIDC_SUPERTOKENS_IMPLEMENTATION_PLAN.md`.
