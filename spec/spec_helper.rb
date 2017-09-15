require 'simplecov'

SimpleCov.start do
  add_filter do |src|
    !(src.filename =~ /lib/)
  end
end

require 'pry'
require 'errands'

RSpec.configure do |config|
  config.order = "random"
  config.filter_run focus: true
  config.run_all_when_everything_filtered = true
end
