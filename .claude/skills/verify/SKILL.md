---
name: verify
description: Build, run, and drive the Papayal Rails app locally to verify changes end-to-end.
---

# Verify changes in the running app

## Build & launch
- JS: `npm run build` (esbuild → `app/assets/builds/application.js`). CSS: `npm run build:css`.
- Server: `bin/rails server -p <port>` (dev DB already has seed-ish data: merchants, gift cards, transactions).
- **Gotcha:** if `public/assets/` exists (stale `assets:precompile`), Sprockets serves those OLD bundles in dev and your JS/CSS changes silently don't load. Fix: `bin/rails assets:clobber` — but it also empties `app/assets/builds/`, so rebuild JS *and* CSS after, then restart the server.

## Drive
- Playwright is available (`npx playwright --version`; install the npm pkg in the scratchpad with `npm install playwright --no-save`, chromium is already cached).
- Login: `/users/sign_in` with `input[name="user[email]"]` / `input[name="user[password]"]`, then `waitForURL('**/admin**')`.
- Create a throwaway admin first (User validates phone presence):
  `bin/rails runner 'User.create!(email: "verify-admin@example.com", role: :admin, phone: "+10000000099", password: "Verify123!pass", password_confirmation: "Verify123!pass", first_name: "V", last_name: "A")'`
  — delete it when done.
- **Gotcha:** don't click generic `form button[type="submit"]` — `button_to` forms (logout, suspend) come first in the DOM and you'll log yourself out or mutate data. Scope selectors tightly; prefer `fill` + `press('Enter')` for search forms.
- Turbo navigations: use `waitForURL(...)`, not `waitForLoadState('networkidle')` (resolves before Turbo finishes).

## Data notes
- Redemption `Transaction.merchant_id` is the *redeeming* merchant (may be a partner like Farmaenlace), not the card's issuing merchant — expect "issued here, redeemed elsewhere" numbers in dev data.
