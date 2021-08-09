# frozen_string_literal: true

require_relative 'translate_exceptions'
require 'octokit'
require 'base64'

module Ftpd

  class GithubFileSystem

    # GithubFileSystem mixin for path expansion.  Used by every command
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

      def api_create(path, content)
        path = api_normalize(path)
        @client.create_contents(@repo, path, 'Create', content)
      end

      def api_update(path, content)
        path = api_normalize(path)
        sha = api_sha(path)
        @client.update_contents(@repo, path, 'Update', sha, content)
      end

      def api_delete(path)
        path = api_normalize(path)
        sha = api_sha(path)
        @client.delete_contents(@repo, path, 'Delete', sha)
      end

      def api_sha(path)
        path = api_normalize(path)
        dirname = Pathname.new(path).dirname.to_s
        parent = @client.contents(@repo, path: dirname)
        folder = parent.find { |f| f.path == path }
        folder.sha
      end

      def api_get(path)
        path = api_normalize(path)
        content = @client.contents(@repo, path: path).content
        decoded = Base64.decode64(content)
      end

      def api_info(path)
        path = api_normalize(path)
        @client.contents(@repo, path: path)
      end

      def api_normalize(path)
        path.gsub(/^\//, '').gsub(/\*$/, '')
      end

    end
  end

  class GithubFileSystem

    # GithubFileSystem mixin providing file attributes.  These are used,
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
        begin
          api_info(ftp_path)
          return true
        rescue Octokit::NotFound
          return false
        end
      end

      # Return true if the path exists and is a directory.
      # @param ftp_path [String] The virtual path
      # @return [Boolean]

      def directory?(ftp_path)
        info = api_info(ftp_path)
        return info.class.name == 'Array'
      end

    end
  end

  class GithubFileSystem

    # GithubFileSystem mixin providing file deletion

    module Delete

      include TranslateExceptions

      # Remove a file.
      # @param ftp_path [String] The virtual path
      #
      # Called for:
      # * DELE
      #
      # If missing, then these commands are not supported.

      def delete(ftp_path)
        api_delete(ftp_path)
      end
      translate_exceptions :delete

    end
  end

  class GithubFileSystem

    # GithubFileSystem mixin providing file reading

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

  class GithubFileSystem

    # GithubFileSystem mixin providing file writing

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
        if exists?(ftp_path)
          api_update(ftp_path, content.string)
        else
          api_create(ftp_path, content.string)
        end
      end
      translate_exceptions :write

    end
  end

  class GithubFileSystem

    # GithubFileSystem mixing providing mkdir

    module Mkdir

      include TranslateExceptions

      # Create a directory.
      # @param ftp_path [String] The virtual path
      #
      # Called for:
      # * MKD
      #
      # If missing, then these commands are not supported.

      def mkdir(ftp_path)
        api_create(ftp_path + '/.gitkeep', '')
      end
      translate_exceptions :mkdir

    end

  end

  class GithubFileSystem

    # GithubFileSystem mixing providing mkdir

    module Rmdir

      include TranslateExceptions

      # Remove a directory.
      # @param ftp_path [String] The virtual path
      #
      # Called for:
      # * RMD
      #
      # If missing, then these commands are not supported.

      def rmdir(ftp_path)
        api_delete(ftp_path)
      end
      translate_exceptions :rmdir

    end

  end

  class GithubFileSystem

    # GithubFileSystem mixin providing directory listing

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
          ftype = 'directory'
          size = 0
        else
          info = api_info(ftp_path)
          ftype = 'file'
          size = info.size
        end
        FileInfo.new(:ftype => ftype,
                     :group => 'ftp',
                     :identifier => '100.100',
                     :mode => 404777,
                     :mtime => Time.new,
                     :nlink => 2,
                     :owner => 'ftp',
                     :path => ftp_path,
                     :size => size)
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
        info = api_info(ftp_path)
        info.map(&:path).map { |x| "/#{x}" }
      end
      translate_exceptions :dir

    end
  end

  class GithubFileSystem

    # GithubFileSystem mixin providing file/directory rename/move

    module Rename

      include TranslateExceptions

      # Rename or move a file or directory
      #
      # Called for:
      # * RNTO
      #
      # If missing, then these commands are not supported.

      def rename(from_ftp_path, to_ftp_path)
        content = api_get(from_ftp_path)
        api_create(to_ftp_path, content)
        api_delete(from_ftp_path)
      end
      translate_exceptions :rename

    end
  end

  class GithubFileSystem

    # GithubFileSystem "omnibus" mixin, which pulls in mixins which are
    # likely to be needed by any GithubFileSystem.

    module Base
      include TranslateExceptions
      include GithubFileSystem::Accessors
      include GithubFileSystem::Api
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

  class GithubFileSystem

    include GithubFileSystem::Base

    # Mixins that make available commands or groups of commands.  Each
    # can be safely left out with the only effect being to make One or
    # more commands be unimplemented.

    include GithubFileSystem::Delete
    include GithubFileSystem::List
    include GithubFileSystem::Mkdir
    include GithubFileSystem::Read
    include GithubFileSystem::Rename
    include GithubFileSystem::Rmdir
    include GithubFileSystem::Write

    # Make a new instance to serve a directory.  data_dir should be an
    # absolute path.

    def initialize(token, repo)
      @client = Octokit::Client.new(access_token: token)
      @repo = repo
      translate_exception SystemCallError
    end

  end

  # A disk file system that does not allow any modification (writes,
  # deletes, etc.)

  class ReadOnlyGithubFileSystem

    include GithubFileSystem::Base
    include GithubFileSystem::List
    include GithubFileSystem::Read

    # Make a new instance to serve a directory.  data_dir should be an
    # absolute path.

    def initialize(data_dir)
      translate_exception SystemCallError
    end

  end

end
