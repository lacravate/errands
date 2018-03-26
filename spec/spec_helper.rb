require 'simplecov'

SimpleCov.start do
  add_filter do |src|
    !(src.filename =~ /lib\/errands/)
  end

  add_filter do |src|
    src.filename.include? '/test_helpers/'
  end

  add_filter do |src|
    src.filename.include? 'alternate_private_access'
  end
end

require 'pry'
require 'errands'
require 'errands/test_helpers/wrapper'

RSpec.configure do |config|
  config.order = "random"
  config.filter_run focus: true
  config.run_all_when_everything_filtered = true
end
