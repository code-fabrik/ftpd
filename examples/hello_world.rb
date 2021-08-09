#!/usr/bin/env ruby

unless $:.include?(File.dirname(__FILE__) + '/../lib')
  $:.unshift(File.dirname(__FILE__) + '/../lib')
end

require 'ftpd'
require 'tmpdir'

class Driver
  def initialize(token, repo)
    @token = token
    @repo = repo
  end

  def authenticate(user, password)
    true
  end

  def file_system(user)
    Ftpd::GithubFileSystem.new(@token, @repo)
  end

end

# Get a token from https://github.com/settings/tokens
driver = Driver.new('my_access_token', 'lukasskywalker/test')
server = Ftpd::FtpServer.new(driver)
server.port = ENV['PORT']
server.start
puts "Server listening on port #{server.bound_port}"
gets
