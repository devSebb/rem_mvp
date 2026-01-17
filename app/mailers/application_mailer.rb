class ApplicationMailer < ActionMailer::Base
  default from: ENV['DEFAULT_FROM_EMAIL'] || 'papayalapp@gmail.com'
  layout "mailer"
end
