#
# Author:: Noah Kantrowitz <noah@opscode.com>
# Cookbook Name:: supervisor
# Provider:: service
#
# Copyright:: 2011, Opscode, Inc <legal@opscode.com>
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

# TODO: is there an easier or better way to achieve this?
# For example, it would be good if by default supervisor could write its
# main errors and child errors to stdout or stderr in addition to writing
# them to its main and child log files.  See the following related
# supervisor issues:
#
#   https://github.com/Supervisor/supervisor/pull/245
#   https://github.com/Supervisor/supervisor/issues/170
#   https://github.com/Supervisor/supervisor/pull/103
#
def display_logfile
  if new_resource.supervisord_logfile.nil?
    Chef::Log.info "You can set supervisord_logfile to see the log file tail when an error occurs."
    return
  end
  begin
    # Note that if the [supervisord] loglevel is configured to debug, then:
    #
    # "the supervisord log file will record the stderr/stdout output of its
    #  child processes and extended info info about process state changes,
    #  which is useful for debugging a process which isn’t starting properly."
    #
    cmd = "tail -n 20 #{new_resource.supervisord_logfile}"
    result = Mixlib::ShellOut.new(cmd).run_command
    lines = result.stdout
  rescue Exception => e
    Chef::Log.warn "unable to read log file: #{e}"
    return
  end
  msg = "showing tail of log file #{new_resource.supervisord_logfile}:\n"
  msg << "-" * 60 + "\n"
  msg << lines
  msg << "-" * 60
  Chef::Log.debug msg
end

def raise_with_details(cmd, details)
  if Chef::Log.debug?
    display_logfile
  end
  raise "Supervisor command had unexpected output:\n$ #{cmd}\n#{details}\n--"
end

action :enable do
  converge_by("Enabling #{ new_resource }") do
    enable_service
  end
end

action :disable do
  if current_resource.state == 'UNAVAILABLE'
    Chef::Log.info "#{new_resource} is already disabled."
  else
    converge_by("Disabling #{new_resource}") do
      disable_service
    end
  end
end

action :start do
  case current_resource.state
  when 'UNAVAILABLE'
    raise "Supervisor service #{new_resource.name} cannot be started because it does not exist"
  when 'RUNNING'
    Chef::Log.debug "#{ new_resource } is already started."
  else
    converge_by("Starting #{ new_resource }") do
      cmd, result = supervisorctl('start')
      if !result.match(/#{new_resource.name}: started$/)
        raise_with_details(cmd, result)
      end
    end
  end
end

action :stop do
  case current_resource.state
  when 'UNAVAILABLE'
    raise "Supervisor service #{new_resource.name} cannot be stopped because it does not exist"
  when 'STOPPED'
    Chef::Log.debug "#{ new_resource } is already stopped."
  else
    converge_by("Stopping #{ new_resource }") do
      cmd, result = supervisorctl('stop')
      if !result.match(/#{new_resource.name}: stopped$/)
        raise_with_details(cmd, result)
      end
    end
  end
end

action :restart do
  case current_resource.state
  when 'UNAVAILABLE'
    raise "Supervisor service #{new_resource.name} cannot be restarted because it does not exist"
  else
    converge_by("Restarting #{ new_resource }") do
      cmd, result = supervisorctl('restart')
      if !result.match(/^#{new_resource.name}: started$/)
        raise_with_details(cmd, result)
      end
    end
  end
end

def enable_service
  execute "supervisorctl update" do
    action :nothing
    user "root"
  end

  template "#{node['supervisor']['dir']}/#{new_resource.service_name}.conf" do
    cookbook new_resource.template_cookbook
    source new_resource.template_source
    owner "root"
    group "root"
    mode "644"
    variables :prog => new_resource
    notifies :run, "execute[supervisorctl update]", :immediately
  end
end

def disable_service
  execute "supervisorctl update" do
    action :nothing
    user "root"
  end

  file "#{node['supervisor']['dir']}/#{new_resource.service_name}.conf" do
    action :delete
    notifies :run, "execute[supervisorctl update]", :immediately
  end
end

def supervisorctl(action)
  cmd = "supervisorctl #{action} #{cmd_line_args}"
  result = Mixlib::ShellOut.new(cmd).run_command
  return cmd, result.stdout.rstrip
end

def cmd_line_args
  name = new_resource.service_name
  if new_resource.numprocs > 1
    name += ':*'
  end
  name
end

def get_current_state(service_name)
  cmd = "supervisorctl status #{service_name}"
  result = Mixlib::ShellOut.new(cmd).run_command
  stdout = result.stdout
  if stdout.include? "No such process #{service_name}"
    "UNAVAILABLE"
  else
    match = stdout.match("(^#{service_name}\\s*)([A-Z]+)(.+)")
    if match.nil?
      raise "The supervisor service is not running as expected. " \
              "The command '#{cmd}' output:\n----\n#{stdout}\n----"
    end
    match[2]
  end
end

def load_current_resource
  @current_resource = Chef::Resource::SupervisorService.new(@new_resource.name)
  @current_resource.state = get_current_state(@new_resource.name)
end
