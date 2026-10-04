# TestFlight distribution

HealthMule is archived, signed, and uploaded only by the manual `Upload TestFlight`
GitHub Actions workflow. A developer Mac is not part of the release path.

The workflow, in order:

1. Accepts dispatches from `main` only.
2. Runs the complete iOS and Simulator test suite.
3. Asks Xcode to create or refresh managed signing assets with an App Store
   Connect API key.
4. Archives the iPhone app and embedded Watch app.
5. Uploads the result to App Store Connect.

A successful job means Apple accepted the upload. App Store Connect may still be
processing the build.

## One-time setup

1. Create an App Store Connect team API key under **Users and Access >
   Integrations > App Store Connect API**. Give it enough access to upload
   builds and manage Certificates, Identifiers & Profiles.
2. Download the `.p8` file immediately. Apple offers that download once.
3. Register at least one physical iPhone with the Apple Developer team under
   **Certificates, Identifiers & Profiles > Devices**.

Xcode's automatic archive phase requires a development provisioning profile,
which contains registered device IDs, before the export phase re-signs the
archive for App Store Connect. That device never participates in the CI build or
upload. Apple's [development provisioning profile
guide](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile/)
documents the device requirement.

Configure the `beta` GitHub Environment with this secret:

- `HEALTHMULE_APP_STORE_CONNECT_API_PRIVATE_KEY`: the complete contents of the downloaded
  `.p8` file

Configure these environment variables:

- `HEALTHMULE_APPLE_TEAM_ID`: `54QY62678F`
- `HEALTHMULE_APP_STORE_CONNECT_KEY_ID`: the API key's 10-character key ID
- `HEALTHMULE_APP_STORE_CONNECT_ISSUER_ID`: the issuer UUID shown by App Store Connect
- `HEALTHMULE_GOOGLE_CLIENT_ID`: the iOS OAuth client ID used by HealthMule
- `HEALTHMULE_GOOGLE_REDIRECT_SCHEME`: the reversed-client-ID URL scheme

The Google values are embedded in the signed app and are identifiers, not
client secrets. The Apple private key is the only GitHub secret required. The
workflow writes all generated configuration under the ephemeral runner and
removes it in an `always()` cleanup step.

## Upload a build

Dispatch the workflow from the GitHub Actions page with branch `main`, or run:

```sh
gh workflow run testflight.yml --ref main
gh run watch 123456789 --exit-status
```

- The dispatch command prints the created run URL when GitHub returns it. Use
  the numeric ID from that URL in place of `123456789`.
- If it prints no URL, locate the run with
  `gh run list --workflow testflight.yml --branch main --event workflow_dispatch`.

After the workflow succeeds, open
[App Store Connect](https://appstoreconnect.apple.com/apps), wait for
processing, then assign the build to an internal TestFlight group. External
testing and App Store submission remain explicit App Store Connect steps.

## Security and operational boundary

- The upload job has read-only repository permissions and uses the dedicated
  `beta` Environment.
- The private key is injected only after the full verification gate passes.
- No certificate or provisioning profile is copied from a developer Mac; Xcode
  automatic signing manages them with the API key.
- Workflow reruns receive a distinct numeric build number.
