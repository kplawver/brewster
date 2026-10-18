require "bundler/setup"
ENV["BREWSTER_LOG"] = "off" # unit specs aren't the logger's audience
require "brewster"
require "json"
require "tmpdir"
require "stringio"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.disable_monkey_patching!
  config.order = :random
end