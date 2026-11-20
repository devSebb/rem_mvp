require "rails_helper"

RSpec.describe "Web registrations (pending-recipient claim block)", type: :request do
  let!(:pending_recipient) do
    create(:user, pending_recipient: true, email: "esperando@example.com", phone: "+593991110000")
  end

  it "keeps pending recipients pending so gift cards can't be claimed without OTP" do
    expect(pending_recipient).to be_pending

    post user_registration_path, params: {
      user: {
        email: "esperando@example.com",
        password: "Password!23",
        password_confirmation: "Password!23",
        first_name: "Atacante",
        last_name: "Anon"
      }
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("app Papayal")
    expect(pending_recipient.reload).to be_pending
    expect(pending_recipient.reload.first_name).not_to eq("Atacante")
  end

  it "blocks phone-matched claims the same way" do
    post user_registration_path, params: {
      user: {
        email: "otro-correo@example.com",
        password: "Password!23",
        password_confirmation: "Password!23",
        first_name: "Atacante",
        last_name: "Anon",
        phone: "+593991110000"
      }
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(pending_recipient.reload).to be_pending
  end

  it "leaves normal web signup untouched" do
    expect {
      post user_registration_path, params: {
        user: {
          email: "nueva@example.com",
          password: "Password!23",
          password_confirmation: "Password!23",
          first_name: "Nueva",
          last_name: "Usuaria",
          phone: "+593995556666"
        }
      }
    }.to change(User, :count).by(1)

    expect(User.find_by(email: "nueva@example.com")).to be_claimed
  end

  %w[admin merchant].each do |escalated_role|
    it "ignores a submitted role=#{escalated_role} and creates a plain user" do
      expect {
        post user_registration_path, params: {
          user: {
            email: "intruso-#{escalated_role}@example.com",
            password: "Password!23",
            password_confirmation: "Password!23",
            first_name: "Intruso",
            last_name: "Anon",
            phone: "+59399555#{escalated_role == 'admin' ? '1111' : '2222'}",
            role: escalated_role
          }
        }
      }.to change(User, :count).by(1)

      created = User.find_by(email: "intruso-#{escalated_role}@example.com")
      expect(created.role).to eq("user")
      expect(created).not_to be_admin
      expect(created).not_to be_merchant
    end
  end
end
