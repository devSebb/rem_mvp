require "rails_helper"

RSpec.describe "Public localization", type: :request do
  it "renders the bilingual landing page with the language toggle" do
    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-language=\"en\"")
    expect(response.body).to include("Prepaid digital gift cards for")
    expect(response.body).to include("Based in the United States")
  end

  it "renders bilingual terms and privacy pages" do
    get legal_terminos_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Terms of Service")
    expect(response.body).to include("Papayal LLC (Delaware, United States)")

    get legal_privacidad_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Privacy Policy")
    expect(response.body).to include("Process prepaid gift card purchases")
  end
end
