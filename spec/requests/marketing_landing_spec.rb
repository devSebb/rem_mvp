require "rails_helper"

RSpec.describe "Public marketing landing", type: :request do
  def page
    Nokogiri::HTML(response.body)
  end

  it "offers both released apps, native FAQs, and no consumer web signup" do
    get root_path

    expect(response).to have_http_status(:ok)
    expect(page.css("h1").size).to eq(1)
    expect(page.css("#preguntas details").size).to eq(6)
    # Store badges in the hero and again in the closing download card.
    expect(page.css('.landing-store-badge[href="https://apps.apple.com/us/app/papayal/id6759072681"]').size).to eq(2)
    google = page.at_css(".landing-store-badge-google")
    expect(google["href"]).to eq("https://play.google.com/store/apps/details?id=com.papayal.app&hl=es")
    expect(google["data-locale-href-en"]).to end_with("&hl=en")
    expect(page.css('a[href="/users/sign_up"]')).to be_empty
    expect(page.css("[data-landing] [data-reveal]")).to be_empty
  end

  it "loads the scroll story only on the landing, with its own header" do
    get root_path

    expect(page.css("[data-landing]").size).to eq(1)
    expect(page.css('script[src*="landing"]').size).to eq(1)
    expect(page.css('link[rel="stylesheet"][href*="landing"]').size).to eq(1)
    expect(page.at_css('meta[name="turbo-visit-control"]')["content"]).to eq("reload")
    nav_targets = page.css("header[data-nav] a[href^='#']").map { |link| link["href"].delete_prefix("#") }
    expect(nav_targets).to include("como-funciona", "comercios", "preguntas", "descargar")
    nav_targets.each { |anchor| expect(page.at_css("##{anchor}")).to be_present }
  end

  it "previews active merchants with redemption restrictions without opening web checkout" do
    create(:merchant, store_name: "Active Partner", partner_redemption: true)
    create(:merchant, store_name: "Second Partner", partner_redemption: true)
    create(:merchant, store_name: "Private Suspended", status: :suspended)

    get root_path

    section = page.at_css("#comercios")
    preview = section.at_css("[data-merchant-preview]")
    expect(preview.text).to include("Active Partner", "Second Partner")
    expect(section.text).not_to include("Private Suspended", "merchant@example.com", "US12345")
    expect(section.css(".marquee a")).to be_empty
    # A shared restriction is stated once, not per logo.
    notes = section.css(".landing-merchant-note").map(&:text)
    expect(notes).to eq(["Para canjear esta tarjeta, paga en Medicity o Farmacias Económicas."])
  end

  it "shows merchant logos with their name as alt text" do
    merchant = create(:merchant, store_name: "Logo Store")
    merchant.logo.attach(io: StringIO.new("fake"), filename: "logo.png", content_type: "image/png")

    get root_path

    logo = page.at_css("[data-merchant-preview] .logo-tile img")
    expect(logo["alt"]).to eq("Logo Store")
    # Unanalyzed blobs fall back to a 2:1 logo when sizing by area.
    expect(logo["style"]).to eq("height: 58.0%")
  end

  it "loops a hidden duplicate so screen readers hear each merchant once" do
    create_list(:merchant, 3)
    get root_path

    readable = page.css("[data-merchant-preview] > li:not([aria-hidden])")
    expect(readable.size).to eq(3)
    expect(page.css('.marquee-list[aria-hidden="true"]').size).to eq(1)
  end

  it "shows an honest empty catalog message" do
    get root_path
    expect(page.at_css(".landing-merchant-empty").text).to include("Consulta los comercios disponibles en la app.")
    expect(page.css("[data-merchant-preview]")).to be_empty
  end

  it "omits an unavailable store rather than linking to a placeholder" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("PAPAYAL_IOS_STORE_URL", anything).and_return("")

    get root_path

    expect(page.css('a[href*="apps.apple.com"]')).to be_empty
    expect(page.css(".landing-store-badge-google").size).to eq(2)
  end
end
