# SilverConnect

A zero-text safety check-in, mood-sharing, and marketplace app for the GBA
silver economy — now with a real backend and account system.

**👉 Start with `DEPLOY.md` for the full step-by-step setup + deploy guide.**

## Files
- `index.html` — the app (auth, check-ins, mood sharing, marketplace)
- `schema.sql` — paste into Supabase's SQL Editor to create your database
- `config.js` — put your Supabase Project URL + anon key here
- `manifest.json` / `sw.js` — makes the site installable as a PWA on phones
- `DEPLOY.md` — full walkthrough, start to finish

## Quick summary
1. Create a free Supabase project → run `schema.sql` in its SQL Editor
2. Paste your Project URL + anon key into `config.js`
3. Drag this folder onto https://app.netlify.com/drop for a live URL
