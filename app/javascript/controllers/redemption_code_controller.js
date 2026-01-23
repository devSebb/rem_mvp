import { Controller } from "@hotwired/stimulus"
import QRCode from "qrcode"
import JsBarcode from "jsbarcode"

// Handles rotating redemption token rendering (QR, barcode, human code)
export default class extends Controller {
  static targets = ["qr", "barcode", "code", "timer", "status"]
  static values = { url: String }

  connect() {
    this.fetchToken()
  }

  disconnect() {
    this.clearTimers()
  }

  fetchToken() {
    if (!this.hasUrlValue) return

    this.clearTimers()
    this.setStatus("Cargando código seguro…")
    this.isRefreshing = false

    fetch(this.urlValue, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken()
      }
    })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json()
      })
      .then((data) => {
        if (!data?.token || !data?.expires_at) throw new Error("Respuesta inválida")

        this.currentToken = data.token
        this.expiresAt = new Date(data.expires_at)
        this.renderAll()
      })
      .catch((error) => {
        console.error("Failed to fetch redemption token", error)
        this.setStatus("Sin conexión. Reintenta.")
        this.retryTimeout = setTimeout(() => this.fetchToken(), 5000)
      })
  }

  renderAll() {
    this.clearStatus()
    this.renderQr()
    this.renderBarcode()
    this.renderCode()
    this.startCountdown()
  }

  renderQr() {
    if (!this.hasQrTarget || !this.currentToken) return

    QRCode.toCanvas(this.qrTarget, this.currentToken, {
      width: 220,
      margin: 1,
      color: {
        dark: "#111827",
        light: "#ffffff"
      }
    })
  }

  renderBarcode() {
    if (!this.hasBarcodeTarget || !this.currentToken) return

    this.barcodeTarget.innerHTML = ""
    JsBarcode(this.barcodeTarget, this.currentToken, {
      format: "CODE128",
      displayValue: false,
      lineColor: "#111827",
      height: 60,
      margin: 0
    })
  }

  renderCode() {
    if (!this.hasCodeTarget || !this.currentToken) return

    const groups = this.currentToken.match(/.{1,4}/g) || [this.currentToken]
    this.codeTarget.textContent = groups.join(" ").trim()
  }

  startCountdown() {
    if (!this.hasTimerTarget || !this.expiresAt) return

    this.updateCountdown()
    this.countdownInterval = setInterval(() => this.updateCountdown(), 1000)
  }

  updateCountdown() {
    const remainingMs = this.expiresAt - new Date()
    const remainingSeconds = Math.max(Math.floor(remainingMs / 1000), 0)

    this.timerTarget.textContent = `${remainingSeconds}s`

    if (remainingSeconds <= 0) {
      if (this.isRefreshing) return
      this.isRefreshing = true
      this.fetchToken()
    }
  }

  setStatus(message) {
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = message
      this.statusTarget.classList.remove("hidden")
    }
  }

  clearStatus() {
    if (this.hasStatusTarget) {
      this.statusTarget.textContent = ""
      this.statusTarget.classList.add("hidden")
    }
  }

  clearTimers() {
    if (this.countdownInterval) {
      clearInterval(this.countdownInterval)
      this.countdownInterval = null
    }

    if (this.retryTimeout) {
      clearTimeout(this.retryTimeout)
      this.retryTimeout = null
    }
  }

  csrfToken() {
    const element = document.querySelector("meta[name='csrf-token']")
    return element ? element.getAttribute("content") : ""
  }
}








