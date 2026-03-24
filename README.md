# PhoneLockAI

SwiftUI iOS app for mindful unlocks: goals, streaks, timed reminders, and a chat flow before unlocking.

## Requirements

- Xcode 16+ (iOS 18.4 deployment target as configured)
- Your own Apple Developer team selected in the target’s **Signing & Capabilities**

## Backend URL (required for chat)

The unlock chat calls an HTTP backend. **No default URL is bundled** (so the repo is safe to publish).

1. Open the project in Xcode.
2. Select the **PhoneLockAI** target → **Info** tab.
3. Under **Custom iOS Target Properties**, add a string key:
   - **Key:** `BACKEND_CHAT_URL`
   - **Value:** your HTTPS endpoint (e.g. API Gateway URL that accepts the app’s JSON payload).

Alternatively, merge the same key into the root `Info.plist` next to the `.xcodeproj` (Xcode merges it with generated keys).

Expected request: `POST` with `Content-Type: application/json`, body shape:

```json
{
  "messages": [{ "role": "user", "content": "..." }],
  "goals": ["goal text"]
}
```

Expected response JSON:

```json
{ "assistant": "reply text" }
```

Implement the server yourself (e.g. AWS Lambda + OpenAI). The in-app coach behavior is described in `PhoneLockAI/PhoneLockAI prompt.txt`.

## App Group

`PhoneLockAI/PhoneLockAI.entitlements` references an App Group (`group.com.kedaarchakankar.phonelockai`). For your own builds, create a matching App Group in the Apple Developer portal and update the entitlement string, or remove the group if you do not use extensions that need it.

## License

Add a `LICENSE` file if you want others to know how they may use the code.
