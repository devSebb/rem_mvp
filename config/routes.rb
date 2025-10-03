Rails.application.routes.draw do
  root "home#index"

  devise_for :users

  resources :gift_cards, only: [:index, :show, :new] do
    collection do
      post :checkout
      get :success
      get :cancel
    end
  end

  namespace :webhooks do
    post :stripe, to: "stripe#receive"
    post :twilio_status, to: "twilio#status"
  end

  # Gift card redemption routes
  get '/redeem', to: 'redeems#show'
  post '/redeem/claim', to: 'redeems#claim'
  get '/redeem/success', to: 'redeems#success', as: :redeem_success

  namespace :merchant do
    root to: "dashboard#index"
    resources :redemptions, only: [:new, :create] do
      get :confirm, on: :collection
      post :redeem, on: :collection
      get :success, on: :collection
    end
    resources :settlements, only: [:index, :show]
    resource :profile, only: [:show, :update]
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
