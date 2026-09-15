# Google OAuth and Drive setup

HealthMule uses GoogleSignIn 9.x for native iOS OAuth and calls Google Drive
API v3 directly. It requests only:

```text
https://www.googleapis.com/auth/drive.file
```

The scope lets the app create and manage the files it created or that the user
explicitly opened or shared with it. It does not grant unrestricted access to
Drive. Google classifies `drive.file` as a non-sensitive, per-file scope; see
[Choose Google Drive API
scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth).

## Create the Google configuration

1. Create or select a Google Cloud project.
2. Enable **Google Drive API** for the project.
3. Configure the Google Auth Platform consent screen and declare
   `https://www.googleapis.com/auth/drive.file` under data access.
4. If the app is External and still in Testing, add the Google account that will
   run the app as a test user.
5. Create an OAuth client with application type **iOS**.
6. Set its bundle ID to the app’s current `HEALTHMULE_BUNDLE_IDENTIFIER`.
   The clean-checkout default is `dev.uinaf.healthmule`; signed local builds
   can override it in the ignored `Config/Signing.xcconfig`.
7. Record the iOS client ID and its reversed-client-ID URL scheme.

A backend client ID is unnecessary because HealthMule has no backend. A native
iOS app cannot keep a client secret confidential, so do not add a web client
secret to the project. Google’s [iOS integration
guide](https://developers.google.com/identity/sign-in/ios/start-integrating)
describes the iOS client and reversed URL scheme.

## Configure the checkout

Create the ignored local configuration:

```sh
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
```

Set both values:

```text
HEALTHMULE_GOOGLE_CLIENT_ID = 123456789-example.apps.googleusercontent.com
HEALTHMULE_GOOGLE_REDIRECT_SCHEME = com.googleusercontent.apps.123456789-example
```

The URL scheme is the client ID’s dot-separated prefix in reverse-domain form,
as shown by Google Cloud Console. Do not include `https://`, a path, or a trailing
slash. The app accepts the configuration only when this scheme exactly equals
`com.googleusercontent.apps.<client-id-prefix>` for the configured client ID.

`Config/App.xcconfig` includes this file optionally, so a clean checkout still
builds and tests with an intentionally unconfigured Google state. The real
`Config/Secrets.xcconfig` is ignored by Git. Device-signing values are likewise
kept in ignored `Config/Signing.xcconfig`; its bundle identifier must match this
Google iOS client.

Generate the project after changing checked-in project configuration:

```sh
make project
```

The package declaration in `project.yml` pins GoogleSignIn to an exact version
and includes both `GoogleSignIn` and `GoogleSignInSwift`. The shared Xcode
workspace lock resolves the same version and records its transitive
dependencies. Treat `project.yml` as the source of truth for the current pin.

## OAuth publishing status

An External Google OAuth app left in **Testing** receives refresh tokens that
expire after seven days when it requests scopes beyond basic profile identity.
`drive.file` therefore makes weekly reauthorization likely during development.
Google documents this in [OAuth refresh-token
expiration](https://developers.google.com/identity/protocols/oauth2#expiration).

For durable unattended sync, move the OAuth app to **In production** and complete
any basic verification the Google console requires. Keeping it in Testing is
acceptable while developing, but the app must treat token expiry as a normal
Reconnect state rather than as data loss.

## Runtime flow

The current app performs these steps:

1. `GoogleAuthService.connect()` presents GoogleSignIn and requests
   `drive.file` as an additional scope.
2. On launch, `restorePreviousSignIn()` restores GoogleSignIn’s Keychain-backed
   state and verifies that `drive.file` remains granted. A revoked grant enters
   Reconnect; an offline or temporarily unavailable token service keeps the
   connection recoverable and is retried on activation or by Try Again.
3. Before each Drive request, `refreshTokensIfNeeded()` obtains a current access
   token and verifies the stable account ID both before and after the
   suspension. A concurrent account change is retryable and can never lend the
   new account’s token to an older request.
4. `DriveAPIClient.ensureAppFolders(for:)` creates or recovers folders for the
   stable Google user ID returned by GoogleSignIn:

   ```text
   Apple Health Sync/
   └── daily/
   ```

5. Drive IDs are cached in a separate account namespace whose key is the
   SHA-256 digest of that stable user ID. Private `appProperties` identify the
   root, daily folder, manifest, and dated records independently of their
   names. Legacy unscoped metadata is ignored and safely rediscovered.
6. Before a different account or replacement folder tree can sync, the app
   atomically marks every local daily artifact pending for that destination,
   clears the prior destination’s manifest completion state and last-successful
   timestamp, and persists only a SHA-256 digest of account, root-folder, and
   daily-folder identity.
7. File creation uses a Drive-generated ID so retrying an ambiguous create
   cannot create a second logical file. Existing files update by ID with a
   multipart `PATCH`.
8. Disconnect calls GoogleSignIn’s `disconnect()`, which revokes access and
   signs out. It does not delete the user’s Drive folder or files.

The UI reports **Connected** only after OAuth scope, stable account identity,
and managed-folder recovery all succeed. OAuth-only setup is shown as finishing
Drive setup; a failed folder check is shown as Drive unavailable. Neither state
can start reconciliation or manual sync.

- A cached folder is accepted only when Drive reports a non-trashed folder MIME
  type.
- The cached `daily` folder must also remain a child of the verified root.
- Folder discovery runs during Drive setup. Artifact uploads use the activated
  folder IDs and do not re-fetch those folders per file.
- Deleted, trashed, or incoherent folder trees are recreated, stale per-file IDs
  are discarded atomically, and the new tree receives a full local republish.

Changing accounts never inherits the previous account’s “Up to date” state.
The new destination receives the complete local daily snapshot followed by a
fresh manifest. Switching back is safe: the app republishes through that
account’s cached immutable Drive IDs instead of creating duplicate logical
files.

GoogleSignIn owns OAuth credential persistence in Keychain. The app stores only
account-namespaced folder and file IDs in `DriveMetadataStore`; the stable user
ID is hashed for the namespace key and is never logged. It must never persist or
log access or refresh tokens itself. See Google’s [iOS API access
guide](https://developers.google.com/identity/sign-in/ios/api-access) and
[disconnect guidance](https://developers.google.com/identity/sign-in/ios/disconnect).

## Current Drive boundary

Folder creation and multipart create/update requests are implemented.

- `DriveArtifactDestination` connects `DriveAPIClient` to the core
  `ExportArtifactDestination`. It maps dated daily artifacts and the manifest to
  their managed folders, then translates Drive failures into the core retry
  classifications.
- `AppModel` constructs that destination through `LiveSyncCoordinator`, so
  foreground reconciliation can stage and upload daily records followed by the
  manifest.
- The session split, destination draining, FIFO reservation order, and the
  15-second upload observation window are documented once in
  [Drive transport](ARCHITECTURE.md#drive-transport).
- Interruption and relaunch acceptance still need a configured OAuth client, a
  real Drive account, and a physical device. Use the
  [physical-device checklist](DEVICE_TESTING.md).

### Error classification

| Failure | Classification |
|---|---|
| First background upload `401` | Retried once after another token refresh, because its bearer token may have expired while the system waited to transfer it |
| Repeated Drive `401`, immediate metadata-request `401`, OAuth token-endpoint grant failure | Reauthorization required; the app returns to Reconnect while keeping staged work |
| Network or server failure while refreshing a token | Transient |
| Stable-account mismatch during token refresh | Transient, never a reauthorization failure |
| `408`, `429`, `5xx` | Transient |
| Drive `403` reasons `backendError`, `rateLimitExceeded`, `userRateLimitExceeded` | Transient |
| Any other HTTP failure | Non-retryable |

The destination feeds these classifications into the durable core retry queue,
which applies transient backoff and preserves blocked reauthorization or
permanent-failure states.

- Restoring valid credentials explicitly resumes persisted reauthorization
  blocks, including after an interrupted sign-in and process relaunch.
- Non-retryable failures stay visible as blocked work and are not advertised as
  eligible for Retry.

## Troubleshooting

### Google is “Not configured”

Confirm that both values in `Config/Secrets.xcconfig` are non-placeholder values,
then run `make project` and rebuild.

### Redirect or sign-in fails

Confirm all three values describe the same iOS client:

- Google Cloud client bundle ID: the resolved
  `HEALTHMULE_BUNDLE_IDENTIFIER`
- `HEALTHMULE_GOOGLE_CLIENT_ID`
- `HEALTHMULE_GOOGLE_REDIRECT_SCHEME`

Also confirm that the Drive API is enabled in the same Google Cloud project.

### Drive access was not granted

The app verifies the returned scope list. Use Reconnect and grant
`drive.file`; do not replace it with a broader Drive scope.

### Reconnect is required after about one week

Check the OAuth app’s publishing status. Seven-day refresh tokens are expected
for External apps in Testing.

### Restore fails while offline

The app keeps a temporary-unavailable state rather than asking for a new grant.
Bring the device online and use Try Again, or foreground the app to let the
bootstrap path retry. Pending local records remain in the durable queue.

### Google is authorized but Drive is unavailable

OAuth completed, but the managed-folder check failed. Use Try Drive Again after
connectivity and the Drive API configuration have been checked. The app remains
unable to sync until it verifies the managed root and `daily` folders; it does
not treat OAuth alone as Connected.

### The folder was moved

Drive file IDs remain stable when names or locations change. The app continues
by cached folder ID, and Reset Local Sync State intentionally preserves the
managed folder and file IDs so a moved export tree is not duplicated.

If the managed root or `daily` folder was deleted, trashed, or replaced, use Try
Drive Again. HealthMule verifies the new coherent tree, clears stale file-ID
cache entries, and republishes all locally staged days plus a fresh manifest.

Reset clears the local staged manifest and records, then rebuilds the currently
selected date range. It never deletes older Drive files; files outside the
rebuilt range can remain in the folder without appearing in the new manifest.

## Upstream references

- [GoogleSignIn for iOS setup](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Calling Google APIs from iOS](https://developers.google.com/identity/sign-in/ios/api-access)
- [Drive `drive.file` scope](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
- [Creating Drive folders](https://developers.google.com/workspace/drive/api/guides/folder)
- [Drive multipart uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads)
- [Drive API error handling](https://developers.google.com/workspace/drive/api/guides/handle-errors)
