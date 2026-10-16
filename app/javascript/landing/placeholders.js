/*
 * Every piece of "real data" the rebuilt screens show, in one file.
 * Swap these for real data (with written permission) and every screen follows.
 * Values are RAW, the way the API would send them; components format them the way the app
 * does (money: en-US "$25" / "$25.00"; dates: es-EC "26 sept"; times: es-EC 24 h "09:46").
 *
 * Rules (CLAUDE.md, director decisions 2026-09-28):
 * - No real merchant, partner or carrier names or logos. Merchants are the five live
 *   categories (Farmacia, Telefonía, Mascotas, Recargas, Seguros); each logo slot shows that
 *   category's mark. Only live categories may appear.
 * - No photos or avatars: people render with the app's initials-on-teal fallback.
 * - Places: US + Ecuador only.
 * - If you change redemption.token, re-run: node brand/ui/scripts/gen-codes.mjs
 */
(function (root) {
  const DATA = {
    statusBarTime: "9:41",

    // API field names mirror src/types/api.ts `Merchant` (store_name, categories, logo_url,
    // amount_presets in cents). Category keys are the app's own (src/constants/categories.ts).
    // Merchants are exactly the five live categories, named by the category word, one app
    // category each. `mark` (marks/<name>.svg) stands in for `logo_url` in every logo slot
    // until merchants give written permission for their real logos.
    // Home shelves, in the app's CATEGORIES order: Salud y medicina, Mascotas, Servicios.
    merchants: [
      { id: "farmacia", store_name: "Farmacia", categories: ["salud_y_medicina"], logo_url: null, mark: "farmacia", amount_presets: [500, 1000, 2500] },
      { id: "seguros", store_name: "Seguros", categories: ["salud_y_medicina"], logo_url: null, mark: "seguros", amount_presets: [500, 1000, 2500] },
      { id: "mascotas", store_name: "Mascotas", categories: ["mascotas"], logo_url: null, mark: "mascotas", amount_presets: [500, 1000, 2500] },
      { id: "telefonia", store_name: "Telefonía", categories: ["servicios"], logo_url: null, mark: "telefonia", amount_presets: [500, 1000, 2500] },
      { id: "recargas", store_name: "Recargas", categories: ["servicios"], logo_url: null, mark: "recargas", amount_presets: [500, 1000, 2500] }
    ],

    people: {
      sender: { first_name: "Daniela", last_name: "Ramírez", name: "Daniela Ramírez", email: "daniela@example.com", phone: null, interests: [] },
      recipient: {
        name: "Rosa Morales",
        email: "rosa@example.com",
        phone_country: "EC",
        phone_calling_code: "+593",
        phone_national: "099 123 4567",
        note: "Para tus medicinas, mamá. Te quiero."
      }
    },

    currency: "USD",

    // The hero purchase: Daniela sends Rosa $25 at Farmacia.
    purchase: {
      merchant_id: "farmacia",
      amount_cents: 2500,
      projected_balance_cents: 2500
    },

    // Rosa's card at Farmacia, as she sees it after claiming.
    giftCard: {
      merchant_id: "farmacia",
      spendable_cents: 2500,
      loads: [{ sender: { full_name: "Daniela Ramírez" }, amount_cents: 2500, created_at: "2026-09-26T15:20:00-05:00", note: "Para tus medicinas, mamá. Te quiero." }]
    },

    // papayal.app/claim/<token> teaser (signed out). `teaser` is server-written copy we don't
    // have, so it's null and the app's own fallback headline renders.
    claim: {
      sender_first_name: "Daniela",
      merchant_id: "farmacia",
      amount_cents: 2500,
      note: "Para tus medicinas, mamá. Te quiero.",
      teaser: null,
      recipient_masked_phone: null,
      recipient_registered: false,
      is_reload: false
    },

    // Fake redemption code in the app's real format: 10 chars, displayed 4-3-3.
    redemption: {
      merchant_id: "farmacia",
      token: "K7QM4X9PRT",
      expires_at_display: "09:46",
      remaining_seconds: 299,
      redeemed_cents: 2500
    }
  };

  if (typeof module !== "undefined" && module.exports) module.exports = DATA;
  root.PAPAYAL_UI_DATA = DATA;
})(typeof window !== "undefined" ? window : globalThis);
