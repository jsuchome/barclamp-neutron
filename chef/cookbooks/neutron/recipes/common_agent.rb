# Copyright 2013 Dell, Inc.
# Copyright 2014-2015 SUSE Linux GmbH
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

neutron = nil
if node.attribute?(:cookbook) and node[:cookbook] == "nova"
  neutrons = search(:node, "roles:neutron-server AND roles:neutron-config-#{node[:nova][:neutron_instance]}")
  neutron = neutrons.first || raise("Neutron instance '#{node[:nova][:neutron_instance]}' for nova not found")
else
  neutron = node
end

# Disable rp_filter
ruby_block "edit /etc/sysctl.conf for rp_filter" do
  block do
    rc = Chef::Util::FileEdit.new("/etc/sysctl.conf")
    rc.search_file_replace_line(/^net.ipv4.conf.all.rp_filter/, 'net.ipv4.conf.all.rp_filter = 0')
    rc.write_file
  end
  only_if { node[:platform] == "suse" }
end

directory "create /etc/sysctl.d for disable-rp_filter" do
  path "/etc/sysctl.d"
  mode "755"
end

disable_rp_filter_file = "/etc/sysctl.d/50-neutron-disable-rp_filter.conf"
cookbook_file disable_rp_filter_file do
  source "sysctl-disable-rp_filter.conf"
  mode "0644"
end

bash "reload disable-rp_filter-sysctl" do
  code "/sbin/sysctl -e -q -p #{disable_rp_filter_file}"
  action :nothing
  subscribes :run, resources(:cookbook_file=> disable_rp_filter_file), :delayed
end

if neutron[:neutron][:use_gitrepo]
  neutron_path = "/opt/neutron"
  venv_path = neutron[:neutron][:use_virtualenv] ? "#{neutron_path}/.venv" : nil

  pfs_and_install_deps "neutron" do
    cookbook "neutron"
    cnode neutron
    virtualenv venv_path
    path neutron_path
    wrap_bins [ "neutron", "neutron-rootwrap" ]
  end

  create_user_and_dirs("neutron")

  execute "neutron_cp_policy.json" do
    command "cp /opt/neutron/etc/policy.json /etc/neutron/"
    creates "/etc/neutron/policy.json"
  end
  execute "neutron_cp_plugins" do
    command "cp -r /opt/neutron/etc/neutron/plugins /etc/neutron/plugins"
    creates "/etc/neutron/plugins"
  end
  execute "neutron_cp_rootwrap" do
    command "cp -r /opt/neutron/etc/neutron/rootwrap.d /etc/neutron/rootwrap.d"
    creates "/etc/neutron/rootwrap.d"
  end
  cookbook_file "/etc/neutron/rootwrap.conf" do
    cookbook "neutron"
    source "neutron-rootwrap.conf"
    mode 00644
    owner "root"
    group node[:neutron][:platform][:group]
  end
end

# openvswitch configuration specific to ML2
if neutron[:neutron][:networking_plugin] == 'ml2' and
   neutron[:neutron][:ml2_mechanism_drivers].include?("openvswitch")

  # Install the package now as neutron-ovs-cleanup service is shipped with this
  package node[:neutron][:platform][:ovs_agent_pkg]

  unless %w(debian ubuntu).include? node.platform
    # Note: this must not be started! This service only makes sense on boot.
    service "neutron-ovs-cleanup" do
      service_name "openstack-neutron-ovs-cleanup" if %w(suse).include?(node.platform)
      action [ :enable ]
    end
  else
    # Arrange for neutron-ovs-cleanup to be run on bootup of compute nodes only
    unless neutron.name == node.name
      cookbook_file "/etc/init.d/neutron-ovs-cleanup" do
        source "neutron-ovs-cleanup"
        mode 00755
      end
      link "/etc/rc2.d/S20neutron-ovs-cleanup" do
        to "../init.d/neutron-ovs-cleanup"
      end
      link "/etc/rc3.d/S20neutron-ovs-cleanup" do
        to "../init.d/neutron-ovs-cleanup"
      end
      link "/etc/rc4.d/S20neutron-ovs-cleanup" do
        to "../init.d/neutron-ovs-cleanup"
      end
      link "/etc/rc5.d/S20neutron-ovs-cleanup" do
        to "../init.d/neutron-ovs-cleanup"
      end
    end
  end
end

# Cleanup the ovs-usurp init scripts that might still be existing from an old
# install (before the network barclamp created the ovs-bridge configuration).
if node[:platform] == "suse"
  [ "br-public", "br-fixed" ].each do |name|
    service "ovs-usurp-config-#{name}" do
      # There's no need to stop anything here. I might even cut us off the 
      # network.
      action [:disable]
      only_if { ::File.exists?("/etc/init.d/ovs-usurp-config-#{name}") }
    end
    file "/etc/init.d/ovs-usurp-config-#{name}" do
      action :delete
    end
  end
end

neutron_network_ha = node.roles.include?("neutron-network") && neutron[:neutron][:ha][:network][:enabled]

# ML2 configuration: L2 agent and L3 agent
if neutron[:neutron][:networking_plugin] == "ml2"
  ml2_mech_drivers = neutron[:neutron][:ml2_mechanism_drivers]
  ml2_type_drivers = neutron[:neutron][:ml2_type_drivers]

  case
  when ml2_mech_drivers.include?("openvswitch")
    # package is already installed

    neutron_agent = node[:neutron][:platform][:ovs_agent_name]
    agent_config_path = "/etc/neutron/plugins/openvswitch/ovs_neutron_plugin.ini"
    interface_driver = "neutron.agent.linux.interface.OVSInterfaceDriver"
    external_network_bridge = "br-public"
    bridge_mappings = ""
    if neutron[:neutron][:use_dvr] || node.roles.include?("neutron-network")
      bridge_mappings = "floating:br-public"
    end
    if ml2_type_drivers.include?("vlan")
      bridge_mappings += ", " unless bridge_mappings.empty?
      bridge_mappings += "physnet1:br-fixed"
    end
  when ml2_mech_drivers.include?("linuxbridge")
    package node[:neutron][:platform][:lb_agent_pkg]

    neutron_agent = node[:neutron][:platform][:lb_agent_name]
    agent_config_path = "/etc/neutron/plugins/linuxbridge/linuxbridge_conf.ini"
    interface_driver = "neutron.agent.linux.interface.BridgeInterfaceDriver"
    external_network_bridge = ""
    physnet = node[:crowbar_wall][:network][:nets][:nova_fixed].first
    interface_mappings = "physnet1:" + physnet
    if neutron[:neutron][:use_dvr] || node.roles.include?("neutron-network")
      external_networks = ["nova_floating"]
      ext_physnet_map = NeutronHelper.get_neutron_physnets(node, external_networks)
      external_networks.each do |net|
        ext_iface = node[:crowbar_wall][:network][:nets][net].last
        next if ext_physnet_map[net] == "physnet1"
        mapping = ", " + ext_physnet_map[net] + ":" + ext_iface
        interface_mappings += mapping
      end
    end
  end

  # include neutron::common_config only now, after we've installed packages
  include_recipe "neutron::common_config"

  # L2 agent
  if neutron[:neutron][:use_gitrepo]
    case
    when ml2_mech_drivers.include?("openvswitch")
      neutron_agent = "neutron-openvswitch-agent"
    when ml2_mech_drivers.include?("linuxbridge")
      neutron_agent = "neutron-linuxbridge-agent"
    end

    link_service neutron_agent do
      virtualenv venv_path
      bin_name "#{neutron_agent} --config-file #{agent_config_path} --config-dir /etc/neutron/"
    end
  end

  case
  when ml2_mech_drivers.include?("openvswitch")
    directory "/etc/neutron/plugins/openvswitch/" do
      mode 00755
      owner "root"
      group node[:neutron][:platform][:group]
      action :create
      recursive true
      not_if { node[:platform] == "suse" }
    end

    template agent_config_path do
      cookbook "neutron"
      source "ovs_neutron_plugin.ini.erb"
      owner "root"
      group node[:neutron][:platform][:group]
      mode "0640"
      variables(
        :ml2_type_drivers => ml2_type_drivers,
        :tunnel_types => ml2_type_drivers.select { |t| ["vxlan", "gre"].include?(t) },
        :use_l2pop => neutron[:neutron][:use_l2pop] && (ml2_type_drivers.include?("gre") || ml2_type_drivers.include?("vxlan")),
        :dvr_enabled => neutron[:neutron][:use_dvr],
        :bridge_mappings => bridge_mappings
      )
    end
  when ml2_mech_drivers.include?("linuxbridge")
    directory "/etc/neutron/plugins/linuxbridge/" do
      mode 00755
      owner "root"
      group node[:neutron][:platform][:group]
      action :create
      recursive true
      not_if { node[:platform] == "suse" }
    end

    template agent_config_path do
      cookbook "neutron"
      source "linuxbridge_conf.ini.erb"
      owner "root"
      group node[:neutron][:platform][:group]
      mode "0640"
      variables(
        :interface_mappings => interface_mappings,
        :ml2_type_drivers => ml2_type_drivers,
        :vxlan_mcast_group => neutron[:neutron][:vxlan][:multicast_group],
        :use_l2pop => neutron[:neutron][:use_l2pop] && ml2_type_drivers.include?("vxlan")
      )
    end
  end

  service neutron_agent do
    supports :status => true, :restart => true
    action [:enable, :start]
    subscribes :restart, resources("template[#{agent_config_path}]")
    subscribes :restart, resources("template[/etc/neutron/neutron.conf]")
    provider Chef::Provider::CrowbarPacemakerService if neutron_network_ha
  end

  # L3 agent
  if neutron[:neutron][:use_dvr] || node.roles.include?("neutron-network")
    unless neutron[:neutron][:use_gitrepo]
      package node[:neutron][:platform][:l3_agent_pkg]
    else
      link_service "neutron-l3-agent" do
        virtualenv venv_path
        bin_name "neutron-l3-agent --config-dir /etc/neutron/"
      end
    end

    template "/etc/neutron/l3_agent.ini" do
      source "l3_agent.ini.erb"
      owner "root"
      group node[:neutron][:platform][:group]
      mode "0640"
      variables(
        :debug => neutron[:neutron][:debug],
        :interface_driver => interface_driver,
        :use_namespaces => "True",
        :handle_internal_only_routers => "True",
        :metadata_port => 9697,
        :send_arp_for_ha => 3,
        :periodic_interval => 40,
        :periodic_fuzzy_delay => 5,
        :external_network_bridge => external_network_bridge,
        :dvr_enabled => neutron[:neutron][:use_dvr],
        :dvr_mode => node.roles.include?("neutron-network") ? "dvr_snat" : "dvr"
      )
    end

    service node[:neutron][:platform][:l3_agent_name] do
      service_name "neutron-l3-agent" if neutron[:neutron][:use_gitrepo]
      supports :status => true, :restart => true
      action [:enable, :start]
      subscribes :restart, resources("template[/etc/neutron/neutron.conf]")
      subscribes :restart, resources("template[/etc/neutron/l3_agent.ini]")
      provider Chef::Provider::CrowbarPacemakerService if neutron_network_ha
    end
  end
end

# Metadata agent
unless neutron[:neutron][:use_gitrepo]
  package node[:neutron][:platform][:metadata_agent_pkg]
else
  link_service "neutron-metadata-agent" do
    virtualenv venv_path
    bin_name "neutron-metadata-agent --config-dir /etc/neutron/ --config-file /etc/neutron/metadata_agent.ini"
  end
end

#TODO: nova should depend on neutron, but neutron also depends on nova
# so we have to do something like this
novas = search(:node, "roles:nova-multi-controller") || []
if novas.length > 0
  nova = novas[0]
  nova = node if nova.name == node.name
else
  nova = node
end
metadata_host = CrowbarHelper.get_host_for_admin_url(nova, (nova[:nova][:ha][:enabled] rescue false))
metadata_port = nova[:nova][:ports][:metadata] rescue 8775
metadata_protocol = (nova[:nova][:ssl][:enabled] ? "https" : "http") rescue "http"
metadata_insecure = (nova[:nova][:ssl][:enabled] && nova[:nova][:ssl][:insecure]) rescue false
metadata_proxy_shared_secret = (nova[:nova][:neutron_metadata_proxy_shared_secret] rescue '')

keystone_settings = KeystoneHelper.keystone_settings(neutron, @cookbook_name)

template "/etc/neutron/metadata_agent.ini" do
  source "metadata_agent.ini.erb"
  owner "root"
  group node[:neutron][:platform][:group]
  mode "0640"
  variables(
    :debug => neutron[:neutron][:debug],
    :keystone_settings => keystone_settings,
    :auth_region => keystone_settings['endpoint_region'],
    :neutron_insecure => neutron[:neutron][:ssl][:insecure],
    :nova_metadata_host => metadata_host,
    :nova_metadata_port => metadata_port,
    :nova_metadata_protocol => metadata_protocol,
    :nova_metadata_insecure => metadata_insecure,
    :metadata_proxy_shared_secret => metadata_proxy_shared_secret
  )
end

service node[:neutron][:platform][:metadata_agent_name] do
  service_name "neutron-metadata-agent" if neutron[:neutron][:use_gitrepo]
  supports :status => true, :restart => true
  action [:enable, :start]
  subscribes :restart, resources("template[/etc/neutron/neutron.conf]")
  subscribes :restart, resources("template[/etc/neutron/metadata_agent.ini]")
  provider Chef::Provider::CrowbarPacemakerService if neutron_network_ha
end

# VMware specific code
if neutron[:neutron][:networking_plugin] == "vmware"
  include_recipe "neutron::vmware_support"
  # We don't need anything more installed or configured on
  # compute nodes except openvswitch packages with stt.
  # For NSX plugin no neutron packages are needed.
end
