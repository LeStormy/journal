Rails.application.routes.draw do
  post '/telegram_webhook', to: 'telegram_bot#webhook'
end
