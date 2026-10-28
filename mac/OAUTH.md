# Sign-in with Google, Microsoft 365 and Zoom

People sign in with their usual Google, Microsoft or Zoom account (Settings › Accounts) to see their
upcoming meetings on the Record page and keep the invitees with each recording. For that, whoever
ships the app registers one OAuth app per service, once, and builds its client ID into the app. End
users never see client IDs or redirect URIs, only the service's own sign-in page in their browser.

Sign-in is OAuth 2 authorization code with PKCE. The browser comes back to a one-time listener on
the Mac's loopback address (any port), and the tokens stay in the user's Keychain. Requests go from
the user's Mac straight to Google, Microsoft or Zoom; there's no server of ours in between. Access
is read-only: meeting subjects, times, join links and invitees.

## Where the IDs go

Create `mac/Config/OAuth.local.xcconfig` (it's in `.gitignore`):

```
PMA_GOOGLE_CLIENT_ID = 1234567890-abc.apps.googleusercontent.com
PMA_GOOGLE_CLIENT_SECRET = GOCSPX-…
PMA_MICROSOFT_CLIENT_ID = 00000000-0000-0000-0000-000000000000
PMA_ZOOM_CLIENT_ID = …
PMA_ZOOM_CLIENT_SECRET = …
```

Then `xcodegen generate` and build (or `mac/scripts/release.sh`). `Config/OAuth.xcconfig` includes
the local file, and `project.yml` copies the values into Info.plist. A service left empty isn't
offered in the app, and with all of them empty the Record page's Meeting section is hidden.

"Secrets" here aren't secret: anything shipped in a desktop app can be read out of it. Google and
Zoom still expect one; PKCE is what protects the sign-in. Keep the local file out of the repository
anyway, so forks register their own apps.

Companies that want their own OAuth app (say, an internal Entra app with admin consent) can set
`oauthClientID.<google|microsoft|zoom>` and `oauthClientSecret.<…>` in the app's preferences, for
example with an MDM profile for the domain `dev.ruy.private-meeting-assistant`. They take precedence
over the built-in ones.

## Google (Calendar and Meet)

1. In [Google Cloud Console](https://console.cloud.google.com/), create a project and enable the
   **Google Calendar API**.
2. Google Auth Platform › **Branding**: app name, support email, logo, home page and privacy policy.
   **Audience**: External. **Data access**: add the scopes `openid`, `email`, `profile` and
   `https://www.googleapis.com/auth/calendar.events.readonly`.
3. **Clients** › Create client › **Desktop app**. Copy the client ID and secret into the local
   xcconfig. Desktop clients accept loopback redirects on any port, so there's no redirect URI to add.
4. While the app is in **Testing**, only the test users you list can sign in, and their sign-in
   expires after 7 days. `calendar.events.readonly` is a sensitive scope, so publishing to everyone
   needs Google's verification: a verified domain for the home page and privacy policy, an
   explanation of how the scope is used, and a short demo video of the sign-in and the feature.

## Microsoft 365 (Outlook calendar and Teams)

1. In [Microsoft Entra admin center](https://entra.microsoft.com/) › App registrations › **New
   registration**. Supported account types: **Accounts in any organizational directory** (add
   personal Microsoft accounts too if you want outlook.com calendars; Teams meeting lookups only work
   for work and school accounts).
2. **Authentication** › Add a platform › **Mobile and desktop applications**, redirect URI
   `http://localhost`. Microsoft ignores the port for localhost.
3. **API permissions** › Microsoft Graph › Delegated: `User.Read`, `Calendars.Read`,
   `OnlineMeetings.Read` (`offline_access` is requested at sign-in).
4. Copy the **Application (client) ID** into the local xcconfig. No secret: the app is a public client.
5. For people in other organizations to consent on their own, complete **publisher verification**
   (a Microsoft Partner Network ID linked to the app). Many organizations still require an
   administrator to approve new apps; their admin can grant consent for everyone once.

## Zoom

1. In the [Zoom App Marketplace](https://marketplace.zoom.us/) › Develop › Build App › **General
   App**, managed by the **user**.
2. OAuth redirect URL and allow list: `http://127.0.0.1/callback`. Zoom ignores the port for
   loopback addresses.
3. Scopes: `user:read:user`, `meeting:read:list_meetings`, `meeting:read:meeting`.
4. Copy the client ID and secret (production, not development) into the local xcconfig.
5. Until the app is published, only users in your own Zoom account can sign in. To open it to
   everyone, submit it for Marketplace review (app listing, privacy policy, scope justifications and
   a test plan).

## Checking it

Build, open Settings › Accounts, and sign in to each service. The Record page should then list
today's and tomorrow's meetings, and pasting a Meet, Zoom or Teams link should find the meeting.
Sign-in failures are shown under the service in Settings (for example a redirect URI that doesn't
match, or a missing scope).
