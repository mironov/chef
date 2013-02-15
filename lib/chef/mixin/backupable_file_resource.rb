#
# Author:: Lamont Granquist (<lamont@opscode.com>)
# Copyright:: Copyright (c) 2013 Opscode, Inc.
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

class Chef
  module Mixin
    module BackupableFileResource
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
    end
  end
end

