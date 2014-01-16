# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class GlanceService < ServiceObject

  def initialize(thelogger)
    @bc_name = "glance"
    @logger = thelogger
  end

# Turn off multi proposal support till it really works and people ask for it.
  def self.allow_multiple_proposals?
    false
  end

  def proposal_dependencies(role)
    answer = []
    deps = ["database"]
    deps << "keystone" if role.default_attributes[@bc_name]["use_keystone"]
    deps << "git" if role.default_attributes[@bc_name]["use_gitrepo"]
    deps << "ceph" if role.default_attributes[@bc_name]["default_store"] == "rbd"
    deps.each do |dep|
      answer << { "barclamp" => dep, "inst" => role.default_attributes[@bc_name]["#{dep}_instance"] }
    end
    answer
  end

  def create_proposal
    @logger.debug("Glance create_proposal: entering")
    base = super

    nodes = NodeObject.all
    nodes.delete_if { |n| n.nil? or n.admin? }
    if nodes.size >= 1
      base["deployment"]["glance"]["elements"] = {
        "glance-server" => [ nodes.first[:fqdn] ]
      }
    end

    base["attributes"][@bc_name]["service_password"] = '%012d' % rand(1e12)

    insts = ["database", "rabbitmq", "keystone", "git", "ceph"]
    insts.each do |inst|
      base["attributes"][@bc_name]["#{inst}_instance"] = ""
      begin
        instService = eval "#{inst.capitalize}Service.new(@logger)"
        instes = instService.list_active[1]
        if instes.empty?
          # No actives, look for proposals
          instes = instService.proposals[1]
        end
        base["attributes"][@bc_name]["#{inst}_instance"] = instes[0] unless instes.empty?
      rescue
        @logger.info("#{@bc_name} create_proposal: no #{inst} found")
      end
    end

    if base["attributes"][@bc_name]["database_instance"] == ""
      raise(I18n.t('model.service.dependency_missing', :name => @bc_name, :dependson => "database"))
    end

    @logger.debug("Glance create_proposal: exiting")
    base
  end

  def validate_proposal_after_save proposal
    super
    if proposal["attributes"][@bc_name]["use_gitrepo"]
      gitService = GitService.new(@logger)
      gits = gitService.list_active[1].to_a
      if not gits.include?proposal["attributes"][@bc_name]["git_instance"]
        raise(I18n.t('model.service.dependency_missing', :name => @bc_name, :dependson => "git"))
      end
    end

    # require ceph instance if storage backend is Rados
    if proposal["attributes"][@bc_name]["default_store"] == "rbd"
      begin
      cephService = CephService.new(@logger)
      cephs = cephService.list_active[1].to_a
      if not cephs.include?proposal["attributes"][@bc_name]["ceph_instance"]
        raise(I18n.t('model.service.dependency_missing', :name => @bc_name, :dependson => "ceph"))
      end
      rescue
        raise(I18n.t('model.service.dependency_missing', :name => @bc_name, :dependson => "ceph"))
      end
    end
  end


  def apply_role_pre_chef_call(old_role, role, all_nodes)
    @logger.debug("Glance apply_role_pre_chef_call: entering #{all_nodes.inspect}")
    return if all_nodes.empty?

    # Update images paths
    nodes = NodeObject.find("roles:provisioner-server")
    unless nodes.nil? or nodes.length < 1
      admin_ip = nodes[0].get_network_by_type("admin")["address"]
      web_port = nodes[0]["provisioner"]["web_port"]
      # substitute the admin web portal
      new_array = []
      role.default_attributes["glance"]["images"].each do |item|
        new_array << item.gsub("|ADMINWEB|", "#{admin_ip}:#{web_port}")
      end
      role.default_attributes["glance"]["images"] = new_array
      role.save
    end

    if role.default_attributes["glance"]["api"]["bind_open_address"]
      net_svc = NetworkService.new @logger
      tnodes = role.override_attributes["glance"]["elements"]["glance-server"]
      tnodes.each do |n|
        net_svc.allocate_ip "default", "public", "host", n
      end unless tnodes.nil?
    end

    # append ceph-glance role if ceph is set as default storage backend
    if role.default_attributes[@bc_name]["default_store"] == "rbd"
      role.run_list << "role[glance-server]"
      role.run_list << "role[ceph-glance]"
      role.save
    end

    @logger.debug("Glance apply_role_pre_chef_call: leaving")
  end

end

