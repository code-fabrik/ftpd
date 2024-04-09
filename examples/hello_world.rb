#!/usr/bin/env ruby

unless $:.include?(File.dirname(__FILE__) + '/../lib')
  $:.unshift(File.dirname(__FILE__) + '/../lib')
end

require 'ftpd'
require 'tmpdir'

class Driver
  def initialize(origin)
    @origin = origin
  end

  def authenticate(user, password)
    true
  end

  def file_system(user)
    Ftpd::RestFileSystem.new(@origin)
  end

end

driver = Driver.new('http://localhost:3000')
server = Ftpd::FtpServer.new(driver)
server.port = ENV['PORT']
server.start
puts "Server listening on port #{server.bound_port}"
gets
