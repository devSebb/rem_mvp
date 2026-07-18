import { Controller } from "@hotwired/stimulus"

// Copies a value to the clipboard and briefly confirms on the button.
export default class extends Controller {
  static targets = ["button"]
  static values = { text: String }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.textValue)
      this.flash("Copiado ✓")
    } catch (_e) {
      this.flash("No se pudo copiar")
    }
  }

  flash(message) {
    if (!this.hasButtonTarget) return
    const original = this.buttonTarget.textContent
    this.buttonTarget.textContent = message
    setTimeout(() => { this.buttonTarget.textContent = original }, 1500)
  }
}
