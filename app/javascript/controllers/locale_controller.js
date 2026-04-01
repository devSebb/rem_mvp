import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.defaultLocale = this.element.dataset.localeDefault || "es"
    this.applyLanguage(this.initialLanguage())
  }

  setLanguage(event) {
    event.preventDefault()

    const { language } = event.currentTarget.dataset
    if (!language) return

    this.applyLanguage(language)
    this.persistLanguage(language)
    this.syncUrl(language)
  }

  applyLanguage(locale) {
    const normalizedLocale = locale === "en" ? "en" : "es"

    document.documentElement.lang = normalizedLocale
    this.toggleContent(normalizedLocale)
    this.updateToggleState(normalizedLocale)
    this.updateDocumentTitle(normalizedLocale)
    this.translateAttributes(normalizedLocale)
  }

  initialLanguage() {
    const queryLanguage = this.readQueryLanguage()

    if (queryLanguage) {
      this.persistLanguage(queryLanguage)
      return queryLanguage
    }

    return this.readSavedLanguage()
  }

  readSavedLanguage() {
    try {
      return window.localStorage.getItem("papayal:locale") || this.defaultLocale
    } catch (_error) {
      return this.defaultLocale
    }
  }

  readQueryLanguage() {
    const params = new URLSearchParams(window.location.search)
    const language = params.get("lang")

    if (language === "en") return "en"
    if (language === "es") return "es"

    return null
  }

  persistLanguage(language) {
    try {
      window.localStorage.setItem("papayal:locale", language)
    } catch (_error) {
      return
    }
  }

  syncUrl(language) {
    const url = new URL(window.location.href)

    if (language === "en") {
      url.searchParams.set("lang", "en")
    } else {
      url.searchParams.delete("lang")
    }

    window.history.replaceState({}, "", `${url.pathname}${url.search}${url.hash}`)
  }

  toggleContent(locale) {
    document.querySelectorAll("[data-locale-content]").forEach((element) => {
      const isVisible = element.dataset.localeContent === locale
      element.classList.toggle("hidden", !isVisible)
      element.setAttribute("aria-hidden", String(!isVisible))
    })
  }

  updateToggleState(locale) {
    document.querySelectorAll("[data-language-toggle]").forEach((button) => {
      const isActive = button.dataset.language === locale
      button.classList.toggle("is-active", isActive)
      button.setAttribute("aria-pressed", String(isActive))
    })
  }

  updateDocumentTitle(locale) {
    const key = locale === "en" ? "titleEn" : "titleEs"
    const title = this.element.dataset[key]
    if (title) document.title = title
  }

  translateAttributes(locale) {
    document.querySelectorAll("[data-locale-attrs]").forEach((element) => {
      element.dataset.localeAttrs.split(",").map((value) => value.trim()).forEach((attribute) => {
        const datasetKey = this.datasetKeyFor(attribute, locale)
        const translatedValue = element.dataset[datasetKey]

        if (!translatedValue) return

        if (attribute === "title") {
          element.setAttribute("title", translatedValue)
        } else {
          element.setAttribute(attribute, translatedValue)
        }
      })
    })

    document.querySelectorAll("[data-locale-value-es][data-locale-value-en]").forEach((element) => {
      element.value = locale === "en" ? element.dataset.localeValueEn : element.dataset.localeValueEs
    })
  }

  datasetKeyFor(attribute, locale) {
    const normalizedAttribute = attribute
      .split("-")
      .map((segment) => segment.charAt(0).toUpperCase() + segment.slice(1))
      .join("")

    return `locale${normalizedAttribute}${locale.toUpperCase()}`
  }
}
