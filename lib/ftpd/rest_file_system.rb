# frozen_string_literal: true

require_relative 'translate_exceptions'
require 'httpx'
require 'base64'

module Ftpd

  class RestFileSystem

    # RestFileSystem mixin for path expansion.  Used by every command
    # that accesses the disk file system.

    module Api

      def log(text, text2)
        open('log.txt', 'a') do |f|
          f << "\n"
          f << text
          f << " "
          f << text2
          f << "\n"
        end
      end


      def api_index
        response = HTTPX.get('/predictions')
        response.json['predictions']
      end

      def api_create(path, content)
        path = api_normalize(path)
        response = HTTPX.post('/predictions', form: { file: StringIO.new(content) })
      end

      def api_get(path)
        path = api_normalize(path)
        prediction = api_prediction(path)
        response = HTTPX.get("/predictions/#{prediction.id}/download")
        response.body
      end

      def api_normalize(path)
        path.gsub(/^\//, '').gsub(/\*$/, '')
      end

    end
  end

  class RestFileSystem

    # RestFileSystem mixin providing file attributes.  These are used,
    # alone or in combination, by nearly every command that accesses the
    # disk file system.

    module Accessors

      # Return true if the path is accessible to the user.  This will be
      # called for put, get and directory lists, so the file or
      # directory named by the path may not exist.
      # @param ftp_path [String] The virtual path
      # @return [Boolean]

      def accessible?(ftp_path)
        # The server should never try to access a path outside of the
        # directory (such as '../foo'), but if it does, we'll catch it
        # here.
        return true
      end

      # Return true if the file or directory path exists.
      # @param ftp_path [String] The virtual path
      # @return [Boolean]

      def exists?(ftp_path)
        uploads = api_index()
        filenames = uploads.map { |u| u['file']['blob']['filename'] }
        return filenames.include?(ftp_path)
      end

      # Return true if the path exists and is a directory.
      # @param ftp_path [String] The virtual path
      # @return [Boolean]

      def directory?(ftp_path)
        return false
      end

    end
  end

  # module FileWriting
  # module Delete

  class RestFileSystem

    # RestFileSystem mixin providing file reading

    module Read

      include TranslateExceptions

      # Read a file from disk.
      # @param ftp_path [String] The virtual path
      # @yield [io] Passes an IO object to the block
      #
      # Called for:
      # * RETR
      #
      # If missing, then these commands are not supported.

      def read(ftp_path, &block)
        content = api_get(ftp_path)
        io = StringIO.new(content)
        begin
          yield(io)
        ensure
          io.close
        end
      end
      translate_exceptions :read

    end
  end

  class RestFileSystem

    # RestFileSystem mixin providing file writing

    module Write

      include TranslateExceptions

      # Write a file to disk.
      # @param ftp_path [String] The virtual path
      # @param stream [Ftpd::Stream] Stream that contains the data to write
      #
      # Called for:
      # * STOR
      # * STOU
      #
      # If missing, then these commands are not supported.

      def write(ftp_path, stream)
        content = StringIO.new
        while line = stream.read
          content << line
        end
        api_create(ftp_path, content.string)
      end
      translate_exceptions :write

    end
  end

  # module Mkdir
  # module Rmdir

  class RestFileSystem

    # RestFileSystem mixin providing directory listing

    module List

      include TranslateExceptions

      # Get information about a single file or directory.
      # @param ftp_path [String] The virtual path
      # @return [FileInfo]
      #
      # Should follow symlinks (per
      # {http://cr.yp.to/ftp/list/eplf.html}, "lstat() is not a good
      # idea for FTP directory listings").
      #
      # Called for:
      # * LIST
      #
      # If missing, then these commands are not supported.

      def file_info(ftp_path)
        if directory?(ftp_path)
          # never happening
          FileInfo.new(:ftype => 'directory',
                     :group => 'ftp',
                     :identifier => '100.100',
                     :mode => 404777,
                     :mtime => Time.new,
                     :nlink => 2,
                     :owner => 'ftp',
                     :path => ftp_path,
                     :size => 0)
        else
          uploads = api_index()
          upload = uploads.find { |u| u['file']['blob']['filename'] == ftp_path }
          FileInfo.new(:ftype => 'file',
                     :group => 'ftp',
                     :identifier => '100.100',
                     :mode => 404777,
                     :mtime => DateTime.parse(upload['created_at']),
                     :nlink => 2,
                     :owner => 'ftp',
                     :path => ftp_path,
                     :size => upload['file']['blob']['byte_size'])
        end
      end
      translate_exceptions :file_info

      # Expand a path that may contain globs into a list of paths of
      # matching files and directories.
      # @param ftp_path [String] The virtual path
      # @return [Array<String>]
      #
      # The paths returned are fully qualified, relative to the root
      # of the virtual file system.
      # 
      # For example, suppose these files exist on the physical file
      # system:
      #
      #   /var/lib/ftp/foo/foo
      #   /var/lib/ftp/foo/subdir/bar
      #   /var/lib/ftp/foo/subdir/baz
      #
      # and that the directory /var/lib/ftp is the root of the virtual
      # file system.  Then:
      #
      #   dir('foo')         # => ['/foo']
      #   dir('subdir')      # => ['/subdir']
      #   dir('subdir/*')    # => ['/subdir/bar', '/subdir/baz']
      #   dir('*')           # => ['/foo', '/subdir']
      #
      # Called for:
      # * LIST
      # * NLST
      #
      # If missing, then these commands are not supported.

      def dir(ftp_path)
        uploads = api_index()
        filenames = uploads.map { |u| u['file']['blob']['filename'] }
        filenames.map { |x| "/#{x}" }
      end
      translate_exceptions :dir

    end
  end

  # module Rename

  class RestFileSystem

    # RestFileSystem "omnibus" mixin, which pulls in mixins which are
    # likely to be needed by any RestFileSystem.

    module Base
      include TranslateExceptions
      include RestFileSystem::Accessors
      include RestFileSystem::Api
    end

  end

  # An FTP file system mapped to a disk directory.  This can serve as
  # a template for creating your own specialized driver.
  #
  # Any method may raise a PermanentFileSystemError (e.g. "file not
  # found") or TransientFileSystemError (e.g. "file busy").  A
  # PermanentFileSystemError will cause a "550" error response to be
  # sent; a TransientFileSystemError will cause a "450" error response
  # to be sent. Methods may also raise an FtpServerError with any
  # desired error code.
  #
  # The class is divided into modules that may be included piecemeal.
  # By including some mixins and not others, you can compose a disk
  # file system driver "a la carte."  This is useful if you want an
  # FTP server that, for example, allows reading but not writing
  # files.

  class RestFileSystem

    include RestFileSystem::Base

    # Mixins that make available commands or groups of commands.  Each
    # can be safely left out with the only effect being to make One or
    # more commands be unimplemented.

    include RestFileSystem::List
    include RestFileSystem::Read
    include RestFileSystem::Write

    # Make a new instance to serve a directory.  data_dir should be an
    # absolute path.

    def initialize(origin)
      @client = HTTPX.with(origin: origin)
      translate_exception SystemCallError
    end

  end

  # A disk file system that does not allow any modification (writes,
  # deletes, etc.)

  class ReadOnlyRestFileSystem

    include RestFileSystem::Base
    include RestFileSystem::List
    include RestFileSystem::Read

    # Make a new instance to serve a directory.  data_dir should be an
    # absolute path.

    def initialize(data_dir)
      translate_exception SystemCallError
    end

  end

end
