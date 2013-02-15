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

require 'chef/provider/file_strategy/content_strategy'

class Chef
  class Provider
    class FileStrategy
      class ContentFromResource < ContentStrategy
        def has_content?
          @new_resource.content != nil
        end

        def filename
          @filename ||= tempfile.path
        end

        def cleanup
          @tempfile.unlink unless @tempfile.nil?
        end

        private

        def tempfile
          @tempfile ||= begin
            tempfile = Tempfile.open(::File.basename(@new_resource.name))
            tempfile.write(@new_resource.content)
            tempfile.close
            tempfile
          end
        end

      end
    end
  end
end
