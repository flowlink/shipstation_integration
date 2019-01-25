source 'https://rubygems.org'

gem 'sinatra'
gem 'i18n'
gem 'activesupport'
gem 'unirest'
gem 'tilt', '~> 1.4.1'
gem 'tilt-jbuilder', require: 'sinatra/jbuilder'
gem 'endpoint_base', github: 'flowlink/endpoint_base'
gem 'foreman'
gem 'unicorn'
gem 'honeybadger'

# security updates suggested by GitHub
gem "rack", ">= 1.6.11"
gem "rack-protection", ">= 1.5.5"
# end security updates

group :development do
  gem 'pry'
  gem 'shotgun'
end

group :development, :test do
  gem 'pry-byebug'
end

group :test do
  gem 'rspec'
  gem 'rack-test'
  gem 'webmock'
  gem 'vcr'
end
