/*
 * papayal-mobile UI as HTML. Each function returns markup for one component or screen,
 * in a real app state, filled from data/placeholders.js. Every meaningful element has a
 * stable data-ui="…" hook so films can animate pieces individually.
 *
 * Load order: tokens.css, fonts.css, ui.css, data/placeholders.js, icons.js, components.js.
 *
 *   const el = PapayalUI.mount(container, "merchantProfile", { selectedCents: 2500 });
 *   gsap.to(el.querySelector('[data-ui="chip-25"]'), { … })
 *
 * Omission option (films only): `hideExpiry: true` on merchantProfile, giftCard, redemptionToken
 * (and on merchantGiftCardHero / redemptionCode) removes every expiry node: the promo card's
 * "VÁLIDA HASTA 08/28" block, the owned card's "· SIN VENCIMIENTO", and the code's
 * "Expira a las…" / "Tiempo restante…" lines. The layout reflows as it would in the app if
 * those nodes were absent. Default false keeps the gallery faithful. Options may only OMIT
 * real UI; nothing here adds or alters it.
 *
 * Sources are cited per function (papayal-mobile paths). States are the app's own; nothing
 * here is invented UI. Transitions between states are the film's to design (motion.js).
 */
(function (root) {
  const D = root.PAPAYAL_UI_DATA;
  const ICONS = root.PAPAYAL_UI_ICONS;
  const MARKS = root.PAPAYAL_UI_MARKS || (ICONS && ICONS.MARKS) || {};
  if (!D || !ICONS) throw new Error("PapayalUI: load data/placeholders.js and icons.js first");

  // Base URL for the raster/SVG assets (assets/…), resolved from this script's location.
  const script = typeof document !== "undefined" ? document.currentScript : null;
  let base = script && script.src ? script.src.replace(/[^/]*$/, "") : "";

  // ------------------------------------------------------------------ helpers ------------
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const ui = (name) => (name ? ` data-ui="${esc(name)}"` : "");
  const cls = (...names) => names.filter(Boolean).join(" ");
  // The landing bundle has no currentScript; it sets PAPAYAL_UI_BASE before rendering.
  const asset = (f) => `${root.PAPAYAL_UI_BASE || base}assets/${f}`;

  // src/utils/money.ts — pinned en-US
  const moneyFmt = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const compactFmt = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 0, maximumFractionDigits: 0 });
  const money = (cents) => moneyFmt.format((cents ?? 0) / 100);
  const moneyCompact = (cents) => (Number.isInteger((cents ?? 0) / 100) ? compactFmt.format(cents / 100) : money(cents));
  // GiftCardScreen DAY_FORMATTER
  // Formatted in Ecuador time (the app formats in device time; pinned so renders never depend on this Mac's zone).
  const day = (iso) => new Intl.DateTimeFormat("es-EC", { day: "numeric", month: "short", timeZone: "America/Guayaquil" }).format(new Date(iso));

  // src/constants/categories.ts (labels) + HomeScreen CATEGORY_ICONS
  const CATEGORIES = [
    ["salud_y_medicina", "Salud y medicina", "plus-circle"], ["mascotas", "Mascotas", "heart"],
    ["servicios", "Servicios", "zap"], ["supermercado", "Supermercado", "shopping-cart"],
    ["hogar", "Hogar", "home"], ["tecnologia", "Tecnología", "monitor"], ["ropa_y_moda", "Ropa y moda", "shopping-bag"],
    ["belleza", "Belleza", "star"], ["deportes_y_fitness", "Deportes y fitness", "activity"],
    ["entretenimiento", "Entretenimiento", "film"], ["restaurantes", "Restaurantes", "coffee"],
    ["educacion", "Educación", "book-open"], ["viajes", "Viajes", "map"], ["bebes_y_ninos", "Bebés y niños", "smile"]
  ];
  const CATEGORY_LABEL = Object.fromEntries(CATEGORIES.map(([k, l]) => [k, l]));

  const merchant = (id) => {
    const m = D.merchants.find((x) => x.id === id);
    if (!m) throw new Error(`PapayalUI: unknown merchant "${id}"`);
    return m;
  };
  const merchantName = (m) => m.store_name || m.name;
  const initialOf = (name) => (name || "").trim().charAt(0).toUpperCase() || "C";
  // src/utils/initials.ts getInitials
  const initials = (name) => {
    const parts = (name || "").trim().split(/\s+/).filter(Boolean);
    if (!parts.length) return "?";
    return parts.length === 1 ? parts[0].slice(0, 2).toUpperCase() : (parts[0][0] + parts[1][0]).toUpperCase();
  };
  // src/domain/wallet/mapGiftCardVM.ts senderShortName
  const senderShortName = (full) => {
    const parts = (full || "").trim().split(/\s+/);
    return parts.length > 1 ? `${parts[0]} ${parts[parts.length - 1][0]}.` : parts[0];
  };

  // ------------------------------------------------------------------ primitives ---------
  /** Feather glyph as it renders from @expo/vector-icons (icon-font line box). */
  function icon(name, size, opts = {}) {
    const ic = ICONS[name];
    if (!ic) throw new Error(`PapayalUI: icon "${name}" not in icons.js`);
    return `<span class="${cls("pui-icon", opts.cls)}" style="--s:${size}px"${ui(opts.ui)}><svg viewBox="${ic.viewBox}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ic.inner}</svg></span>`;
  }
  /** MerchantGiftCardHero ContactlessGlyph (28 × 22 react-native-svg). */
  function contactless() {
    const ic = ICONS.contactless;
    return `<svg viewBox="${ic.viewBox}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true">${ic.inner}</svg>`;
  }
  /** Category mark (marks/*.svg): cream tile r50/480 + teal 24-unit drawing inset 80/480.
   *  Rendered like an <Image resizeMode="contain">: fills its box, keeps its square aspect. */
  function mark(name, u) {
    const inner = MARKS[name];
    if (!inner) throw new Error(`PapayalUI: mark "${name}" not in icons.js`);
    return `<svg class="pui-mark" viewBox="0 0 480 480" preserveAspectRatio="xMidYMid meet" aria-hidden="true"${ui(u)}><rect class="pui-mark-tile" width="480" height="480" rx="50"/><svg class="pui-mark-ico" x="80" y="80" width="320" height="320" viewBox="0 0 24 24" overflow="visible">${inner}</svg></svg>`;
  }
  /** Which logo a merchant renders: its mark, or the app's monogram fallback (state). */
  const logoKind = (m, logo) => (logo === "monogram" || !m.mark ? "monogram" : "mark");

  /** iOS UIActivityIndicatorView (medium, 8 spokes), static frame. */
  function spinner(ui_) {
    let spokes = "";
    for (let i = 0; i < 8; i++) {
      spokes += `<rect x="9" y="1.5" width="2" height="5" rx="1" transform="rotate(${i * 45} 10 10)" opacity="${(0.28 + (0.72 * (8 - i)) / 8).toFixed(2)}"/>`;
    }
    return `<svg class="pui-spinner" viewBox="0 0 20 20" fill="currentColor"${ui(ui_)}>${spokes}</svg>`;
  }

  /** Button.tsx — variants primary | secondary | ghost | danger; states pressed | disabled | loading. */
  function button({ label, variant = "primary", pressed = false, disabled = false, loading = false, tall = false, outline = false, ui: u, cls: extra } = {}) {
    const isDisabled = disabled || loading;
    const spinnerColor = variant === "ghost" ? "var(--color-primary)" : variant === "primary" ? "var(--color-secondary)" : "var(--hc-white)";
    return `<div class="${cls("v pui-btn", `pui-btn--${variant}`, tall && "pui-btn--tall", outline && "pui-btn--outline", pressed && !isDisabled && "is-pressed", isDisabled && "is-disabled", extra)}"${ui(u)}>${
      loading ? `<span style="color:${spinnerColor}">${spinner(u && `${u}-spinner`)}</span>` : `<span class="t pui-btn-label"${ui(u && `${u}-label`)}>${esc(label)}</span>`
    }</div>`;
  }

  /** BackButton.tsx */
  function backButton({ pressed = false, ui: u = "back" } = {}) {
    return `<div class="${cls("v pui-back", pressed && "is-pressed")}"${ui(u)}>${icon("arrow-left", 22)}</div>`;
  }

  /** Card.tsx */
  const card = (inner, { ui: u, cls: extra } = {}) => `<div class="${cls("v pui-card", extra)}"${ui(u)}>${inner}</div>`;

  /** Monogram fallback used by MerchantGridCard (56) and MerchantGiftCardHero (40). */
  const monogram = (name, cl) => `<div class="${cls("v pui-monogram", cl)}" data-ui="monogram"><span class="t pui-monogram-initial">${esc(initialOf(name))}</span></div>`;

  /** Avatar.tsx fallback: initials on teal (director: used instead of avatar-default.png). */
  const avatar = (name, size, u) =>
    `<div class="v pui-avatar" style="width:${size}px;height:${size}px;border-radius:${size / 2}px"${ui(u)}><span class="t pui-avatar-initials" style="font-size:${size * 0.32}px">${esc(initials(name))}</span></div>`;

  /** Banner.tsx (tone "info"). */
  function banner({ title, message, iconName = "info", ui: u = "banner", cls: extra } = {}) {
    return `<div class="${cls("v pui-banner", extra)}"${ui(u)}>${icon(iconName, 18)}<div class="v pui-banner-body">${
      title ? `<span class="t pui-banner-title"${ui(`${u}-title`)}>${esc(title)}</span>` : ""
    }<span class="t sys pui-banner-message"${ui(`${u}-message`)}>${esc(message)}</span></div></div>`;
  }

  /** ListRow.tsx — ListGroup of rows; variant default | accent | danger; pressed / disabled. */
  function listRow({ iconName, title, subtitle, variant = "default", chevron = true, pressed = false, disabled = false, ui: u } = {}) {
    return `<div class="${cls("v r pui-row", pressed && "is-pressed", disabled && "is-disabled")}"${ui(u)}><div class="${cls("v pui-row-icon", variant !== "default" && `is-${variant}`)}">${icon(iconName, 18)}</div><div class="v pui-row-text"><span class="${cls("t pui-row-title", variant === "danger" && "is-danger")}">${esc(title)}</span>${
      subtitle ? `<span class="t sys pui-row-subtitle">${esc(subtitle)}</span>` : ""
    }</div>${chevron ? `<span class="pui-row-chevron">${icon("chevron-right", 18)}</span>` : ""}</div>`;
  }
  const listGroup = (rows, u) => `<div class="v pui-group"${ui(u)}><div class="v pui-group-clip">${rows.join('<div class="v pui-row-divider"></div>')}</div></div>`;

  // ------------------------------------------------------------------ components ---------
  /** MerchantGridCard.tsx — tile + labels; width from getMerchantShelfCardMetrics(393). */
  function merchantGridCard({ merchantId, categoryLabel = "Comercio", pressed = false, width = 393, logo } = {}) {
    const m = merchant(merchantId);
    const cardsVisible = width >= 900 ? 4.5 : 2.5;
    const w = Math.round((width - 20 - 14 * cardsVisible) / cardsVisible);
    const h = Math.round(w / 1.5);
    return `<div class="${cls("v pui-tile", pressed && "is-pressed")}" data-ui="tile-${esc(m.id)}">
      <div class="v pui-tile-card" style="width:${w}px;height:${h}px" data-ui="tile-${esc(m.id)}-card"><div class="v pui-tile-logo-area">${logoKind(m, logo) === "mark" ? `<div class="pui-logo-image" data-ui="tile-${esc(m.id)}-logo">${mark(m.mark)}</div>` : monogram(merchantName(m), "pui-tile-monogram")}</div></div>
      <div class="v pui-tile-labels" style="width:${w}px"><span class="t nowrap pui-tile-name">${esc(merchantName(m))}</span><span class="t nowrap pui-tile-category">${esc(categoryLabel)}</span></div>
    </div>`;
  }

  /** MerchantGiftCardHero.tsx — variant "promo" | "owned". */
  function merchantGiftCardHero({ merchantId, variant = "promo", spendableCents = 0, ui: u = "giftcard", logo, hideExpiry = false } = {}) {
    const m = merchant(merchantId);
    // A logo image gets bandedLogoHeight(aspect): a square mark (aspect 1) → 54 × 54, in the
    // auto-height logo area (minHeight 40). The monogram keeps the fixed 40-high area.
    const logoHtml =
      logoKind(m, logo) === "mark"
        ? `<div class="v pui-giftcard-logo-area is-auto"><div class="pui-giftcard-logo-img" data-ui="${u}-logo">${mark(m.mark)}</div></div>`
        : `<div class="v pui-giftcard-logo-area">${monogram(merchantName(m), "pui-giftcard-monogram")}</div>`;
    const bottom =
      variant === "owned"
        ? `<div class="v pui-giftcard-bottom">
             <div class="v r pui-giftcard-balance-row"><span class="t pui-giftcard-balance-label">Disponible</span><span class="t pui-giftcard-balance-value"${ui(`${u}-balance`)}>${money(spendableCents)}</span></div>
             <div class="v r pui-giftcard-meta"><span class="t nowrap pui-giftcard-caption" style="flex:0 1 auto"${ui(`${u}-caption`)}>${hideExpiry ? "TARJETA DE REGALO DIGITAL" : "TARJETA DE REGALO DIGITAL · SIN VENCIMIENTO"}</span></div>
           </div>`
        : `<div class="v pui-giftcard-bottom">
             <span class="t pui-giftcard-number"${ui(`${u}-number`)}>1234 5678 9009 8765</span>
             <div class="v r pui-giftcard-meta"><span class="t pui-giftcard-caption"${ui(`${u}-caption`)}>TARJETA DE REGALO</span>${hideExpiry ? "" : `<div class="v pui-giftcard-valid"${ui(`${u}-valid`)}><span class="t pui-giftcard-valid-label">VÁLIDA HASTA</span><span class="t pui-giftcard-valid-date">08/28</span></div>`}</div>
           </div>`;
    return `<div class="v pui-giftcard"${ui(u)}>
      <div class="v r pui-giftcard-top">
        ${logoHtml}
        <div class="v"><img class="pui-giftcard-ring" src="${asset("Papayal-logoTag.png")}" alt=""${ui(`${u}-ring`)}></div>
      </div>
      <div class="pui-giftcard-contactless"${ui(`${u}-contactless`)}>${contactless()}</div>
      ${bottom}
    </div>`;
  }

  /** merchantProfileUi.tsx amount chips: presets + "Otro". */
  function amountChips({ presets, selectedCents = null } = {}) {
    const chips = presets
      .map((c) => {
        const sel = c === selectedCents;
        return `<div class="${cls("v pui-chip", sel && "is-selected")}" data-ui="chip-${c / 100}"><span class="t pui-chip-label">${moneyCompact(c)}</span></div>`;
      })
      .join("");
    return `<div class="v r pui-mp-amount-row" data-ui="amount-row">${chips}<div class="v pui-chip" data-ui="chip-otro"><span class="t pui-chip-label">Otro</span></div></div>`;
  }

  /** AnimatedTabBar.tsx — focused: "home" | "wallet" | "profile". */
  function tabBar({ focused = "home" } = {}) {
    const tabs = [
      ["home", "home", "Inicio", 20],
      ["wallet", "credit-card", "Mis tarjetas", 22],
      ["profile", "user", "Perfil", 22]
    ];
    const index = tabs.findIndex((t) => t[0] === focused);
    const tabWidth = (393 - 8) / 3;
    const indicatorWidth = Math.max(tabWidth - 8, tabWidth * 0.82);
    const offset = (tabWidth - indicatorWidth) / 2;
    return `<div class="v pui-tabbar" data-ui="tabbar"><div class="v r pui-tabbar-rail" data-ui="tabbar-rail">
      <div class="v pui-tab-indicator" data-ui="tab-indicator" style="transform:translateX(${(index * tabWidth + offset).toFixed(3)}px)"></div>
      ${tabs
        .map(([key, glyph, label, size]) => `<div class="${cls("v pui-tab", key === focused && "is-focused")}" data-ui="tab-${key}">${icon(glyph, size, { ui: `tab-${key}-icon` })}<span class="t pui-tab-label" data-ui="tab-${key}-label">${label}</span></div>`)
        .join("")}
    </div></div>`;
  }
  tabBar.geometry = { tabWidth: (393 - 8) / 3, indicatorOffset: 4 }; // indicator x = index × tabWidth + 4

  /** CheckoutHeader.tsx */
  function checkoutHeader({ step = "recipient", title, subtitle, summary = [] } = {}) {
    const steps = [["merchant", "Comercio"], ["recipient", "Destinatario"], ["confirm", "Confirmar"], ["payment", "Pago"]];
    const active = steps.findIndex((s) => s[0] === step);
    return `<div class="v pui-ch" data-ui="checkout-header">
      <div class="v r pui-ch-top">${backButton()}<span class="t pui-ch-stepcount" data-ui="step-count">Paso ${active + 1} de ${steps.length}</span></div>
      <span class="t pui-ch-title" data-ui="checkout-title">${esc(title)}</span>
      <span class="t sys pui-ch-subtitle" data-ui="checkout-subtitle">${esc(subtitle)}</span>
      <div class="v r pui-ch-progress" data-ui="progress">${steps
        .map(([key, label], i) => {
          const isActive = i === active;
          const done = i < active;
          return `<div class="v pui-ch-step" data-ui="progress-${key}"><div class="${cls("v pui-ch-dot", done && "is-complete", isActive && "is-active")}">${done ? icon("check", 11) : ""}</div><span class="${cls("t nowrap pui-ch-label", (isActive || done) && "is-on")}">${label}</span></div>`;
        })
        .join("")}</div>
      ${
        summary.length
          ? `<div class="v r pui-ch-summary" data-ui="checkout-summary">${summary
              .map(([l, v]) => `<div class="v pui-ch-summary-item"><span class="t pui-ch-summary-label">${esc(l)}</span><span class="t nowrap pui-ch-summary-value">${esc(v)}</span></div>`)
              .join("")}</div>`
          : ""
      }
    </div>`;
  }

  /** TextField.tsx (filled). */
  /** iOS text caret (chrome, not app UI): systemBlue, 2 pt, one line tall. `lead` = before
   *  placeholder text (empty focused field). Blink it with motion.js caretBlink. */
  const caret = (u, lead) => `<span class="${cls("pui-caret", lead && "is-lead")}"${ui(u)}></span>`;

  /** TextField.tsx — filled, or empty showing its placeholder (placeholderTextColor lightText).
   *  `focused: true` adds the iOS caret (after the text, or before the placeholder when empty).
   *  Hooks: -placeholder, -value (wraps -text + caret), -text, -caret / -caret-lead. */
  function textField({ label, value, placeholder, multiline = false, error, focused = false, ui: u } = {}) {
    const empty = !value;
    return `<div class="v pui-field"${ui(u)}><span class="t pui-field-label">${esc(label)}</span><div class="v"><div class="${cls("v pui-field-input", multiline && "is-multiline", error && "is-error")}"${ui(u && `${u}-input`)}>${
      placeholder ? `<span class="t pui-field-placeholder"${ui(u && `${u}-placeholder`)}${empty ? "" : ' style="display:none"'}>${focused ? caret(u && `${u}-caret-lead`, true) : ""}${esc(placeholder)}</span>` : ""
    }<span class="t pui-field-value"${ui(u && `${u}-value`)}${empty && placeholder ? ' style="display:none"' : ""}><span${ui(u && `${u}-text`)}>${esc(value)}</span>${focused ? caret(u && `${u}-caret`) : ""}</span></div></div>${
      error ? `<span class="t pui-field-error">${esc(error)}</span>` : ""
    }</div>`;
  }

  /** PhoneInput.tsx (filled). */
  function phoneInput({ label = "Teléfono", focused = false, ui: u = "field-phone" } = {}) {
    const r = D.people.recipient;
    return `<div class="v pui-field"${ui(u)}><span class="t pui-field-label">${esc(label)}</span><div class="${cls("v pui-phone-box", focused && "is-focused")}"${ui(`${u}-input`)}>
      <div class="v r pui-phone-chip"><span class="t pui-phone-flag" data-ui="flag">${r.phone_country === "EC" ? "🇪🇨" : ""}</span><span class="t pui-phone-code">${esc(r.phone_calling_code)}</span>${icon("chevron-down", 16)}</div>
      <div class="v pui-phone-divider"></div>
      <span class="t pui-phone-input">${esc(r.phone_national)}</span>
    </div></div>`;
  }

  /** Redemption code block (RedemptionTokenScreen card body). state: showing | celebrating */
  function redemptionCode({ state = "showing", hideExpiry = false } = {}) {
    const R = D.redemption;
    const t = R.token;
    const display = t.length === 10 ? `${t.slice(0, 4)}-${t.slice(4, 7)}-${t.slice(7)}` : t;
    const mins = Math.floor(R.remaining_seconds / 60);
    const secs = String(R.remaining_seconds % 60).padStart(2, "0");
    return `<div class="v pui-rt-token-container" data-ui="code-block">
      <div class="v pui-rt-code-area" data-ui="code-area">
        <div class="v pui-rt-well" data-ui="qr"><img class="pui-rt-qr" src="${asset("token-qr.svg")}" alt=""></div>
        <div class="v pui-rt-well" data-ui="barcode"><img class="pui-rt-barcode" src="${asset("token-barcode.svg")}" alt=""></div>
        <span class="t pui-rt-token" data-ui="token-text">${esc(display)}</span>
        ${state === "celebrating" ? `<div class="v pui-rt-overlay" data-ui="celebrate-overlay">${icon("check-circle", 44)}<span class="t pui-rt-celebrate">¡Canje completo!</span></div>` : ""}
      </div>
      ${
        state === "showing" && !hideExpiry
          ? `<span class="t sys pui-rt-muted" data-ui="expires">Expira a las ${esc(R.expires_at_display)}</span><span class="t pui-rt-countdown" data-ui="countdown">Tiempo restante: ${mins}:${secs}</span>`
          : ""
      }
    </div>`;
  }

  /** ClaimLandingScreen merchant row: 36-pt circular logo well + name. The mark replaces the
   *  app's merchant-default.png fallback (which would show with logo_url null). */
  function claimMerchantRow({ merchantId } = {}) {
    const m = merchant(merchantId);
    return `<div class="v r pui-cl-merchant-row" data-ui="claim-merchant"><div class="v pui-cl-logo" data-ui="claim-logo">${m.mark ? mark(m.mark) : `<img src="${asset("merchant-default.png")}" alt="">`}</div><span class="t pui-cl-merchant">${esc(merchantName(m))}</span></div>`;
  }

  /** PurchaseSuccessScreen card. */
  function successBlock() {
    const P = D.purchase;
    const m = merchant(P.merchant_id);
    const who = D.people.recipient.name.trim().split(/\s+/)[0];
    return card(
      `<div class="v pui-success-disc" data-ui="success-disc">${icon("check", 32)}</div>
       <span class="t pui-ps-title" data-ui="success-title">¡Tarjeta enviada!</span>
       <span class="t sys pui-ps-subtitle" data-ui="success-body">${esc(`${who} recibirá una tarjeta de regalo digital de ${merchantName(m)} con ${money(P.amount_cents)}. Ya le avisamos.`)}</span>
       <div class="v pui-ps-summary" data-ui="success-summary"><span class="t pui-ps-merchant">${esc(merchantName(m))}</span><span class="t pui-ps-amount">${money(P.amount_cents)}</span>${
         typeof P.projected_balance_cents === "number" ? `<span class="t sys pui-ps-balance">Saldo de la tarjeta: ${money(P.projected_balance_cents)}</span>` : ""
       }</div>
       <div class="v pui-ps-actions" data-ui="success-actions">
         ${button({ label: "Compartir por WhatsApp", variant: "secondary", tall: true, ui: "btn-share" })}
         ${button({ label: "Ver mis tarjetas", variant: "primary", tall: true, ui: "btn-wallet" })}
         ${button({ label: "Enviar otra", variant: "ghost", outline: true, ui: "btn-another" })}
         ${button({ label: "Regresar a inicio", variant: "ghost", outline: true, ui: "btn-home" })}
       </div>`,
      { ui: "success-card", cls: "pui-ps-card" }
    );
  }

  // ------------------------------------------------------------------ screen shell -------
  function statusBar() {
    return `<div class="pui-statusbar" data-ui="statusbar"><span class="pui-statusbar-time">${esc(D.statusBarTime)}</span><div class="pui-statusbar-icons">
      <svg width="18" height="12" viewBox="0 0 18 12" fill="currentColor"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1"/></svg>
      <svg width="16" height="12" viewBox="0 0 16 12" fill="currentColor"><path d="M8 2.3c2.3 0 4.4.9 5.9 2.4l1.1-1.1C13.2 1.8 10.7.7 8 .7S2.8 1.8 1 3.6l1.1 1.1C3.6 3.2 5.7 2.3 8 2.3z"/><path d="M8 5.5c1.4 0 2.7.6 3.7 1.5l1.1-1.1C11.5 4.7 9.8 3.9 8 3.9s-3.5.8-4.8 2l1.1 1.1c1-.9 2.3-1.5 3.7-1.5z"/><path d="M8 8.6c.6 0 1.1.2 1.5.6L8 10.8 6.5 9.2c.4-.4.9-.6 1.5-.6z"/></svg>
      <svg width="27" height="13" viewBox="0 0 27 13" fill="none"><rect x="0.5" y="0.5" width="23" height="12" rx="3.8" stroke="currentColor" opacity="0.4"/><rect x="2" y="2" width="20" height="9" rx="2.5" fill="currentColor"/><path d="M25 4.5v4c.8-.3 1.3-1.1 1.3-2s-.5-1.7-1.3-2z" fill="currentColor" opacity="0.45"/></svg>
    </div></div>`;
  }
  const homeIndicator = () => `<div class="pui-home-indicator" data-ui="home-indicator"></div>`;

  /** Screen frame: 393 × 852 logical, iOS status bar + home indicator. */
  function shell(name, body, { chrome = true } = {}) {
    return `<div class="pui pui-screen" data-ui="screen-${esc(name)}">${body}${chrome ? statusBar() + homeIndicator() : ""}</div>`;
  }
  /** Scroll region: content moves by translateY; films animate [data-ui="scroll-content"]. */
  const scroller = (top, content, scroll = 0, extraStyle = "") =>
    `<div class="pui-scroll" data-ui="scroll" style="top:${top}px;${extraStyle}"><div class="v pui-scroll-content" data-ui="scroll-content" style="transform:translateY(${-scroll}px)">${content}</div></div>`;
  /** Native-stack header (WalletStack screenOptions): BackButton left, Raleway 600 title. */
  const navbar = (title) => `<div class="v pui-navbar" data-ui="navbar"><div class="pui-navbar-left">${backButton({ ui: "navbar-back" })}</div><span class="t pui-navbar-title" data-ui="navbar-title">${esc(title)}</span></div>`;

  function topNavBar() {
    return `<div class="v r pui-topnav" data-ui="topnav"><div class="v pui-topnav-btn"><img class="pui-topnav-logo" src="${asset("Papayal-logoTag.png")}" alt="" data-ui="topnav-logo"></div><div class="v pui-topnav-btn">${icon("help-circle", 24, { ui: "topnav-help" })}</div></div>`;
  }

  // ------------------------------------------------------------------ screens ------------
  /** HomeScreen.tsx (signed in). Shelves built with buildMerchantShelves' rules. */
  function home({ scroll = 0, pressedTile = null } = {}) {
    const sender = D.people.sender;
    const shelves = [];
    const known = new Set(CATEGORIES.map((c) => c[0]));
    CATEGORIES.forEach(([key, label, glyph]) => {
      const ms = D.merchants.filter((m) => (m.categories || []).includes(key));
      if (ms.length) shelves.push({ key, label, glyph, ms });
    });
    const uncategorized = D.merchants.filter((m) => !(m.categories || []).some((k) => known.has(k)));
    if (uncategorized.length) shelves.push({ key: "otros", label: "Otros", glyph: "grid", ms: uncategorized });
    const order = [...(sender.interests || []).filter((k) => shelves.some((s) => s.key === k)), ...shelves.map((s) => s.key)];
    const ordered = [...new Set(order)].map((k) => shelves.find((s) => s.key === k));

    const header = `<div class="v pui-home-header" data-ui="home-header">
      ${topNavBar()}
      <span class="t pui-home-title" data-ui="home-title">Bienvenido</span>
      <span class="t sys pui-home-subtitle" data-ui="home-subtitle">Administra tus tarjetas y canjes fácilmente.</span>
      ${card(
        `<span class="t pui-hero-title" data-ui="hero-title">Tarjetas de regalo digitales para lo esencial en Ecuador.</span>
         <div class="v pui-hero-sub"><span class="t pui-hero-subtitle">Rápido. Seguro.</span><div class="v r pui-hero-action-row"><div class="v pui-hero-image-wrap"><img class="pui-hero-image" src="${asset("home-hero.webp")}" alt="" data-ui="hero-image"></div></div></div>
         <div class="v pui-flow" data-ui="hero-flow"><span class="t pui-flow-title">Cómo funciona</span><div class="v r pui-flow-steps">${[
           ["shopping-bag", "Elige una\ntienda", "elige"], ["send", "Envía la\ntarjeta", "envia"], ["map-pin", "Gasta\nlocalmente", "gasta"]
         ]
           .map(([g, l, k], i) => `${i ? `<span class="pui-flow-arrow">${icon("arrow-right", 20)}</span>` : ""}<div class="v pui-flow-step" data-ui="flow-${k}">${icon(g, 28)}<span class="t sys pui-flow-label">${esc(l)}</span></div>`)
           .join("")}</div></div>
         ${button({ label: "Comprar tarjeta de regalo", ui: "hero-cta", cls: "pui-hero-cta" })}`,
        { ui: "hero-card", cls: "pui-hero pui-home-card" }
      )}
    </div>`;

    const shelvesHtml = ordered
      .map(
        (s) => `<div class="v pui-shelf" data-ui="shelf-${s.key}"><div class="v r pui-shelf-header">${icon(s.glyph, 18)}<span class="t pui-shelf-title">${esc(s.label)}</span></div>
        <div class="v r pui-shelf-row" data-ui="shelf-${s.key}-row">${s.ms.map((m) => merchantGridCard({ merchantId: m.id, categoryLabel: s.label, pressed: pressedTile === m.id })).join("")}</div></div>`
      )
      .join("");

    const footer = `<div class="v pui-home-footer" data-ui="home-footer">
      ${card(`<span class="t pui-home-section-title">Cuenta</span><div class="v pui-home-userinfo"><span class="t pui-home-name">${esc(sender.name ?? "Usuario anónimo")}</span><span class="t sys pui-home-muted">${esc(sender.email)}</span>${sender.phone ? `<span class="t sys pui-home-muted">${esc(sender.phone)}</span>` : ""}</div>${button({ label: "Editar perfil", variant: "secondary", cls: "pui-home-button" })}`, { cls: "pui-home-card" })}
      ${card(`<span class="t pui-home-section-title">Acciones rápidas</span>${button({ label: "Ver mis tarjetas", cls: "pui-home-button" })}`, { cls: "pui-home-card" })}
    </div><div class="pui-home-list-end"></div>`;

    return shell("home", `<div class="pui-body">${scroller(0, header + shelvesHtml + footer, scroll)}${tabBar({ focused: "home" })}</div>`);
  }
  // Scroll offset (measured) at which the hero card's CTA and both shelves are on screen.
  home.SHELVES_SCROLL = 440;

  /** MerchantProfileScreen.tsx + merchant/merchantProfileUi.tsx (signed in, tab bar hidden). */
  function merchantProfile({ merchantId = D.purchase.merchant_id, selectedCents = D.purchase.amount_cents, ctaPressed = false, scroll = 0, hideExpiry = false } = {}) {
    const m = merchant(merchantId);
    const presets = (m.amount_presets || [500, 1000, 2500]).slice().sort((a, b) => a - b);
    const lowest = presets[0];
    const cats = (m.categories || []).map((c) => CATEGORY_LABEL[c] || c).join(" · ") || "Tarjeta de regalo";
    const steps = [
      ["tag", "Eliges el monto", "Define cuánto quieres enviar."],
      ["message-square", "Tu familia recibe un código", "Lo recibe listo para usar."],
      ["check-circle", "Lo canjea en el local", "Presenta el código al pagar."]
    ];
    const pills = [["shield", "Seguro"], ["check-circle", "Confiable"], ["zap", "Rápido"]];
    const content = `
      <div class="v pui-mp-hero-band" data-ui="hero-band">${merchantGiftCardHero({ merchantId, variant: "promo", hideExpiry })}</div>
      <div class="v pui-mp-title-block"><span class="t pui-mp-store" data-ui="store-name">${esc(merchantName(m))}</span><span class="t pui-mp-category" data-ui="store-category">${esc(cats)}</span><span class="t pui-mp-brandline" data-ui="store-brandline">Envía una tarjeta de regalo digital a tu familia en Ecuador.</span></div>
      <div class="v pui-mp-section"><span class="t pui-mp-section-title" data-ui="amount-title">Elige el monto</span>${amountChips({ presets, selectedCents })}</div>
      <div class="v pui-mp-steps" data-ui="steps-strip">${steps.map(([g, t, x], i) => `<div class="v r pui-mp-step" data-ui="step-${i + 1}"><div class="v pui-mp-step-icon">${icon(g, 18)}</div><span class="t pui-mp-step-title">${t}</span><span class="t pui-mp-step-text">${x}</span></div>`).join("")}</div>
      <div class="v r pui-mp-trust" data-ui="trust">${pills.map(([g, l]) => `<div class="v r pui-mp-pill">${icon(g, 15)}<span class="t pui-mp-pill-label">${l}</span></div>`).join("")}</div>
      <div class="v pui-mp-coverage"><span class="t pui-mp-section-title">Canje</span><div class="v r pui-mp-coverage-row" data-ui="coverage"><div class="v pui-mp-coverage-icon">${icon("map-pin", 19)}</div><span class="t pui-mp-coverage-text">Canjeable en comercios afiliados en Ecuador.</span></div></div>
      <div style="height:${90 + 16}px"></div>`;
    const cta = button({
      label: selectedCents ? `Enviar ${moneyCompact(selectedCents)}` : `Enviar tarjeta · desde ${moneyCompact(lowest)}`,
      pressed: ctaPressed,
      ui: selectedCents ? `cta-enviar` : "cta-enviar"
    });
    return shell(
      "merchant-profile",
      `<div class="pui-body"><div class="v" style="padding-top:59px">${`<div class="v pui-mp-header" data-ui="header"><div class="v r pui-appheader-top">${backButton()}</div></div>`}</div>
       ${scroller(115, content, scroll, "")}
       <div class="v pui-ctabar" data-ui="cta-bar">${cta}</div></div>`
    );
  }

  /** DeliveryProfileScreen.tsx (filled form; tab bar visible, Inicio). */
  function deliveryProfile({ scroll = 0, noteValue, noteFocused = false } = {}) {
    const P = D.purchase;
    const m = merchant(P.merchant_id);
    const r = D.people.recipient;
    const content = `<div class="v pui-screen-inner">
      ${checkoutHeader({
        step: "recipient",
        title: "Destinatario",
        subtitle: `¿Para quién es? Si ya tiene una tarjeta de ${merchantName(m)}, le añadimos el saldo.`,
        summary: [["Comercio", merchantName(m)], ["Monto", money(P.amount_cents)]]
      })}
      ${card(
        `<div class="v pui-dp-form">
          <div class="v r pui-dp-contacts" data-ui="contacts-row"><div class="v pui-dp-contacts-icon">${icon("users", 18)}</div><span class="t pui-dp-contacts-text">Elegir de mis contactos</span>${icon("chevron-right", 18)}</div>
          ${textField({ label: "Nombre completo", value: r.name, ui: "field-name" })}
          ${textField({ label: "Correo", value: r.email, ui: "field-email" })}
          ${phoneInput()}
          ${textField({ label: "Nota (opcional)", value: noteValue === undefined ? r.note : noteValue, placeholder: "Añade un mensaje corto", multiline: true, focused: noteFocused, ui: "field-note" })}
          <span class="t sys pui-dp-helper" data-ui="note-helper">Máximo 140 caracteres. Se mostrará al destinatario.</span>
        </div>`,
        { ui: "form-card", cls: "pui-dp-card" }
      )}
      ${button({ label: "Continuar", tall: true, ui: "cta-continuar" })}
    </div><div style="height:144px"></div>`;
    return shell("delivery-profile", `<div class="pui-body">${scroller(59, content, scroll)}${tabBar({ focused: "home" })}</div>`);
  }
  // Scroll offset (measured) at which the note, helper text and "Continuar" clear the tab bar.
  deliveryProfile.END_SCROLL = 200;

  /** PurchaseSuccessScreen.tsx (first card to Rosa; tab bar visible, Inicio). */
  function purchaseSuccess() {
    const content = `<div class="v" style="min-height:${852 - 59}px;padding-bottom:144px"><div class="v pui-screen-inner pui-screen-center">
      <div class="v r pui-ps-nav"><div class="v pui-ps-close" data-ui="close">${icon("x", 22)}</div></div>
      ${successBlock()}
    </div></div>`;
    return shell("purchase-success", `<div class="pui-body">${scroller(59, content)}${tabBar({ focused: "home" })}</div>`);
  }

  /** ClaimLandingScreen.tsx (signed out, Auth stack: no tab bar). */
  function claimLanding() {
    const C = D.claim;
    const m = merchant(C.merchant_id);
    const who = C.sender_first_name || "Alguien";
    const title = C.teaser || (C.is_reload ? `${who} recargó tu tarjeta de ${merchantName(m)} con ${money(C.amount_cents)}` : `${who} te envió una tarjeta de regalo digital de ${merchantName(m)}`);
    const bannerMsg = C.recipient_masked_phone
      ? `Crea tu cuenta con el número ${C.recipient_masked_phone} y confirma el código de verificación para ${C.is_reload ? "ver tu saldo" : "recibirla"}.`
      : "Crea tu cuenta con el número o correo que recibió el mensaje y confirma el código de verificación.";
    const actions = C.recipient_registered
      ? button({ label: C.is_reload ? "Iniciar sesión y ver mi tarjeta" : "Iniciar sesión y ver mi regalo", ui: "cta-primary" }) + button({ label: "Crear cuenta", variant: "ghost", ui: "cta-secondary" })
      : button({ label: C.is_reload ? "Crear cuenta y ver mi tarjeta" : "Crear cuenta y reclamar", ui: "cta-primary" }) + button({ label: "Ya tengo cuenta", variant: "ghost", ui: "cta-secondary" });
    const inner = card(
      `<div class="v pui-cl-badge" data-ui="gift-badge"><span class="t pui-cl-emoji" data-ui="gift-emoji">🎁</span></div>
       <span class="t pui-cl-title" data-ui="claim-title">${esc(title)}</span>
       ${claimMerchantRow({ merchantId: C.merchant_id })}
       <span class="t pui-cl-amount" data-ui="claim-amount">${money(C.amount_cents)}</span>
       ${C.note ? `<div class="v pui-note-box" data-ui="claim-note"><span class="t pui-cl-note">“${esc(C.note.trim())}”</span></div>` : ""}
       ${banner({ iconName: "shield", title: "Reclamo seguro", message: bannerMsg, ui: "claim-banner", cls: "pui-cl-banner" })}
       <div class="v pui-cl-actions">${actions}</div>`,
      { ui: "claim-card", cls: "pui-cl-card" }
    );
    const content = `<div class="v" style="min-height:${852 - 59}px;padding-bottom:144px"><div class="v pui-screen-inner pui-screen-center">${inner}</div></div>`;
    return shell("claim-landing", `<div class="pui-body">${scroller(59, content)}</div>`);
  }

  /** GiftCardScreen.tsx (Rosa's card; Wallet stack native header; tab bar visible). */
  function giftCard({ scroll = 0, tabBarVisible = true, hideExpiry = false } = {}) {
    const G = D.giftCard;
    const m = merchant(G.merchant_id);
    const loads = G.loads
      .map((l, i) => {
        const who = senderShortName(l.sender.full_name);
        return `<div class="v pui-load" data-ui="load-${i + 1}"><div class="v r pui-load-top">${avatar(who, 40, `load-${i + 1}-avatar`)}<div class="v pui-load-text"><span class="t nowrap pui-load-who">${esc(who)}</span><span class="t sys pui-load-meta">${esc(day(l.created_at))}</span></div><div class="v pui-load-amount-col"><span class="t pui-load-amount">${money(l.amount_cents)}</span></div></div>${
          l.note ? `<span class="t pui-load-note" data-ui="load-${i + 1}-note">“${esc(l.note.trim())}”</span>` : ""
        }</div>`;
      })
      .join("");
    const content = `<div class="v pui-gc-content">
      <div class="v pui-gc-headblock" data-ui="balance-block"><span class="t pui-gc-total-label">Disponible</span><span class="t pui-gc-total-value" data-ui="balance">${money(G.spendable_cents)}</span></div>
      ${merchantGiftCardHero({ merchantId: G.merchant_id, variant: "owned", spendableCents: G.spendable_cents, hideExpiry })}
      <div class="v pui-gc-strips"></div>
      <div class="v pui-gc-section" data-ui="loads"><span class="t pui-gc-section-title">Recargas</span><div class="v pui-gc-section-body">${loads}</div></div>
    </div><div style="height:${34 + 130}px"></div>`;
    return shell(
      "gift-card",
      `<div class="pui-body">${navbar(merchantName(m))}${scroller(103, content, scroll)}
       <div class="v pui-ctabar pui-ctabar--stack" data-ui="cta-bar">${button({ label: "Canjear en tienda", ui: "cta-canjear" })}${button({ label: "Recargar", variant: "ghost", ui: "cta-recargar" })}</div>
       ${tabBarVisible ? tabBar({ focused: "wallet" }) : ""}</div>`
    );
  }

  /** RedemptionTokenScreen.tsx — state: showing | celebrating | finished. */
  function redemptionToken({ state = "showing", hideExpiry = false } = {}) {
    const R = D.redemption;
    const m = merchant(R.merchant_id);
    let content;
    if (state === "finished") {
      content = `<div class="v pui-screen-inner pui-screen-center" style="height:${852 - 103}px;flex:none"><div class="v" style="width:100%" data-ui="finished">${card(
        `<div class="v pui-rt-finished-icon">${icon("check-circle", 44)}</div><span class="t pui-rt-finished-title" data-ui="finished-title">¡Listo!</span><span class="t sys pui-rt-finished-sub" data-ui="finished-body">${esc(`Canjeaste ${money(R.redeemed_cents)} en ${merchantName(m)}.`)}</span>${button({ label: "Volver a mis tarjetas", ui: "cta-volver", cls: "pui-rt-finished-button" })}`,
        { ui: "finished-card", cls: "pui-rt-finished" }
      )}</div></div>`;
    } else {
      content = `<div class="v pui-screen-inner">${card(
        `<span class="t pui-rt-title" data-ui="rt-title">${esc(`Tarjeta de ${merchantName(m)}`)}</span>
         <span class="t pui-rt-subtitle" data-ui="rt-subtitle">Muestra este código en caja</span>
         ${redemptionCode({ state, hideExpiry })}
         ${state === "showing" ? button({ label: "Generar otro código", ui: "cta-regenerar", cls: "pui-rt-button" }) : ""}`,
        { ui: "code-card" }
      )}</div><div style="height:144px"></div>`;
    }
    return shell("redemption-token", `<div class="pui-body">${navbar("Canjear en tienda")}${scroller(103, content)}${tabBar({ focused: "wallet" })}</div>`);
  }

  // ------------------------------------------------------------------ device -------------
  /** DeviceFrame: the standard film device (device/SOURCE.md). `inner` is the 393 × 852 UI
   *  (a screen from PapayalUI.screens, or a film's own stack of screen containers). Returns the
   *  device at 1470 × 3000 device px; scale it with a transform (transform-origin 0 0). */
  function deviceFrame(inner, { ui: u = "device" } = {}) {
    return `<div class="pui pui-device"${ui(u)}><div class="pui-device-screen"${ui(`${u}-screen`)}><div class="pui-device-ui"${ui(`${u}-ui`)}>${inner}</div></div><img class="pui-device-bezel" src="${asset("../device/iphone-18-pro-max-black.png")}" alt=""${ui(`${u}-bezel`)}></div>`;
  }
  /** Geometry for camera maths: a UI point → device px, and the device's size. */
  deviceFrame.GEOMETRY = { width: 1470, height: 3000, screen: { x: 75, y: 66, w: 1320, h: 2868 }, uiScale: 2868 / 852, uiOffsetX: -1.458 };
  deviceFrame.uiToDevice = (px, py) => {
    const G = deviceFrame.GEOMETRY;
    return { x: G.screen.x + G.uiOffsetX + px * G.uiScale, y: G.screen.y + py * G.uiScale };
  };

  // ------------------------------------------------------------------ registry -----------
  const SCREENS = { home, merchantProfile, deliveryProfile, purchaseSuccess, claimLanding, giftCard, redemptionToken };
  const COMPONENTS = { deviceFrame, caret, statusBar, homeIndicator, mark, claimMerchantRow, listRow, listGroup, button, backButton, card, banner, merchantGridCard, merchantGiftCardHero, amountChips, tabBar, checkoutHeader, textField, phoneInput, redemptionCode, successBlock, avatar, icon, spinner };

  const PapayalUI = {
    get base() { return base; },
    set base(v) { base = v.endsWith("/") ? v : v + "/"; },
    screens: SCREENS,
    components: COMPONENTS,
    format: { money, moneyCompact, day, initials, senderShortName },
    /** Render a screen into `target` (replaces its children). Returns the .pui-screen element. */
    mount(target, screen, opts) {
      const fn = SCREENS[screen];
      if (!fn) throw new Error(`PapayalUI: unknown screen "${screen}"`);
      target.innerHTML = fn(opts);
      return target.firstElementChild;
    },
    /** Render a lone component inside a .pui wrapper (for galleries / overlays). */
    component(target, name, opts) {
      const fn = COMPONENTS[name];
      if (!fn) throw new Error(`PapayalUI: unknown component "${name}"`);
      target.innerHTML = `<div class="pui">${fn(opts)}</div>`;
      return target.firstElementChild;
    }
  };

  if (typeof module !== "undefined" && module.exports) module.exports = PapayalUI;
  root.PapayalUI = PapayalUI;
})(typeof window !== "undefined" ? window : globalThis);
