import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "mobileMenu",
    "menuButton",
    "newsletterStatus",
    "contactStatus",
    "heroParallaxItem",
    "countup"
  ]

  connect() {
    this.setupRevealObserver()
    this.setupCountObserver()
  }

  disconnect() {
    if (this.revealObserver) this.revealObserver.disconnect()
    if (this.countObserver) this.countObserver.disconnect()
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

  handleAnchorClick(event) {
    const href = event.currentTarget.getAttribute("href")
    if (!href || !href.includes("#")) return

    const [path, hash] = href.split("#")
    const currentPath = window.location.pathname
    const normalizedPath = path && path.length > 0 ? path : currentPath

    if (normalizedPath !== currentPath || !hash) return

    const target = document.getElementById(hash)
    if (!target) return

    event.preventDefault()
    const offset = 94
    const top = target.getBoundingClientRect().top + window.scrollY - offset
    window.scrollTo({ top, behavior: "smooth" })
  }

  handleNewsletterSubmit(event) {
    event.preventDefault()
    if (!this.hasNewsletterStatusTarget) return

    this.newsletterStatusTarget.classList.remove("hidden")
    event.target.reset()
  }

  handleContactSubmit(event) {
    event.preventDefault()
    if (!this.hasContactStatusTarget) return

    this.contactStatusTarget.classList.remove("hidden")
    event.target.reset()
  }

  handleHeroParallax(event) {
    if (!this.hasHeroParallaxItemTarget) return

    const card = event.currentTarget
    const rect = card.getBoundingClientRect()
    const x = (event.clientX - rect.left) / rect.width - 0.5
    const y = (event.clientY - rect.top) / rect.height - 0.5

    this.heroParallaxTargets.forEach((element) => {
      const speed = Number(element.dataset.speed || 6)
      const moveX = x * speed
      const moveY = y * speed
      element.style.transform = `translate3d(${moveX}px, ${moveY}px, 0)`
    })
  }

  resetHeroParallax() {
    this.heroParallaxTargets.forEach((element) => {
      element.style.transform = "translate3d(0, 0, 0)"
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
