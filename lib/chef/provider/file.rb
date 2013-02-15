#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/config'
require 'chef/log'
require 'chef/resource/file'
require 'chef/provider'
require 'etc'
require 'fileutils'
require 'chef/scan_access_control'
require 'chef/mixin/checksum'
require 'chef/mixin/diffable_file_resource'

class Chef
  class Provider
    class File < Chef::Provider
      include Chef::Mixin::EnforceOwnershipAndPermissions
      include Chef::Mixin::Checksum
      include Chef::Mixin::DiffableFileResource

      attr_accessor :content_strategy

      def initialize(new_resource, run_context)
        @content_strategy ||= ContentFromResource.new(new_resource, run_context)
        super
      end

      def whyrun_supported?
        true
      end

      def load_current_resource
        # Let children resources override constructing the @current_resource
        @current_resource ||= Chef::Resource::File.new(@new_resource.name)
        @new_resource.path.gsub!(/\\/, "/") # for Windows
        @current_resource.path(@new_resource.path)
        load_resource_attributes_from_file(@current_resource)
        @current_resource
      end

      def define_resource_requirements
        # Make sure the parent directory exists, otherwise fail.  For why-run assume it would have been created.
        requirements.assert(:create, :create_if_missing, :touch) do |a|
          parent_directory = ::File.dirname(@new_resource.path)
          a.assertion { ::File.directory?(parent_directory) }
          a.failure_message(Chef::Exceptions::EnclosingDirectoryDoesNotExist, "Parent directory #{parent_directory} does not exist.")
          a.whyrun("Assuming directory #{parent_directory} would have been created")
        end

        # Make sure the file is deletable if it exists, otherwise fail.
        if ::File.exists?(@new_resource.path)
          requirements.assert(:delete) do |a|
            a.assertion { ::File.writable?(@new_resource.path) }
            a.failure_message(Chef::Exceptions::InsufficientPermissions,"File #{@new_resource.path} exists but is not writable so it cannot be deleted")
          end
        end
      end

      # if you are using a tempfile before creating, you must
      # override the default with the tempfile, since the
      # file at @new_resource.path will not be updated on converge
      def load_resource_attributes_from_file(resource)
        if resource.respond_to?(:checksum)
          if ::File.exists?(resource.path) && !::File.directory?(resource.path)
            if @action != :create_if_missing # XXX: don't we break current_resource semantics by skipping this?
              resource.checksum(checksum(resource.path))
            end
          end
        end

        if Chef::Platform.windows?
          # TODO: To work around CHEF-3554, add support for Windows
          # equivalent, or implicit resource reporting won't work for
          # Windows.
          return
        end

        acl_scanner = ScanAccessControl.new(@new_resource, resource)
        acl_scanner.set_all!
      end

      def do_acl_changes
        if access_controls.requires_changes?
          converge_by(access_controls.describe_changes) do
            access_controls.set_all
            # update the @new_resource to have the correct new values for reporting (@new_resource == actual "end state" here)
            load_resource_attributes_from_file(@new_resource)
          end
        end
      end

      # handles both cases of when the file exists and must be backed up, and when it does not and must be created
      def tempfile_to_destfile
        backup @new_resource.path if ::File.exists?(@new_resource.path)
        filename = @content_strategy.filename
        # touch only when creating a file that does not exist, in order to get default perms right based on umask
        FileUtils.touch(@new_resource.path) unless ::File.exists?(@new_resource.path)
        FileUtils.cp(filename, @new_resource.path)
        @content_strategy.cleanup
      end

      def do_update_file
        description = []
        description << "update content in file #{@new_resource.path} from #{short_cksum(@current_resource.checksum)} to #{short_cksum(@content_strategy.checksum)}"
        description << diff(@content_strategy.filename)
        converge_by(description) do
          tempfile_to_destfile
          Chef::Log.info("#{@new_resource} updated file #{@new_resource.path}")
        end
        # the cleanup in the converge_by will not be run in whyrun-mode
        @content_strategy.cleanup if whyrun_mode?
      end

      def do_create_file
        description = []
        description << "create new file #{@new_resource.path}"
        description << " with content checksum #{short_cksum(@content_strategy.checksum)}"
        description << diff(@content_strategy.filename)
        converge_by(description) do
          tempfile_to_destfile
          Chef::Log.info("#{@new_resource} created file #{@new_resource.path}")
        end
        # the cleanup in the converge_by will not be run in whyrun-mode
        @content_strategy.cleanup if whyrun_mode?
      end

      def action_create
        if @content_strategy.has_content?
          if !::File.exists?(@new_resource.path)
            do_create_file
          else
            if @content_strategy.contents_changed?(@current_resource)
              do_update_file
            end
          end
        end
        do_acl_changes
      end

      def action_create_if_missing
        if ::File.exists?(@new_resource.path)
          Chef::Log.debug("#{@new_resource} exists at #{@new_resource.path} taking no action.")
        else
          action_create
        end
      end

      def action_delete
        if ::File.exists?(@new_resource.path)
          converge_by("delete file #{@new_resource.path}") do
            backup unless ::File.symlink?(@new_resource.path)
            ::File.delete(@new_resource.path)
            Chef::Log.info("#{@new_resource} deleted file at #{@new_resource.path}")
          end
        end
      end

      def action_touch
        action_create
        converge_by("update utime on file #{@new_resource.path}") do
          time = Time.now
          ::File.utime(time, time, @new_resource.path)
          Chef::Log.info("#{@new_resource} updated atime and mtime to #{time}")
        end
      end

      def backup(file=nil)
        file ||= @new_resource.path
        if @new_resource.backup != false && @new_resource.backup > 0 && ::File.exist?(file)
          time = Time.now
          savetime = time.strftime("%Y%m%d%H%M%S")
          backup_filename = "#{@new_resource.path}.chef-#{savetime}"
          backup_filename = backup_filename.sub(/^([A-Za-z]:)/, "") #strip drive letter on Windows
          # if :file_backup_path is nil, we fallback to the old behavior of
          # keeping the backup in the same directory. We also need to to_s it
          # so we don't get a type error around implicit to_str conversions.
          prefix = Chef::Config[:file_backup_path].to_s
          backup_path = ::File.join(prefix, backup_filename)
          FileUtils.mkdir_p(::File.dirname(backup_path)) if Chef::Config[:file_backup_path]
          FileUtils.cp(file, backup_path, :preserve => true)
          Chef::Log.info("#{@new_resource} backed up to #{backup_path}")

          # Clean up after the number of backups
          slice_number = @new_resource.backup
          backup_files = Dir[::File.join(prefix, ".#{@new_resource.path}.chef-*")].sort { |a,b| b <=> a }
          if backup_files.length >= @new_resource.backup
            remainder = backup_files.slice(slice_number..-1)
            remainder.each do |backup_to_delete|
              FileUtils.rm(backup_to_delete)
              Chef::Log.info("#{@new_resource} removed backup at #{backup_to_delete}")
            end
          end
        end
      end

      # FIXME: keep this for mv strategy
#      def deploy_tempfile
#        Tempfile.open(::File.basename(@new_resource.name)) do |tempfile|
#          yield tempfile
#
#          temp_res = Chef::Resource::CookbookFile.new(@new_resource.name)
#          temp_res.path(tempfile.path)
#          ac = Chef::FileAccessControl.new(temp_res, @new_resource, self)
#          ac.set_all!
#          FileUtils.mv(tempfile.path, @new_resource.path)
#        end
#      end
#
      private

      def short_cksum(checksum)
        return "none" if checksum.nil?
        checksum.slice(0,6)
      end

      class BackupService
      end
    end
  end
end

class Chef
  class Provider
    class File
      class ContentStrategy
        attr_accessor :run_context

        def initialize(new_resource, run_context)
          @new_resource = new_resource
          @run_context = run_context
        end

        def has_content?
          # most providers will always have content
          true
        end

        def contents_changed?(current_resource)
          checksum != current_resource.checksum
        end

        def filename
          raise "class must implement tempfile!"
        end

        def checksum
          Chef::Digester.checksum_for_file(filename)
        end

        def cleanup
          raise "class must implement cleanup!"
        end
      end

      class ContentFromResource < ContentStrategy
        def has_content?
          @new_resource.content != nil
        end

        def filename
          @filename ||= begin
                          @tempfile = Tempfile.open(::File.basename(@new_resource.name))
                          @tempfile.write(@new_resource.content)
                          @tempfile.close
                          @tempfile.path
                        end
        end

        def cleanup
          @tempfile.unlink
        end
      end
    end
  end
end

