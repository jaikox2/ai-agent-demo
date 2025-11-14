Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  scope "/:account_id", constraints: { account_id: /[A-Za-z0-9_-]+/ } do
    get "main" => "main#index"
    resources :products, only: %i[index create update destroy], param: :id, constraints: { id: /[0-9a-fA-F-]{36}/ }
  end
end
