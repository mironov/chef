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

require 'chef/mixin/shell_out'

class Chef
  module Mixin
    module DiffableFileResource
      include Chef::Mixin::ShellOut

      def diff(file)
        diff_string = catch (:nodiff) do
          @new_resource.diff( _diff_file_against_current(file) )
        end
        @new_resource.diff || diff_string
      end

      private

      def _diff_file_against_current(path)
        suppress_resource_reporting = false

        throw :nodiff, "(diff output suppressed by config)" if Chef::Config[:diff_disabled]
        throw :nodiff, "(no temp file with new content, diff output suppressed)" unless ::File.exists?(path)  # should never happen?

        # solaris does not support diff -N, so create tempfile to diff against if we are creating a new file
        target_path = if ::File.exists?(@current_resource.path)
                        @current_resource.path
                      else
                        suppress_resource_reporting = true  # suppress big diffs going to resource reporting service
                        tempfile = Tempfile.new('chef-tempfile')
                        tempfile.path
                      end

        diff_filesize_threshold = Chef::Config[:diff_filesize_threshold]
        diff_output_threshold = Chef::Config[:diff_output_threshold]

        if ::File.size(target_path) > diff_filesize_threshold || ::File.size(path) > diff_filesize_threshold
          throw :nodiff, "(file sizes exceed #{diff_filesize_threshold} bytes, diff output suppressed)"
        end

        # MacOSX(BSD?) diff will *sometimes* happily spit out nasty binary diffs
        throw :nodiff, "(current file is binary, diff output suppressed)" if _is_binary?(target_path)
        throw :nodiff, "(new content is binary, diff output suppressed)" if _is_binary?(path)

        begin
          # -u: Unified diff format
          result = shell_out("diff -u #{target_path} #{path}" )
        rescue Exception => e
          # Should *not* receive this, but in some circumstances it seems that
          # an exception can be thrown even using shell_out instead of shell_out!
          throw :nodiff, "Could not determine diff. Error: #{e.message}"
        end

        # diff will set a non-zero return code even when there's
        # valid stdout results, if it encounters something unexpected
        # So as long as we have output, we'll show it.
        if not result.stdout.empty?
          if result.stdout.length > diff_output_threshold
            throw :nodiff, "(long diff of over #{diff_output_threshold} characters, diff output suppressed)"
          else
            val = result.stdout.split("\n")
            val.delete("\\ No newline at end of file")
            val = val.join("\\n")
            # XXX: we produce valid diff output to the terminal, but the diff in the resource (and
            #      sent to reporting) is suppressed
            throw :nodiff, val if suppress_resource_reporting
            # XXX: we return the diff here, everything else is an error of one form or another
            return val
          end
        elsif not result.stderr.empty?
          throw :nodiff, "Could not determine diff. Error: #{result.stderr}"
        else
          throw :nodiff, "(no diff)"
        end
      end

      def _is_binary?(path)
        ::File.open(path) do |file|

          buff = file.read(Chef::Config[:diff_filesize_threshold])
          buff = "" if buff.nil?
          return buff !~ /^[\r[:print:]]*$/
        end
      end

    end
  end
end

