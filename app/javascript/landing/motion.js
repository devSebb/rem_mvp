/*
 * The app's real motion, as named constants. Every entry cites its source in papayal-mobile
 * and carries both the EXACT curve (usable directly as a GSAP ease) and a plain GSAP-string
 * approximation for quick work. Films tune their own transitions to these; UI states come
 * from components.js.
 *
 *   gsap.to(el, { x: 128, duration: M.tabIndicator.duration, ease: M.tabIndicator.ease })
 *   gsap.to(el, { x: 128, duration: 0.3, ease: M.tabIndicator.gsap })   // approximation
 *
 * Springs: Reanimated 4.1 `withSpring` physics (src/animation/spring/spring.ts). A config
 * without `mass` gets Reanimated 4's default mass = 4 (GentleSpringConfig), not 1.
 * The animation ends when spring energy falls to 6e-9 of the start energy.
 */
(function (root) {
  const ENERGY_THRESHOLD = 6e-9;

  /** Exact under/critically damped spring from 0 → 1, zero initial velocity.
   *  Returns { ease(t∈[0,1]) → progress, duration (s), zeta, overshoot, visualSettle (s) }. */
  function spring({ damping, stiffness, mass = 4 }) {
    const w0 = Math.sqrt(stiffness / mass);
    const zeta = damping / (2 * Math.sqrt(stiffness * mass));
    const pos = (t) => {
      if (zeta < 1) {
        const wd = w0 * Math.sqrt(1 - zeta * zeta);
        return 1 - Math.exp(-zeta * w0 * t) * (Math.cos(wd * t) + ((zeta * w0) / wd) * Math.sin(wd * t));
      }
      return 1 - Math.exp(-w0 * t) * (1 + w0 * t);
    };
    const vel = (t, h = 1e-4) => (pos(t + h) - pos(t)) / h;
    const energy = (t) => 0.5 * stiffness * (1 - pos(t)) ** 2 + 0.5 * mass * vel(t) ** 2;
    const e0 = 0.5 * stiffness; // displacement 1, velocity 0
    let duration = 0;
    while (duration < 10 && energy(duration) / e0 > ENERGY_THRESHOLD) duration += 1 / 240;
    let peak = 0;
    let visualSettle = 0;
    for (let t = 0; t <= duration; t += 1 / 240) {
      const p = pos(t);
      peak = Math.max(peak, p);
      if (Math.abs(1 - p) > 0.01) visualSettle = t; // last time outside ±1 %
    }
    return {
      ease: (t) => (t >= 1 ? 1 : pos(t * duration)),
      duration: +duration.toFixed(3),
      visualSettle: +visualSettle.toFixed(3),
      zeta: +zeta.toFixed(3),
      overshoot: +Math.max(0, peak - 1).toFixed(3)
    };
  }

  /** CSS/RN cubic-bezier as an ease function (RN Easing.bezier is the same curve). */
  function cubicBezier(x1, y1, x2, y2) {
    const bx = (t) => 3 * x1 * t * (1 - t) ** 2 + 3 * x2 * t * t * (1 - t) + t ** 3;
    const by = (t) => 3 * y1 * t * (1 - t) ** 2 + 3 * y2 * t * t * (1 - t) + t ** 3;
    return (x) => {
      if (x <= 0) return 0;
      if (x >= 1) return 1;
      let lo = 0, hi = 1, t = x;
      for (let i = 0; i < 40; i++) {
        t = (lo + hi) / 2;
        if (bx(t) < x) lo = t; else hi = t;
      }
      return by(t);
    };
  }
  // RN Easing.ease = bezier(0.42, 0, 1, 1); Easing.inOut(f) mirrors f.
  const rnEase = cubicBezier(0.42, 0, 1, 1);
  const rnInOutEase = (t) => (t < 0.5 ? rnEase(t * 2) / 2 : 1 - rnEase((1 - t) * 2) / 2);

  const tabIndicator = spring({ damping: 18, stiffness: 240, mass: 0.6 });
  const tabIndex = spring({ damping: 16, stiffness: 200, mass: 0.7 });
  const tabPanReturn = spring({ damping: 15, stiffness: 140 });
  const tilePress = spring({ damping: 15, stiffness: 300 });

  const MOTION = {
    spring,
    cubicBezier,

    // ---- AnimatedTabBar (src/ui/components/AnimatedTabBar.tsx) --------------------------
    tabIndicator: {
      source: "AnimatedTabBar.tsx:88 withSpring(index*tabWidth+offset, {damping:18, stiffness:240, mass:0.6})",
      what: "cream indicator pill slides to the focused tab (translateX)",
      ...tabIndicator,
      gsap: "back.out(1.1)" // over ~0.3 s
    },
    tabIndex: {
      source: "AnimatedTabBar.tsx:94 withSpring(index, {damping:16, stiffness:200, mass:0.7})",
      what: "drives every tab's icon scale 0.94→1.2, icon color navbarMuted→secondary, icon opacity 0.5→1, label color navbarMuted→primary, label opacity 0.7→1 (interpolated by distance from the focused index, clamped)",
      iconScale: { unfocused: 0.94, focused: 1.2 },
      iconOpacity: { unfocused: 0.5, focused: 1 },
      labelOpacity: { unfocused: 0.7, focused: 1 },
      ...tabIndex,
      gsap: "back.out(1.3)" // over ~0.35 s
    },
    tabSwipe: {
      source: "AnimatedTabBar.tsx:136-164 Gesture.Pan",
      what: "rail translateX = pan×0.05, rail scale 1→0.96 over |pan| 0–120 px, indicator += pan×0.12; |pan| > 52 px switches tab; release springs pan back to 0",
      switchThreshold: 52,
      railFollow: 0.05,
      indicatorFollow: 0.12,
      railScale: { atPan: 120, scale: 0.96 },
      release: { source: "withSpring(0, {damping:15, stiffness:140}) — default mass 4", ...tabPanReturn, gsap: "elastic.out(1, 0.6)" }
    },

    // ---- Press feedback ------------------------------------------------------------------
    tilePress: {
      source: "MerchantGridCard.tsx:23,59-62 withSpring(0.97 | 1, {damping:15, stiffness:300}) — default mass 4",
      what: "merchant shelf tile scales to 0.97 on press-in and springs back to 1 on release (the only press-scale in the app)",
      pressedScale: 0.97,
      ...tilePress,
      gsap: "elastic.out(1, 0.5)"
    },
    buttonPress: {
      source: "Button.tsx:100-105",
      what: "Button: opacity 0.9 while pressed, 0.5 disabled. No scale, no timing (instant state swap)",
      pressedOpacity: 0.9,
      disabledOpacity: 0.5,
      duration: 0
    },
    backPress: { source: "BackButton.tsx:67-72", what: "teal 8% disc behind the arrow while pressed; disabled opacity 0.4", duration: 0 },
    rowPress: { source: "ListRow.tsx:135-137", what: "row background becomes --hc-pressed-row while pressed (iOS)", duration: 0 },

    // ---- Loading ---------------------------------------------------------------------------
    skeletonPulse: {
      source: "StateViews.tsx:27-42 Animated.loop(timing 1→0.5 500ms, 0.5→1 500ms, Easing.inOut(Easing.ease))",
      what: "every SkeletonBlock pulses opacity in sync",
      from: 1, to: 0.5, halfPeriod: 0.5,
      ease: rnInOutEase,
      gsap: "power1.inOut" // close to RN inOut(ease)
    },

    // ---- Redemption (src/screens/RedemptionTokenScreen.tsx) ---------------------------------
    celebrateFadeIn: {
      source: "RedemptionTokenScreen.tsx:308 entering={FadeIn.duration(200)}",
      what: "\"¡Canje completo!\" overlay fades in over the code",
      duration: 0.2,
      ease: (t) => (t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2),
      gsap: "power1.inOut" // exact: Reanimated withTiming default Easing.inOut(Easing.quad)
    },
    celebrateHold: {
      source: "RedemptionTokenScreen.tsx:37 CELEBRATE_MS = 1600",
      what: "the overlay holds before the screen switches to the \"¡Listo!\" card",
      duration: 1.6
    },
    finishedFadeIn: {
      source: "RedemptionTokenScreen.tsx:228 entering={FadeIn.duration(250)}",
      what: "\"¡Listo!\" card fades in (screen content swaps instantly underneath)",
      duration: 0.25,
      ease: (t) => (t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2),
      gsap: "power1.inOut"
    },
    balancePoll: {
      source: "useBalanceCaptureDetector.ts:6 BALANCE_POLL_MS = 4000",
      what: "the app notices a merchant capture on its next 4 s balance poll (so 0–4 s after the cashier scans)",
      interval: 4
    },
    regenerateCooldown: { source: "RedemptionTokenScreen.tsx:213 setCooldown(4)", what: "\"Espera Ns antes de regenerar.\" counts down from 4", seconds: 4 },

    // ---- Welcome (src/screens/WelcomeScreen.tsx) — the app's only choreographed intro ------
    welcome: {
      source: "WelcomeScreen.tsx:34-120",
      hero: { delay: 0, duration: 0.9, y: 20, ease: "power2.out", what: "logo + wordmark: opacity 0→1, y 20→0, Easing.out(Easing.cubic)" },
      logoFloat: { duration: 1.8, y: -7, ease: rnInOutEase, gsap: "power1.inOut", yoyo: true, repeat: -1, what: "logo bobs 0 ↔ −7 px" },
      headline: { delay: 1.1, duration: 0.65, y: 20, ease: cubicBezier(0.2, 0.9, 0.25, 1), gsap: "expo.out", what: "Easing.bezier(0.2, 0.9, 0.25, 1)" },
      subhead: { delay: 1.1 + 0.65 + 0.08, duration: 0.56, y: 16, ease: "power2.out" },
      ctas: { delay: 1.1 + 0.65 + 0.08 + 0.56 + 0.09, duration: 0.42, y: 18, ease: "power2.out" },
      trustChips: { delay: 1.9, stagger: 0.1, duration: 0.45, y: 8, ease: "power2.out" },
      ctaGlow: { delay: 2.8, duration: 1.2, shadowOpacity: [0, 0.34], ease: rnInOutEase, gsap: "power1.inOut", yoyo: true, repeat: -1 }
    },

    // ---- Navigation (native stack / modals: platform defaults, not in app code) -----------
    screenPush: {
      source: "navigation/index.tsx: native-stack default; CompleteDetails + PurchaseSuccess use animation:'slide_from_right'. The behaviour itself is UIKit's (platform), not app code — values are approximations of UINavigationController's default push.",
      what: "iOS push: the incoming screen slides in from the right edge casting a soft shadow from its left edge; the outgoing screen shifts ~30 % left underneath it and dims slightly. Pop is the reverse.",
      duration: 0.35,
      gsap: "power3.out", // approximation of UIKit's push curve
      parallax: 0.3, // outgoing screen travels 30 % of the width
      dim: "var(--ios-push-dim)", // tokens.css: black 10 % over the outgoing screen
      edgeShadow: "var(--ios-push-edge-shadow)" // tokens.css: on the incoming screen while it moves
    },
    /** Add an iOS push to a GSAP timeline. `outEls`/`inEls`: element(s) of the screens.
     *  Creates the dim layer inside each outgoing screen. Seek-safe (fromTo + sets). */
    iosPush(tl, outEls, inEls, at, { width = 393 } = {}) {
      const P = MOTION.screenPush;
      const list = (x) => (x instanceof Element ? [x] : Array.from(x));
      const outs = list(outEls), ins = list(inEls);
      outs.forEach((el) => {
        let dim = Array.from(el.children).find((c) => c.classList.contains("pui-push-dim"));
        if (!dim) { dim = document.createElement("div"); dim.className = "pui-push-dim"; el.appendChild(dim); }
        tl.fromTo(el, { x: 0 }, { x: -width * P.parallax, duration: P.duration, ease: P.gsap, immediateRender: false }, at);
        tl.fromTo(dim, { opacity: 0 }, { opacity: 1, duration: P.duration, ease: P.gsap, immediateRender: false }, at);
        tl.set(el, { autoAlpha: 0 }, at + P.duration);
      });
      ins.forEach((el) => {
        tl.fromTo(el, { x: width }, { x: 0, duration: P.duration, ease: P.gsap, immediateRender: false }, at);
        tl.set(el, { boxShadow: P.edgeShadow }, at);
        tl.set(el, { boxShadow: "none" }, at + P.duration);
      });
    },
    caretBlink: {
      source: "UIKit text caret (platform, approx.): solid while typing, blinks when idle",
      what: "iOS caret: stays solid while characters are being entered; after ~0.5 s idle it blinks — 0.5 s on, 0.5 s off, with short ~0.1 s fades",
      period: 1.0,
      on: 0.5,
      fade: 0.1,
      idleBeforeBlink: 0.5,
      /** Caret opacity at time `t` given the last keystroke at `lastKey` (seconds). */
      opacityAt(t, lastKey) {
        const idle = t - lastKey - 0.5;
        if (idle < 0) return 1;
        const ph = idle % 1.0;
        if (ph < 0.5) return 1;
        if (ph < 0.6) return 1 - (ph - 0.5) / 0.1;
        if (ph < 0.9) return 0;
        return (ph - 0.9) / 0.1;
      }
    },
    tabSwitch: { source: "@react-navigation/bottom-tabs v6 default", what: "screen content CUTS on tab change; only the bar animates", duration: 0 },
    sheetSlide: { source: "ContactPickerModal/CountryPickerModal <Modal animationType=\"slide\">", what: "bottom sheet slides up over a 50 % black scrim (platform timing, approx.)", duration: 0.3, gsap: "power3.out" },
    faqExpand: { source: "HelpScreen.tsx:252 LayoutAnimation.Presets.easeInEaseOut", what: "FAQ rows expand", duration: 0.3, gsap: "power1.inOut" },

    // No animation in the app for: amount-chip select, CTA label change, success check,
    // purchase success card, claim reveal. Those are instant state swaps.
    instant: ["amount chip select", "CTA label change", "PurchaseSuccess mount", "ClaimLanding mount", "step progress change"]
  };

  if (typeof module !== "undefined" && module.exports) module.exports = MOTION;
  root.PAPAYAL_UI_MOTION = MOTION;
})(typeof window !== "undefined" ? window : globalThis);
