# iOS Example Backend

Dedicated backend for manually running the iOS example app. This is separate from `test-server/`, which is an integration-test harness and may intentionally mock or override app config.

## Run

Start SuperTokens Core:

```bash
docker run -p 127.0.0.1:3567:3567 supertokens/supertokens-postgresql
```

Create env config:

```bash
cp example-server/.env.example example-server/.env
```

Update `example-server/.env`:

```text
API_DOMAIN=https://your-ngrok-domain.ngrok-free.dev
ALLOWED_ORIGINS=https://staging.supertokens-rownd-hub.pages.dev,http://127.0.0.1:5173,http://localhost:5173
GOOGLE_CLIENT_ID=<Google Web OAuth client ID>
GOOGLE_CLIENT_SECRET=<Google Web OAuth client secret>
GOOGLE_IOS_CLIENT_ID=<Google iOS OAuth client ID>
ROWND_APP_KEY=<local app key>
ROWND_APP_SECRET=<local app secret>
ROWND_MOBILE_CLIENT_DOMAIN=https://staging.supertokens-rownd-hub.pages.dev/
```

Run the backend from the repo root:

```bash
npm run example:server
```

Expose it with ngrok using the same local port:

```bash
ngrok http 3137
```

## iOS App

Set these environment variables on the `rownd_ios_example` scheme:

```text
ROWND_EXAMPLE_API_DOMAIN=https://your-ngrok-domain.ngrok-free.dev
ROWND_EXAMPLE_HUB_BASE_URL=https://staging.supertokens-rownd-hub.pages.dev
ROWND_EXAMPLE_APP_KEY=<local app key>
ROWND_EXAMPLE_API_BASE_PATH=/auth
```

The example app uses Universal Links for Rownd authentication links hosted on `https://staging.supertokens-rownd-hub.pages.dev`.

Google uses the Web OAuth client in the backend and the iOS OAuth client in app config. The iOS OAuth reversed client ID must also be registered in `example/ios-native-Info.plist`.
