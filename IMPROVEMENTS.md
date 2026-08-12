# Suggested improvements

Things worth doing that are deliberately *not* done yet, roughly in the order I'd
do them. Everything here is a judgement call rather than a defect — the concrete
bugs have been fixed.

## Done since this list was written

- **§4 (serial refresh)** — `refreshAll` now runs a `withTaskGroup` capped at three.
  The fixed `Task.sleep(for: .seconds(5))` in the scrape path is still there.
- **§6 (legacy migration)** — `seedMeters()` and `adoptLegacyUsage()` are gone,
  along with the two hardcoded session UUIDs.
- **§7 (layout writing into the model)** — the left/right placement model is
  retired, so `maximumPerSide` and the `$meters` sink that wrote it no longer
  exist. `NotchLayout`'s hardcoded `1...12` search went with it.
- **§2, partly** — `SessionStore` is `@Observable`. `QuotaStore` is still an
  `ObservableObject`, so the note below still applies to it.

## New, from the agent-monitoring work

- **The hook helper starts a Swift process per event.** Around 350 ms of that is
  runtime start-up, on every tool call an agent makes. It is off the critical path
  for reporting events (the CLI does not wait) but it is not free. A C helper, or a
  persistent one, would cut it.
- **`IslandWindowController.present` rebuilds the `NSHostingView` on every call**,
  including once a second from the elapsed-time tick. It should set the frame and
  let SwiftUI diff the content instead.
- **`PermissionRules` is a subset of Claude Code's matching.** It errs toward
  showing a card, which is the safe direction, but it will show one for rules it
  cannot parse. Worth extending as the rule grammar settles.
- **Codex and Gemini session support is presence-only.** Codex's `notify` is wired
  but reports far less than Claude Code's hooks; Gemini has nothing to hook.

## 1. Split `QuotaStore`

`Sources/LimitIsland/Core/QuotaStore.swift` owns several unrelated jobs:
persistence, the poll loop, the percentage/countdown display phase, hover state,
account CRUD, the layout capacity, *and* the live `NSWindowController` and
`GeminiOAuthFlow` objects. A view model holding window controllers is the
biggest structural problem left in the app.

Suggested shape:

- `MeterRepository` — the account list and its persistence.
- `UsageRefresher` — polling, reading, the sticky-reading rule.
- `SignInCoordinator` — `loginWindows` and `oauthFlows`.
- `QuotaStore` — a thin view-facing projection over those three.

## 2. Migrate to `@Observable`

The deployment target is macOS 14, where the macro is available. Today
`showsResetTimer` flips every 5 s and 2 s, and because `QuotaStore` is a single
`ObservableObject`, **every** flip invalidates every view observing it —
including all of Settings if it happens to be open. `@Observable` narrows
invalidation to the properties a view actually reads, and would also remove the
`@ObservedObject var state:` threading through five views in favour of
`.environment`.

## 3. Get the reader off the main actor

`SubscriptionUsageReader` is `@MainActor` because it owns `WKWebView`s, but that
drags the JSON decoding and the regex scraping onto the main actor too — they
resume there after each `await`. Split it: an `actor` for the HTTP and parsing
work, and a small `@MainActor` shim for the WebKit parts.

## 4. Refresh meters concurrently

`refreshAll` is a serial `for` loop. The scraping fallback sleeps a fixed 5 s per
meter and each request can take 20 s, so with six or more meters a single cycle
can outrun the 60 s poll interval. A `withTaskGroup` with a small concurrency
limit would fix it. Related: the fixed `Task.sleep(for: .seconds(5))` in the
scrape path should await `WKNavigationDelegate` completion instead — WebKit also
throttles JavaScript in views that are not in a window, so it is flaky as well as
slow.

## 5. Teach polling about the machine's lifecycle

There is no pause on sleep (`NSWorkspace.willSleepNotification`), no pause when
the panel is hidden, no backoff after repeated failures, and no jitter. A laptop
on battery hits three provider APIs every minute forever. Worth adding:
exponential backoff on consecutive failures, and a refresh on wake rather than
waiting out the remaining interval.

## 6. Persistence details

- `persistUsages()` re-encodes and writes the whole dictionary after **every**
  meter refresh — N writes per minute. Debounce to one write per cycle.
- The legacy `seedMeters()` / `adoptLegacyUsage()` path, with its two hardcoded
  session UUIDs, migrates from a build that never shipped (the repo has no
  commits). It can be deleted outright.

## 7. Layout writing into the model

`IslandWindowController.position()` writes `state.maximumPerSide`, and does so
from a `$meters` sink — which is why it needs both a `RunLoop.main` hop and an
inequality guard to avoid "Publishing changes from within view updates". Capacity
is layout output, not model state; it belongs in a separate object the settings
screen reads, not in the observable store.

Smaller: `NotchLayout.capacity(forWidth:)` searches a hardcoded `1...12`, paired
with a `maximumPerSide` default of 6. Derive the bound instead of writing it
twice.

## 8. Tooling

- No `.swiftlint.yml` / `.swift-format`, no CI. A GitHub Actions job running
  `swift build` and `swift test` would have caught the missing `gemini.png`
  immediately — the bundled-logo test now does.
- `Scripts/build-app.sh` hand-assembles the bundle with no version stamping and
  no notarization path. Fine for personal use; a blocker for distribution.
- The app is **not sandboxed**, and cannot easily become so: it reads
  `~/.codex/auth.json`, another app's keychain item, and WebKit cookie stores.
  Any App Store ambition means rethinking all three.

## 9. WebKit lifetime

`SubscriptionUsageReader.webViews` is bounded by the meter count and cleaned up
on removal, so it is not a leak — but each entry is a live `WKWebView` held for
the life of the app. Only the scraping fallback needs one, and only Codex and
Claude can reach it. Constructing on demand and releasing after the read would
cost a page load per refresh but hold no WebKit processes at idle.

## 10. Scraping is a guess — and it was quietly load-bearing

`SubscriptionTextParser` reads whatever the usage page renders. The
label-proximity and consumption-vs-remaining rules are now tested, but it is
still heuristic and will silently produce a wrong number when a provider
restyles its page.

This stopped being hypothetical. The logging added alongside it revealed that
every Claude refresh was failing to decode `claude.ai/api/organizations` and
falling over to the scraper without a word. The cause turned out to be the
response model, not the network: an organization's identifier can arrive
numeric, and it was declared `String?`, so one type mismatch inside one element
failed the entire response. Provider payloads are now decoded element-by-element
with lenient identifiers, and an empty result logs rather than passing quietly.

Two rounds of guessing preceded that diagnosis — first "Cloudflare interstitial",
then "wrong user agent" — and both were settled in minutes once the failure path
logged the response's content type and JSON skeleton. Diagnostics that describe a
payload's *shape* (never its values) are worth adding wherever an undocumented
API is decoded.

The episode is the argument for this item: a silent fallback let a broken API
path run unnoticed indefinitely.

Since all three providers have real API paths, consider dropping the scrape
entirely and showing "usage unavailable" instead — a blank is more honest than a
plausible wrong percentage, and it fails loudly enough to be fixed.
