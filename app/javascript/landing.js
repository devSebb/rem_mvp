// Public landing: a scroll story over the real app screens, animated with GSAP + ScrollTrigger.
// Loaded only by marketing/landing.html.erb. The kit in ./landing is copied from
// papayal-motion/brand/ui (an HTML rebuild of papayal-mobile); phone screens stay in Spanish.
import { gsap } from "gsap"
import { ScrollTrigger } from "gsap/ScrollTrigger"
import "./landing/placeholders.js"
import "./landing/icons.js"
import "./landing/components.js"
import "./landing/motion.js"

const ASSET_ROOT = "/marketing/landing/"
window.PAPAYAL_UI_BASE = ASSET_ROOT

function start() {
  if (!document.querySelector("[data-landing]")) return

  gsap.registerPlugin(ScrollTrigger)
  ScrollTrigger.config({ ignoreMobileResize: true })

  const UI = window.PapayalUI
  const M = window.PAPAYAL_UI_MOTION
  const D = window.PAPAYAL_UI_DATA
  const $ = (s, r = document) => r.querySelector(s)
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s))
  const q = (screen, name) => screen.querySelector(`[data-ui="${name}"]`)
  const nav = $("[data-nav]")

  // ------------------------------------------------------------ static decoration ---------
  // Card back: concentric papaya rings (brand/card.html), stroke kept optically constant.
  const rings = $("[data-back-rings]")
  for (let i = 0; i < 13; i++) {
    const s = 0.42 + 0.3 * i
    rings.insertAdjacentHTML("beforeend", `<use href="#papaya" transform="translate(500 315.25) scale(${s.toFixed(2)}) translate(-268.723 -268.723)" style="stroke-width:${(7 / s).toFixed(3)}"/>`)
  }
  // Category marks, exactly as the app draws them.
  $$("[data-mark]").forEach((li) => { $(".cat-mark", li).innerHTML = UI.components.mark(li.dataset.mark) })

  const onScroll = () => nav.classList.toggle("is-scrolled", scrollY > 8)
  addEventListener("scroll", onScroll, { passive: true })
  onScroll()

  // ------------------------------------------------------------ helpers -------------------
  /** A device with stacked app screens. Screens render at 393 × 852 and are zoomed to fit. */
  function makePhone(host) {
    host.innerHTML = `<div class="phone-screen"><div class="phone-stack"></div></div><img class="phone-bezel" src="${ASSET_ROOT}device/iphone.webp" alt="">`
    const screen = $(".phone-screen", host)
    const stack = $(".phone-stack", host)
    const fit = () => stack.style.setProperty("--ui-scale", (screen.clientHeight / 852).toFixed(4))
    const ro = new ResizeObserver(fit)
    ro.observe(screen)
    fit()
    return {
      add(name, opts) { stack.insertAdjacentHTML("beforeend", UI.screens[name](opts)); return stack.lastElementChild },
      destroy() { ro.disconnect(); host.innerHTML = "" }
    }
  }

  /** Finger tap: a soft dot that lands on `el` and releases (optionally on its twin `outEl`). */
  function dot(el) {
    let d = el.querySelector(":scope > .tap")
    if (!d) { d = document.createElement("span"); d.className = "tap"; el.appendChild(d) }
    return d
  }
  function tap(tl, el, at, outEl = el) {
    const a = dot(el), b = dot(outEl)
    tl.fromTo(a, { scale: 0.5, opacity: 0 }, { scale: 1, opacity: 1, duration: 0.12, ease: "power2.out", immediateRender: false }, at)
    if (a !== b) tl.set(a, { opacity: 0 }, at + 0.15).set(b, { scale: 1, opacity: 1 }, at + 0.15)
    tl.to(b, { scale: 1.5, opacity: 0, duration: 0.3, ease: "power2.out" }, at + 0.17)
  }
  /** Button.tsx press: opacity 0.9, instant (motion.js buttonPress). */
  function press(tl, el, at) {
    tl.set(el, { opacity: M.buttonPress.pressedOpacity }, at).set(el, { opacity: 1 }, at + 0.16)
  }
  /** UIKit push between two stacked screens (motion.js iosPush). */
  function push(tl, from, to, at) {
    tl.set(to, { autoAlpha: 1 }, at)
    M.iosPush(tl, from, to, at)
  }
  /** The logo's thick orange ring as a shockwave: grows, thins, fades. */
  function shock(tl, svg, at, { dur = 0.9, from = 8, to = 49, w = 10 } = {}) {
    const c = $("circle", svg)
    tl.fromTo(c, { attr: { r: from }, strokeWidth: w, opacity: 1 }, { attr: { r: to }, strokeWidth: 0.3, opacity: 0, duration: dur, ease: "power2.out", immediateRender: false }, at)
  }
  /** Step captions: desktop lights the active row and fills the rail; mobile swaps one caption. */
  function stepper(tl, section, desk) {
    const steps = $$(".step", section)
    const list = $("[data-steps]", section)
    gsap.set(list, { "--fill": 0 })
    return (i, at) => {
      steps.forEach((s, j) => {
        if (desk) tl.to(s, { opacity: j === i ? 1 : 0.32, duration: 0.3, ease: "power1.inOut" }, at)
        else tl.to(s, { autoAlpha: j === i ? 1 : 0, y: j === i ? 0 : j < i ? -14 : 14, duration: 0.3, ease: "power2.out" }, at)
      })
      if (desk) tl.to(list, { "--fill": i / (steps.length - 1), duration: 0.4, ease: "power2.inOut" }, at)
    }
  }
  // Momentum/directional snap skipped whole steps; labels + no inertia lands on each one.
  const snap = { snapTo: "labels", inertia: false, duration: { min: 0.2, max: 0.7 }, delay: 0.08, ease: "power2.inOut" }

  // Nav turns dark over teal. Reads scroll position, not the scrubbed timeline.
  const dark = new Set()
  const setDark = (key, on) => { on ? dark.add(key) : dark.delete(key); nav.classList.toggle("is-dark", dark.size > 0) }
  const darkZone = (key, trigger) => ScrollTrigger.create({
    trigger, start: () => `top top+=${nav.offsetHeight}`, end: () => `bottom top+=${nav.offsetHeight}`, onToggle: (s) => setDark(key, s.isActive)
  })

  // ------------------------------------------------------------ hero ----------------------
  function heroIntro() {
    const card = $("[data-hero-card]")
    const sweep = $("[data-sweep]")
    gsap.set(sweep, { xPercent: -70 })
    const tl = gsap.timeline({ defaults: { ease: "expo.out" } })
    tl.from(".hero-title .line > span", { yPercent: 115, duration: 1.05, stagger: 0.09 }, 0.1)
      .fromTo(".hero .hl", { backgroundSize: "0% 78%" }, { backgroundSize: "100% 78%", duration: 0.7, ease: "power3.inOut" }, 0.6)
      .from("[data-intro]", { y: 24, opacity: 0, duration: 0.8, stagger: 0.08 }, 0.5)
      .fromTo(card, { scale: 0.55, rotation: -22, opacity: 0 }, { scale: 1, rotation: -5, opacity: 1, duration: 1.1, ease: "power3.inOut" }, 0.35)
      .from("[data-gc-shadow]", { opacity: 0, duration: 0.8, ease: "power2.out" }, 0.9)
      .to(sweep, { xPercent: 70, duration: 1.1, ease: "power2.inOut" }, 1.25)
      .from("[data-hero-art] [data-notif]", { y: -26, opacity: 0, scale: 0.94, duration: 0.6, ease: "back.out(1.7)" }, 1.45)
      .from("[data-pill]", { scale: 0.4, opacity: 0, duration: 0.6, ease: "back.out(2.2)" }, 1.65)
      .from("[data-hint]", { opacity: 0, duration: 0.6 }, 2.2)
    shock(tl, $("[data-hero-art] [data-shock]"), 0.35, { dur: 1.15, w: 9 })
    tl.add(() => {
      gsap.to(card, { y: -7, duration: 2.6, yoyo: true, repeat: -1, ease: "sine.inOut" })
      gsap.to("[data-hero-art] [data-notif]", { y: 6, duration: 3.1, yoyo: true, repeat: -1, ease: "sine.inOut" })
      gsap.to("[data-pill]", { y: -5, duration: 2.2, yoyo: true, repeat: -1, ease: "sine.inOut", delay: 0.4 })
    })
  }

  function heroInteract() {
    const art = $("[data-hero-art]")
    const card = $("[data-hero-card]")
    const tilt = $("[data-gc-tilt]")
    const gc = $("[data-gc]")
    const shadow = $("[data-gc-shadow]")
    let flipped = false
    const onClick = () => {
      flipped = !flipped
      card.setAttribute("aria-pressed", String(flipped))
      gsap.to(gc, { rotationY: flipped ? 180 : 0, duration: 0.9, ease: "power3.inOut" })
      gsap.fromTo(card, { scale: 1 }, { scale: 1.04, duration: 0.45, yoyo: true, repeat: 1, ease: "power2.inOut" })
      gsap.to("[data-hint]", { opacity: 0, duration: 0.3 })
    }
    card.addEventListener("click", onClick)
    const fine = matchMedia("(hover: hover) and (pointer: fine)").matches
    let onMove, onLeave
    if (fine) {
      const rx = gsap.quickTo(tilt, "rotationX", { duration: 0.7, ease: "power3.out" })
      const ry = gsap.quickTo(tilt, "rotationY", { duration: 0.7, ease: "power3.out" })
      const sx = gsap.quickTo(shadow, "x", { duration: 0.9, ease: "power3.out" })
      onMove = (e) => {
        const r = art.getBoundingClientRect()
        const px = (e.clientX - r.left) / r.width - 0.5
        const py = (e.clientY - r.top) / r.height - 0.5
        ry(px * 24); rx(-py * 18); sx(-px * 40)
      }
      onLeave = () => { rx(0); ry(0); sx(0) }
      art.addEventListener("pointermove", onMove)
      art.addEventListener("pointerleave", onLeave)
    }
    return () => {
      card.removeEventListener("click", onClick)
      if (onMove) { art.removeEventListener("pointermove", onMove); art.removeEventListener("pointerleave", onLeave) }
    }
  }

  function heroScroll() {
    gsap.to("[data-hero-art]", { yPercent: -10, ease: "none", scrollTrigger: { trigger: ".hero", start: "top top", end: "bottom top", scrub: true } })
    gsap.to(".hero-copy", { y: -40, opacity: 0.4, ease: "none", scrollTrigger: { trigger: ".hero", start: "40% top", end: "bottom top", scrub: true } })
  }

  // ------------------------------------------------------------ Así envías ----------------
  function buildSend(desk) {
    const sec = $(".story-send")
    const stage = $("[data-stage]", sec)
    const P = makePhone($('[data-phone="send"]', sec))
    const sHome = P.add("home")
    const sPick = P.add("merchantProfile", { selectedCents: null, hideExpiry: true })
    const sPicked = P.add("merchantProfile", { selectedCents: 2500, hideExpiry: true })
    const sTo = P.add("deliveryProfile", { noteValue: "", noteFocused: true })
    const sDone = P.add("purchaseSuccess")
    gsap.set([sPick, sPicked, sTo, sDone], { autoAlpha: 0 })

    const tl = gsap.timeline({
      defaults: { ease: "power2.inOut" },
      scrollTrigger: { trigger: sec, start: "top top", end: () => `+=${innerHeight * 3.4}`, pin: stage, scrub: 0.7, snap, anticipatePin: 1, invalidateOnRefresh: true }
    })
    const step = stepper(tl, sec, desk)

    // 01 Elige el comercio: scroll Home to the shelves, tap Farmacia.
    tl.addLabel("s0", 0)
    tl.to(q(sHome, "scroll-content"), { y: -UI.screens.home.SHELVES_SCROLL, duration: 1.2 }, 0.3)
    const tile = q(sHome, "tile-farmacia-card")
    tap(tl, tile, 1.6)
    tl.to(tile, { scale: M.tilePress.pressedScale, duration: 0.1, ease: "power1.out" }, 1.6)
      .to(tile, { scale: 1, duration: 0.4, ease: M.tilePress.gsap }, 1.72)
    push(tl, sHome, sPick, 1.95)

    // 02 Elige el monto: $25 (instant swap, like the app), then "Enviar $25".
    step(1, 2.1)
    tl.addLabel("s1", 2.7)
    tap(tl, q(sPick, "chip-25"), 2.85, q(sPicked, "chip-25"))
    tl.set(sPicked, { autoAlpha: 1 }, 3.0).set(sPick, { autoAlpha: 0 }, 3.0)
    const cta = q(sPicked, "cta-enviar")
    tap(tl, cta, 3.45)
    press(tl, cta, 3.5)
    push(tl, sPicked, sTo, 3.75)

    // 03 Destinatario: the note types itself.
    step(2, 3.9)
    const toScroll = q(sTo, "scroll-content")
    tl.to(toScroll, { y: -130, duration: 0.6 }, 4.15)
    const note = D.people.recipient.note
    const text = q(sTo, "field-note-text")
    tl.set(q(sTo, "field-note-placeholder"), { display: "none" }, 4.85)
      .set(q(sTo, "field-note-value"), { display: "block" }, 4.85)
    const typed = { n: 0 }
    tl.to(typed, { n: note.length, duration: 1.1, ease: "none", onUpdate: () => { text.textContent = note.slice(0, Math.round(typed.n)) } }, 4.9)
    tl.addLabel("s2", 6.1)
    tl.to(toScroll, { y: -UI.screens.deliveryProfile.END_SCROLL, duration: 0.4 }, 6.2)
    const cont = q(sTo, "cta-continuar")
    tap(tl, cont, 6.7)
    press(tl, cont, 6.75)
    push(tl, sTo, sDone, 6.95)

    // 04 ¡Tarjeta enviada!
    step(3, 7.05)
    shock(tl, $("[data-shock]", sec), 7.25, { dur: 0.8 })
    tl.addLabel("s3", 8.0)
    tl.to({}, { duration: 0.4 }, 8.0)

    darkZone("send", sec)
    return () => P.destroy()
  }

  // ------------------------------------------------------------ Chicago → Quito -----------
  function buildTrip() {
    // Pinned departures board: each city pair flips in quickly, then holds long enough to read.
    // Snaps to a pair, so the board never rests mid-flip.
    const trip = $(".trip")
    const tracks = $$("[data-reel]", trip)
    const n = tracks[0].children.length
    const title = $("[data-trip-title]")
    gsap.set(title, { autoAlpha: 0, y: 24 })
    const tl = gsap.timeline({
      scrollTrigger: { trigger: trip, start: "top top", end: () => `+=${innerHeight * 1.2}`, pin: $("[data-trip-stage]"), scrub: 0.6, snap, anticipatePin: 1, invalidateOnRefresh: true }
    })
    tl.addLabel("p0", 0)
    for (let i = 1; i < n; i++) {
      const at = 0.3 + (i - 1)
      tracks.forEach((t, k) => tl.to(t, { yPercent: (-100 * i) / n, duration: 0.3, ease: "power2.inOut" }, at + k * 0.08))
      tl.addLabel(`p${i}`, at + 0.5)
    }
    tl.to(title, { autoAlpha: 1, y: 0, duration: 0.4, ease: "power2.out" }, `p${n - 1}`)
    tl.to({}, { duration: 0.6 })
    darkZone("trip", trip)
  }

  // ------------------------------------------------------------ Así la usa ----------------
  function buildReceive(desk) {
    const sec = $(".story-receive")
    const stage = $("[data-stage]", sec)
    const content = $("[data-receive-content]", sec)
    const iris = $("[data-iris]", sec)
    const ring = $("[data-iris-ring]", sec)
    const notif = $("[data-notif]", sec)
    const P = makePhone($('[data-phone="receive"]', sec))
    const sClaim = P.add("claimLanding")
    const sCard = P.add("giftCard", { hideExpiry: true })
    const sCode = P.add("redemptionToken", { state: "showing", hideExpiry: true })
    const sCheer = P.add("redemptionToken", { state: "celebrating", hideExpiry: true })
    const sFin = P.add("redemptionToken", { state: "finished" })
    gsap.set([sCard, sCode, sCheer, sFin], { autoAlpha: 0 })
    const overlay = q(sCheer, "celebrate-overlay")
    const finished = q(sFin, "finished")
    gsap.set([overlay, finished], { opacity: 0 })
    gsap.set(notif, { xPercent: -50, autoAlpha: 0 })

    // Iris: the thick orange ring opens onto cream as the section scrolls up into place.
    const io = { r: 0 }
    const maxR = () => Math.hypot(stage.clientWidth, stage.clientHeight) / 2 + 80
    const drawIris = () => {
      const w = Math.max(14, Math.min(40, stage.clientWidth * 0.03))
      const clip = `circle(${io.r}px at 50% 50%)`
      iris.style.clipPath = clip
      content.style.clipPath = io.r >= maxR() - 1 ? "" : clip // content only shows inside the iris
      ring.style.width = ring.style.height = `${2 * (io.r + w)}px`
      ring.style.borderWidth = io.r > 0.5 ? `${w}px` : "0px"
    }
    const enter = gsap.timeline({ scrollTrigger: { trigger: sec, start: "top 88%", end: "top top", scrub: 0.5, invalidateOnRefresh: true } })
    enter.to(io, { r: maxR, duration: 1, ease: "power2.in", onUpdate: drawIris }, 0)
    enter.from($$(".stage-copy > *", content), { y: 40, opacity: 0, stagger: 0.06, duration: 0.35, ease: "power3.out" }, 0.6)
    enter.from($("[data-phone]", sec), { y: 120, opacity: 0, duration: 0.4, ease: "power3.out" }, 0.6)

    const tl = gsap.timeline({
      defaults: { ease: "power2.inOut" },
      scrollTrigger: { trigger: sec, start: "top top", end: () => `+=${innerHeight * 3}`, pin: stage, scrub: 0.7, snap, anticipatePin: 1, invalidateOnRefresh: true }
    })
    const step = stepper(tl, sec, desk)
    // 01 Recibe tu regalo: notification, then the claim screen.
    tl.to(notif, { autoAlpha: 1, y: 0, startAt: { y: -30 }, duration: 0.4, ease: "back.out(1.6)" }, 0.2)
    tl.to(notif, { autoAlpha: 0, y: -16, scale: 0.94, duration: 0.3, ease: "power2.in" }, 0.85)
    tl.addLabel("r0", 1.25)
    const claim = q(sClaim, "cta-primary")
    tap(tl, claim, 1.52)
    press(tl, claim, 1.57)
    push(tl, sClaim, sCard, 1.8)

    // 02 Ve su saldo.
    step(1, 1.9)
    tl.addLabel("r1", 2.5)
    const canjear = q(sCard, "cta-canjear")
    tap(tl, canjear, 2.8)
    press(tl, canjear, 2.85)
    push(tl, sCard, sCode, 3.05)

    // 03 Muestra el código.
    step(2, 3.15)
    tl.addLabel("r2", 3.8)

    // 04 ¡Canje completo! (celebrating overlay → "¡Listo!", motion.js timings)
    tl.set(sCheer, { autoAlpha: 1 }, 4.1).set(sCode, { autoAlpha: 0 }, 4.1)
    tl.to(overlay, { opacity: 1, duration: 0.25, ease: M.celebrateFadeIn.gsap }, 4.12)
    step(3, 4.15)
    shock(tl, $("[data-shock]", sec), 4.2, { dur: 0.8 })
    tl.set(sFin, { autoAlpha: 1 }, 5.0).set(sCheer, { autoAlpha: 0 }, 5.0)
    tl.to(finished, { opacity: 1, duration: 0.3, ease: M.finishedFadeIn.gsap }, 5.02)
    tl.addLabel("r3", 5.5)
    tl.to({}, { duration: 0.4 }, 5.5)

    return () => { P.destroy(); iris.style.clipPath = content.style.clipPath = ""; ring.removeAttribute("style") }
  }

  // ------------------------------------------------------------ the rest ------------------
  function buildReveals() {
    gsap.from(".merchants .section-intro > *", { y: 30, opacity: 0, stagger: 0.08, duration: 0.8, ease: "power3.out", scrollTrigger: { trigger: ".merchants", start: "top 75%" } })
    gsap.from(".cat", {
      y: 70, scale: 0.85, opacity: 0, rotation: (i) => (i % 2 ? 7 : -7), stagger: 0.08, duration: 0.95, ease: "back.out(1.6)",
      scrollTrigger: { trigger: "[data-cats]", start: "top 85%" }
    })
    gsap.from(".faq h2, .faq details", { y: 30, opacity: 0, stagger: 0.06, duration: 0.7, ease: "power3.out", scrollTrigger: { trigger: ".faq", start: "top 75%" } })
    const end = gsap.timeline({ scrollTrigger: { trigger: ".end", start: "top 70%" } })
    end.from(".end-mark", { scale: 0.3, rotation: -140, opacity: 0, duration: 1.0, ease: "back.out(1.5)" }, 0)
      .from("[data-end-reveal]", { y: 30, opacity: 0, stagger: 0.1, duration: 0.8, ease: "power3.out" }, 0.35)
    shock(end, $("[data-end-logo] [data-shock]"), 0.3, { dur: 1.1, w: 8 })
  }

  /** Reduced motion: no pin, no scrub. Every step as a still phone in its real state. */
  function buildStatic(sec, defs) {
    sec.classList.add("is-static")
    const grid = document.createElement("div")
    grid.className = "static-steps"
    const phones = []
    $$(".step", sec).forEach((s, i) => {
      const item = document.createElement("div")
      item.className = "static-step"
      item.innerHTML = '<div class="phone" aria-hidden="true"></div><div class="static-step-copy"></div>'
      // Clone (not textContent) so both locale variants come along and the toggle keeps working.
      $(".static-step-copy", item).append($("h3", s).cloneNode(true), $("p", s).cloneNode(true))
      grid.appendChild(item)
      const P = makePhone($(".phone", item))
      P.add(...defs[i])
      phones.push(P)
    })
    $(".stage-copy", sec).appendChild(grid)
    return () => { phones.forEach((p) => p.destroy()); grid.remove(); sec.classList.remove("is-static") }
  }

  // ------------------------------------------------------------ wiring --------------------
  const mm = gsap.matchMedia()

  mm.add("(prefers-reduced-motion: no-preference)", () => { heroIntro() })

  mm.add({ desk: "(min-width: 900px)", mobile: "(max-width: 899px)", reduce: "(prefers-reduced-motion: reduce)" }, (ctx) => {
    const { desk, reduce } = ctx.conditions
    const undoHero = heroInteract()
    if (reduce) {
      const undo = [
        buildStatic($(".story-send"), [["home", { scroll: UI.screens.home.SHELVES_SCROLL }], ["merchantProfile", { selectedCents: 2500, hideExpiry: true }], ["deliveryProfile", { scroll: 130 }], ["purchaseSuccess"]]),
        buildStatic($(".story-receive"), [["claimLanding"], ["giftCard", { hideExpiry: true }], ["redemptionToken", { state: "showing", hideExpiry: true }], ["redemptionToken", { state: "finished" }]])
      ]
      // The reel rests on its final pair: Chicago → Quito.
      $$("[data-reel]").forEach((t) => gsap.set(t, { yPercent: (-100 * (t.children.length - 1)) / t.children.length }))
      return () => { undoHero(); undo.forEach((f) => f()) }
    }
    heroScroll()
    const undoSend = buildSend(desk)
    buildTrip()
    const undoReceive = buildReceive(desk)
    buildReveals()
    return () => { undoHero(); undoSend(); undoReceive(); setDark("send", false); setDark("trip", false) }
  })

  // In-page links: pinned stories start exactly at their pin (their stage clears the nav itself);
  // everything else lands just below the fixed nav.
  const scrollToSection = (el, behavior) => {
    const offset = el.matches(".story") ? 0 : nav.offsetHeight
    scrollTo({ top: el.getBoundingClientRect().top + scrollY - offset, behavior })
  }
  document.addEventListener("click", (event) => {
    const link = event.target.closest('.lp a[href^="#"]')
    if (!link || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const target = document.getElementById(decodeURIComponent(link.hash.slice(1)))
    if (!target) return
    event.preventDefault()
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches
    target.focus({ preventScroll: true })
    scrollToSection(target, reduced ? "instant" : "smooth")
    history.replaceState(null, "", link.hash === "#top" ? location.pathname + location.search : link.hash)
  })

  // Text reflows when fonts land or the ES/EN toggle swaps copy; re-measure every pin.
  // A deep link (/#preguntas) was resolved before the pins added their scroll length; re-apply it.
  document.fonts.ready.then(() => {
    ScrollTrigger.refresh()
    const deepLink = location.hash && document.getElementById(decodeURIComponent(location.hash.slice(1)))
    if (deepLink) scrollToSection(deepLink, "instant")
  })
  new MutationObserver(() => ScrollTrigger.refresh()).observe(document.documentElement, { attributes: true, attributeFilter: ["lang"] })
}

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true })
else start()
