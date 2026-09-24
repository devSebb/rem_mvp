import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "mobileMenu",
    "menuButton",
    "contactStatus",
    "contactError",
    "countup"
  ]

  connect() {
    this.setupRevealObserver()
    this.setupCountObserver()
    this.desktopQuery = window.matchMedia("(min-width: 1200px)")
    this.onViewportChange = () => this.closeMenu()
    this.desktopQuery.addEventListener("change", this.onViewportChange)
  }

  disconnect() {
    if (this.revealObserver) this.revealObserver.disconnect()
    if (this.countObserver) this.countObserver.disconnect()
    this.desktopQuery?.removeEventListener("change", this.onViewportChange)
  }

  toggleMenu() {
    if (!this.hasMobileMenuTarget || !this.hasMenuButtonTarget) return

    const isHidden = this.mobileMenuTarget.classList.contains("hidden")
    this.mobileMenuTarget.classList.toggle("hidden")
    this.menuButtonTarget.setAttribute("aria-expanded", String(isHidden))
  }

  closeMenu() {
    if (!this.hasMobileMenuTarget || !this.hasMenuButtonTarget) return

    this.mobileMenuTarget.classList.add("hidden")
    this.menuButtonTarget.setAttribute("aria-expanded", "false")
  }

  escapeMenu(event) {
    if (!this.hasMenuButtonTarget || this.menuButtonTarget.getAttribute("aria-expanded") !== "true") return

    event.preventDefault()
    this.closeMenu()
    this.menuButtonTarget.focus()
  }

  handleAnchorClick(event) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const url = new URL(event.currentTarget.href, window.location.href)
    this.closeMenu()
    if (url.origin !== window.location.origin || url.pathname !== window.location.pathname || !url.hash) return

    const target = document.getElementById(decodeURIComponent(url.hash.slice(1)))
    if (!target) return

    event.preventDefault()
    const headerHeight = document.querySelector(".marketing-nav-wrap")?.getBoundingClientRect().height || 80
    const top = target.getBoundingClientRect().top + window.scrollY - headerHeight - 16
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    // Transfer keyboard focus out of the now-closed menu without a second scroll.
    target.focus({ preventScroll: true })
    window.scrollTo({ top, behavior: reducedMotion ? "instant" : "smooth" })
    window.history.replaceState({}, "", `${window.location.pathname}${window.location.search}${url.hash}`)
  }

  handleContactSubmit(event) {
    event.preventDefault()

    const form = event.target
    const submitButton = form.querySelector('button[type="submit"]')
    const token = document.querySelector('meta[name="csrf-token"]')?.content

    const payload = {
      name: form.querySelector("#contact-name")?.value.trim() || "",
      email: form.querySelector("#contact-email")?.value.trim() || "",
      message: form.querySelector("#contact-message")?.value.trim() || ""
    }

    if (this.hasContactErrorTarget) this.contactErrorTarget.classList.add("hidden")
    if (submitButton) submitButton.disabled = true

    fetch("/contact", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": token || ""
      },
      body: JSON.stringify(payload)
    })
      .then((response) => {
        if (!response.ok) throw new Error("Request failed")
        if (this.hasContactStatusTarget) this.contactStatusTarget.classList.remove("hidden")
        form.reset()
      })
      .catch(() => {
        if (this.hasContactErrorTarget) this.contactErrorTarget.classList.remove("hidden")
      })
      .finally(() => {
        if (submitButton) submitButton.disabled = false
      })
  }

  setupRevealObserver() {
    const revealElements = document.querySelectorAll("[data-reveal]")
    if (revealElements.length === 0) return

    this.revealObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible")
            this.revealObserver.unobserve(entry.target)
          }
        })
      },
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
    )

    revealElements.forEach((element) => this.revealObserver.observe(element))
  }

  setupCountObserver() {
    if (!this.hasCountupTarget) return

    this.countObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting || entry.target.dataset.countAnimated === "true") return
          this.animateCount(entry.target)
          entry.target.dataset.countAnimated = "true"
          this.countObserver.unobserve(entry.target)
        })
      },
      { threshold: 0.5 }
    )

    this.countupTargets.forEach((element) => this.countObserver.observe(element))
  }

  animateCount(element) {
    const finalValue = Number(element.dataset.countTo || 0)
    const prefix = element.dataset.countPrefix || ""
    const suffix = element.dataset.countSuffix || (finalValue >= 1000 ? "+" : "")
    const duration = 1200
    const start = performance.now()
    const hasDecimal = finalValue % 1 !== 0

    const step = (now) => {
      const progress = Math.min((now - start) / duration, 1)
      const eased = 1 - Math.pow(1 - progress, 3)
      const current = finalValue * eased
      const formatted = hasDecimal ? current.toFixed(1) : Math.round(current).toLocaleString("en-US")
      element.textContent = `${prefix}${formatted}${suffix}`

      if (progress < 1) {
        requestAnimationFrame(step)
      }
    }

    requestAnimationFrame(step)
  }
}
