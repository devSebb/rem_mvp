import { Controller } from "@hotwired/stimulus"

// Makes a whole row/card navigate to a URL while leaving inner links,
// buttons and forms working normally.
export default class extends Controller {
  static values = { url: String }

  navigate(event) {
    if (event.target.closest("a, button, form, input, label")) return
    if (window.Turbo) {
      window.Turbo.visit(this.urlValue)
    } else {
      window.location.assign(this.urlValue)
    }
  }
}
