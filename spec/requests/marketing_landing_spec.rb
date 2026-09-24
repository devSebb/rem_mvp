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
    expect(page.css('.landing-store-badge[href="https://apps.apple.com/us/app/papayal/id6759072681"]').size).to eq(1)
    google = page.at_css(".landing-store-badge-google")
    expect(google["href"]).to eq("https://play.google.com/store/apps/details?id=com.papayal.app&hl=es")
    expect(google["data-locale-href-en"]).to end_with("&hl=en")
    expect(page.css('a[href="/users/sign_up"]')).to be_empty
    expect(page.css(".landing-page [data-reveal]")).to be_empty
  end

  it "previews active merchants with redemption restrictions without opening web checkout" do
    create(:merchant, store_name: "Active Partner", partner_redemption: true)
    create(:merchant, store_name: "Second Partner", partner_redemption: true)
    create(:merchant, store_name: "Private Suspended", status: :suspended)

    get root_path

    section = page.at_css("#mercado")
    preview = section.at_css("[data-merchant-preview]")
    expect(preview.text).to include("Active Partner", "Second Partner")
    expect(section.text).not_to include("Private Suspended", "merchant@example.com", "US12345")
    expect(section.css(".landing-marquee a")).to be_empty
    # A shared restriction is stated once, not per logo.
    notes = section.css(".landing-merchant-note").map(&:text)
    expect(notes).to eq(["Para canjear esta tarjeta, paga en Medicity o Farmacias Económicas."])
  end

  it "shows merchant logos with their name as alt text" do
    merchant = create(:merchant, store_name: "Logo Store")
    merchant.logo.attach(io: StringIO.new("fake"), filename: "logo.png", content_type: "image/png")

    get root_path

    expect(page.at_css("[data-merchant-preview] img.landing-marquee-logo")["alt"]).to eq("Logo Store")
  end

  it "loops a hidden duplicate so screen readers hear each merchant once" do
    create_list(:merchant, 3)
    get root_path

    readable = page.css("[data-merchant-preview] > li:not([aria-hidden])")
    expect(readable.size).to eq(3)
    expect(page.css('.landing-marquee-list[aria-hidden="true"]').size).to eq(1)
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
    expect(page.css(".landing-store-badge-google").size).to eq(1)
    expect(page.css(".landing-availability")).to be_empty
  end
end
