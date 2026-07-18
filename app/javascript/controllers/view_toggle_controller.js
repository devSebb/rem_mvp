import { Controller } from "@hotwired/stimulus"

// Toggles between list and grid renderings of the same collection,
// remembering the admin's choice per page in localStorage.
export default class extends Controller {
  static targets = ["list", "grid", "listButton", "gridButton"]
  static values = { storageKey: { type: String, default: "admin_view_mode" } }

  connect() {
    this.apply(this.storedMode())
  }

  showList() {
    this.apply("list")
  }

  showGrid() {
    this.apply("grid")
  }

  apply(mode) {
    const isGrid = mode === "grid"
    if (this.hasListTarget) this.listTarget.classList.toggle("hidden", isGrid)
    if (this.hasGridTarget) this.gridTarget.classList.toggle("hidden", !isGrid)
    this.setActive(this.listButtonTarget, !isGrid)
    this.setActive(this.gridButtonTarget, isGrid)

    try {
      localStorage.setItem(this.storageKeyValue, mode)
    } catch (_e) {
      // Private browsing / storage disabled: toggle still works, just not remembered.
    }
  }

  storedMode() {
    try {
      return localStorage.getItem(this.storageKeyValue) === "grid" ? "grid" : "list"
    } catch (_e) {
      return "list"
    }
  }

  setActive(button, active) {
    button.classList.toggle("bg-[#0D2F32]", active)
    button.classList.toggle("text-white", active)
    button.classList.toggle("bg-white", !active)
    button.classList.toggle("text-[#2C3A43]", !active)
  }
}
