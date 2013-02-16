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

require 'chef/mixin/template'
require 'chef/provider/file_strategy/content_strategy'

class Chef
  class Provider
    class FileStrategy
      class ContentFromTemplate < ContentStrategy
        include Chef::Mixin::Template

        attr_accessor :template_location
        attr_accessor :template_finder

        def filename
          @filename ||= render_with_context(template_location)
        end

        def cleanup
          @tempfile.unlink unless @tempfile.nil?
        end

        private

        def render_with_context(template_location)
          context = {}
          context.merge!(@new_resource.variables)
          context[:node] = @run_context.node
          context[:template_finder] = template_finder
          render_template(IO.read(template_location), context) { |t| @tempfile = t }
          @tempfile.path
        end
      end
    end
  end
end
