# frozen_string_literal: true

#
# Cookbook Name:: aws-parallelcluster
# Recipe:: dns_config
#
# Copyright 2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file.
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
# See the License for the specific language governing permissions and limitations under the License.

if node['cfncluster']['cfn_scheduler'] == 'slurm'
  # Heterogeneous Instance Type
  if node['cfncluster']['cfn_dns_domain'].nil? || node['cfncluster']['cfn_dns_domain'] == "NONE"
    Chef::Log.info("Cluster DNS domain not configured, using private hostname.")

    node.force_default['cfncluster']['assigned_hostname'] = node['ec2']['local_hostname']
    node.force_default['cfncluster']['assigned_short_hostname'] = node['ec2']['local_hostname'].split('.')[0].to_s
  else

    # Configure custom dns domain
    # Function to extend DNS resolver configuration by appending the Route53 domain created within the cluster
    # ($CLUSTER_NAME.pcluster) and be listed as a "search" domain in the resolv.conf file.
    if platform?('ubuntu') && node['platform_version'] == "18.04"

      Chef::Log.info("Appending search domain '#{node['cfncluster']['cfn_dns_domain']}' to /etc/systemd/resolved.conf")
      # Configure resolved to automatically append Route53 search domain in resolv.conf.
      # On Ubuntu18 resolv.conf is managed by systemd-resolved.
      replace_or_add "append Route53 search domain in /etc/systemd/resolved.conf" do
        path "/etc/systemd/resolved.conf"
        pattern "Domains=*"
        line "Domains=#{node['cfncluster']['cfn_dns_domain']}"
      end
    else

      Chef::Log.info("Appending search domain '#{node['cfncluster']['cfn_dns_domain']}' to /etc/dhcp/dhclient.conf")
      # Configure dhclient to automatically append Route53 search domain in resolv.conf
      # - on CentOS6 resolv.conf is managed by network + dhclient,
      # - on CentOS7, Alinux and Alinux2 by NetworkManager + dhclient,
      # - on Ubuntu16 by networking + dhclient
      replace_or_add "append Route53 search domain in /etc/dhcp/dhclient.conf" do
        path "/etc/dhcp/dhclient.conf"
        pattern "append domain-name*"
        line "append domain-name \" #{node['cfncluster']['cfn_dns_domain']}\";"
      end

      if platform?('centos') && node['platform_version'].to_i < 7
        # On CentOS6 there is a dhclient configuration file for eth0
        replace_or_add "append Route53 search domain in /etc/dhcp/dhclient-eth0.conf" do
          path "/etc/dhcp/dhclient-eth0.conf"
          pattern "append domain-name*"
          line "append domain-name \" #{node['cfncluster']['cfn_dns_domain']}\";"
        end
      end
    end
    restart_network_service

    if node['cfncluster']['cfn_node_type'] == "ComputeFleet"
      # For compute node retrieve assigned hostname from DynamoDB and configure it
      # - hostname: $QUEUE-static-$INSTANCE_TYPE_1-[1-$MIN1]
      # - fqdn: $QUEUE-static-$INSTANCE_TYPE_1-[1-$MIN1].$CLUSTER_NAME.pcluster
      ruby_block "retrieve assigned hostname" do
        block do
          assigned_hostname = compute_hostname
          node.force_default['cfncluster']['assigned_hostname'] = "#{assigned_hostname}.#{node['cfncluster']['cfn_dns_domain']}"
          node.force_default['cfncluster']['assigned_short_hostname'] = assigned_hostname.split('.')[0].to_s
        end
        retries 5
        retry_delay 3
      end

    else
      # Head node
      node.force_default['cfncluster']['assigned_hostname'] = node['ec2']['local_hostname']
      node.force_default['cfncluster']['assigned_short_hostname'] = node['ec2']['local_hostname'].split('.')[0].to_s
    end
  end

else
  # Single Instance Type
  node.force_default['cfncluster']['assigned_hostname'] = node['ec2']['local_hostname']
  node.force_default['cfncluster']['assigned_short_hostname'] = node['ec2']['local_hostname'].split('.')[0].to_s
end

# Configure fqdn and /etc/hosts
hostname "set fqdn hostname and /etc/hosts" do
  compile_time false
  hostname(lazy { node['cfncluster']['assigned_hostname'].to_s })
end

# Configure short hostname
if platform_family?('rhel') && node['platform_version'].to_i < 7 ||
   platform_family?('amazon') && node['platform_version'].to_i != 2

  # hostnamectl not present in alinux1 and centos6
  replace_or_add "set hostname in /etc/sysconfig/network" do
    path "/etc/sysconfig/network"
    pattern "HOSTNAME=*"
    line(lazy { "HOSTNAME=#{node['cfncluster']['assigned_short_hostname']}" })
  end
  execute "execute hostname set command" do
    command(lazy { "hostname #{node['cfncluster']['assigned_short_hostname']}" })
  end

else
  execute "execute hostnamamectl set command" do
    command(lazy { "hostnamectl set-hostname #{node['cfncluster']['assigned_short_hostname']}" })
  end
end