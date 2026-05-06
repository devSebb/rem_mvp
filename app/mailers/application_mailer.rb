class ApplicationMailer < ActionMailer::Base
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'hola@papayal.app'
  layout "mailer"
end
