Rails.application.routes.draw do
  root "home#index"

  devise_for :users

  resources :gift_cards, only: [:index, :show, :new] do
    collection do
      post :checkout
      get :success
      get :cancel
    end
    
    resources :transfers, only: [:new, :create] do
      get :confirm, on: :collection
      post :process_transfer, on: :collection
    end
  end

  namespace :api do
    namespace :v1 do
      resources :gift_cards, only: [] do
        resource :redemption_token, only: :create, module: :gift_cards
      end

      post "gift_cards/validate", to: "gift_cards#validate"
      get  "gift_cards/:token",   to: "gift_cards#show"

      # Kept path for backwards compatibility; now backed by Transaction records.
      resources :redemptions, only: [:create, :show] do
        post :refund, on: :member
      end
    end
  end

  namespace :webhooks do
    post :stripe, to: "stripe#receive"
    post :twilio_status, to: "twilio#status"
  end

  # Gift card redemption routes (removed - using direct merchant redemption only)

  namespace :merchant do
    root to: "dashboard#index"
    resources :redemptions, only: [:new, :create] do
      get :confirm, on: :collection
      post :redeem, on: :collection
      get :success, on: :collection
    end
    resources :gift_cards, only: [:show] do
      post "transactions/:transaction_id/refund", to: "transactions#refund", as: :refund_transaction
    end
    resources :settlements, only: [:index, :show]
    resource :profile, only: [:show, :update]
  end

  namespace :admin do
    resources :gift_cards, only: [] do
      resources :refunds, only: [:new, :create], path: 'refund'
    end
  end

  # Mount Sidekiq web interface at /sidekiq (admin only)
  mount Sidekiq::Web => '/sidekiq', constraints: ->(request) { 
    request.env['warden'].user&.admin? 
  }

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
