$:.unshift File.join(File.dirname(__FILE__), 'lib')

require 'errands/version'

Gem::Specification.new do |s|
  s.name          = "errands"
  s.version       = Errands::VERSION
  s.authors       = ["lacravate"]
  s.email         = ["lacravate@lacravate.fr"]
  s.homepage      = "https://github.com/lacravate/errands"
  s.summary       = "Turn a model into a threaded service"
  s.description   = "A code frame to have an orderly use of thread and separate runtime and actual job of a Ruby class"

  s.files         = `git ls-files app lib`.split("\n")
  s.platform      = Gem::Platform::RUBY
  s.require_paths = ['lib']

  s.add_development_dependency "rspec", "~> 3.5"
  s.add_development_dependency "pry", "~> 0.10.4"
  s.add_development_dependency "simplecov", "~> 0.15"
end
