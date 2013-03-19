#
# Cookbook Name:: nova
# Recipe:: api-ec2
#
# Copyright 2012, Rackspace US, Inc.
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

require "uri"

class ::Chef::Recipe
  include ::Openstack
end

include_recipe "nova::nova-common"

platform_options = node["nova"]["platform"]

directory "/var/lock/nova" do
  owner node["nova"]["user"]
  group node["nova"]["group"]
  mode  00700

  action :create
end

package "python-keystone" do
  action :upgrade
end

platform_options["api_ec2_packages"].each do |pkg|
  package pkg do
    options platform_options["package_overrides"]

    action :upgrade
  end
end

service "nova-api-ec2" do
  service_name platform_options["api_ec2_service"]
  supports :status => true, :restart => true
  subscribes :restart, resources("template[/etc/nova/nova.conf]")

  action :enable
end

service_pass = service_password "nova"

identity_admin_endpoint = endpoint "identity-admin"
keystone_service_role = node["nova"]["keystone_service_chef_role"]
keystone = config_by_role keystone_service_role, "keystone"

ec2_admin_endpoint = endpoint "compute-ec2-admin"
ec2_public_endpoint = endpoint "compute-ec2-api"

bootstrap_token = secret "secrets", "keystone_bootstrap_token"
auth_uri = ::URI.decode identity_admin_endpoint.to_s

# Register Service Tenant
keystone_register "Register Service Tenant" do
  auth_uri auth_uri
  bootstrap_token bootstrap_token
  tenant_name node["nova"]["service_tenant_name"]
  tenant_description "Service Tenant"

  action :create_tenant
end

# Register Service User
keystone_register "Register Service User" do
  auth_uri auth_uri
  bootstrap_token bootstrap_token
  tenant_name node["nova"]["service_tenant_name"]
  user_name node["nova"]["service_user"]
  user_pass service_pass

  action :create_user
end

# Grant Admin role to Service User for Service Tenant
keystone_register "Grant 'admin' Role to Service User for Service Tenant" do
  auth_uri auth_uri
  bootstrap_token bootstrap_token
  tenant_name node["nova"]["service_tenant_name"]
  user_name node["nova"]["service_user"]
  role_name node["nova"]["service_role"]

  action :grant_role
end

# Register EC2 Service
keystone_register "Register EC2 Service" do
  auth_uri auth_uri
  bootstrap_token bootstrap_token
  service_name "ec2"
  service_type "ec2"
  service_description "EC2 Compatibility Layer"

  action :create_service
end

# Register EC2 Endpoint
keystone_register "Register Compute Endpoint" do
  auth_uri auth_uri
  bootstrap_token bootstrap_token
  service_type "ec2"
  endpoint_region node["nova"]["region"]
  endpoint_adminurl ::URI.decode ec2_admin_endpoint.to_s
  endpoint_internalurl ::URI.decode ec2_public_endpoint.to_s
  endpoint_publicurl ::URI.decode ec2_public_endpoint.to_s

  action :create_endpoint
end

template "/etc/nova/api-paste.ini" do
  source "api-paste.ini.erb"
  owner  node["nova"]["user"]
  group  node["nova"]["group"]
  mode   00644
  variables(
    :identity_admin_endpoint => identity_admin_endpoint,
    :service_pass => service_pass
  )

  notifies :restart, "service[nova-api-ec2]"
end
