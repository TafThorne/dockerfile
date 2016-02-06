#!/usr/bin/env ruby

# dockerfile.rb
# Copyright (C) 2015 Joe Ruether jrruethe@gmail.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

require "set"
require "yaml"
require "base64"

class Dockerfile
  
  def initialize

    @from       = "phusion/baseimage:0.9.18"
    @maintainer = "Joe Ruether <jrruethe@gmail.com>"    
    @user       = "root"
    @id         = `id -u`.chomp # 1000
    
    @requirements = Set.new
    @packages     = Set.new
    @envs         = Set.new
    @ports        = Set.new
    @volumes      = Set.new
    
    # Files to add before and after the run command
    @adds       = []
    @configures = []
    
    # Command lists for the run section
    @begin_commands        = []
    @pre_install_commands  = []
    @install_commands      = []
    @post_install_commands = []
    @run_commands          = []
    @end_commands          = []
    
    # Set if deb packages need dependencies to be resolved
    @deb_flag = false
    
    # Used to download deb files from the host  
    @ip_address = `ip route get 8.8.8.8 | awk '{print $NF; exit}'`.chomp

    # Ip address of the docker interface
    @docker_ip=`ifconfig docker0 | grep "inet addr"`.chomp.strip.split(/[ :]/)[2]
  end
  
  ##############################################################################
  public
  
  # string ()
  def finalize
    lines = []
    lines.push "FROM #{@from}"
    lines.push "MAINTAINER #{@maintainer}"
    lines.push ""
    @envs.each{|p| lines.push "ENV #{p[0]} #{p[1]}"}
    lines.push "" if !@envs.empty?
    @ports.each{|p| lines.push "EXPOSE #{p}"}
    lines.push "" if !@ports.empty?
    lines += @adds
    lines.push "" if !@adds.empty?
    lines.push build_run_command
    lines.push ""
    lines += @configures
    lines.push "" if !@configures.empty?
    @volumes.each{|v| lines.push "VOLUME #{v}"}
    lines.push "" if !@volumes.empty?
    lines.push "ENTRYPOINT [\"/sbin/my_init\"]"
  end
  
  # void (string)
  def set_user(user)
    @user = user
    @begin_commands.push comment "Creating user / Adjusting user permissions"
    @begin_commands.push "(groupadd -g #{@id} #{user} || true)"
    @begin_commands.push "((useradd -u #{@id} -g #{@id} -p #{user} -m #{user}) || \\" 
    @begin_commands.push " (usermod -u #{@id} #{user} && groupmod -g #{@id} #{user}))"
    @begin_commands.push "chown -R #{user}:#{user} /home/#{user}"
    @begin_commands.push blank
  end
  
  # void (string)
  def startup(text)
    @run_commands.push comment "Defining startup script"
    @run_commands.push "echo '#!/bin/sh -e' > /etc/rc.local"
    @run_commands.push blank if text.strip.start_with? "#"
    text.strip.split("\n").each do |line|
      line.strip!
      if line.start_with? "#"
        @run_commands.push comment line[1..-1].strip
      elsif line.match /^\s*$/
        @run_commands.push blank
      else
      
        # Escaping for the echo command
        line.gsub!("\"","\\\"")
        line.gsub!("${", "\\${")
        line.gsub!("$(", "\\$(")
        
        @run_commands.push "echo \"#{line}\" >> /etc/rc.local"
      end
    end
    @run_commands.push blank
  end
  
  # void (string, string)
  def add_cron(name, command)
    @run_commands.push comment "Adding #{name} cronjob"
    @run_commands.push "echo '#!/bin/sh -e' > /etc/cron.hourly/#{name}"
    @run_commands.push "echo 'logger #{name}: $(' >> /etc/cron.hourly/#{name}"

    command.strip.split("\n").each do |line|
      line.strip!
      if line.start_with? "#"
        @run_commands.push comment line[1..-1].strip
      elsif line.match /^\s*$/
        @run_commands.push blank
      else
      
        # Escaping for the echo command
        line.gsub!("\"","\\\"")
        line.gsub!("${", "\\${")
        line.gsub!("$(", "\\$(")
        
        @run_commands.push "echo \"#{line};\" >> /etc/cron.hourly/#{name}"
      end
    end

    @run_commands.push "echo ')' >> /etc/cron.hourly/#{name}"
    @run_commands.push "chmod 755 /etc/cron.hourly/#{name}"
    @run_commands.push blank
  end

  # void (string, string)
  def add_daemon(name, command)
    @run_commands.push comment "Installing #{name} daemon"
    @run_commands.push "mkdir -p /etc/service/#{name}"
    @run_commands.push "echo '#!/bin/sh' > /etc/service/#{name}/run"
    @run_commands.push "echo \"exec /sbin/setuser #{@user} #{command.gsub("\"","\\\"")}\" >> /etc/service/#{name}/run"
    @run_commands.push "chmod 755 /etc/service/#{name}/run"
    @run_commands.push blank
  end
  
  # void (string, string)
  def add_env(key, value)
    @envs.add [key, value]
  end
  
  # void (string, string)
  def add(source, destination = "/")
    @adds.push "ADD #{source} #{destination}"
  end
  
  # void (string, string)
  def configure(source, destination = "/")
    @configures.push "ADD #{source} #{destination}"
  end
  
  # void (string, string)
  def embed(source, destination = "/")
    @run_commands.push comment "Embedding #{source}"
    @run_commands.push "echo \\"
    
    s = Base64.encode64(File.open("#{source}", "rb").read)
    s.split("\n").each do |line|
      @run_commands.push "#{line} \\"
    end
    
    @run_commands.push "| tr -d ' ' | base64 -d > #{destination}"
    @run_commands.push blank
  end
  
  # void (string, string)
  def create(file, contents)
    @run_commands.push comment "Creating #{file}"
    @run_commands.push "echo \\"
    
    s = Base64.encode64(contents)
    s.split("\n").each do |line|
      @run_commands.push "#{line} \\"
    end
    
    @run_commands.push "| tr -d ' ' | base64 -d > #{file}"
    @run_commands.push blank
  end
  
  # void (string, string)
  def append(file, contents)
    @run_commands.push comment "Appending to #{file}"
    @run_commands.push "echo \\"
    
    s = Base64.encode64(contents)
    s.split("\n").each do |line|
      @run_commands.push "#{line} \\"
    end
    
    @run_commands.push "| tr -d ' ' | base64 -d >> #{file}"
    @run_commands.push blank
  end
  
  # void (int)
  def expose(port)
    @ports.add port
  end
  
  # void (string, string, string)
  def add_repository(name, deb, key = nil)
    @pre_install_commands.push comment "Adding #{name} repository"
    
    # If key is all hex
    if key =~ /^[0-9A-F]+$/i
      
      # Import the key using GPG
      @pre_install_commands.push "gpg --keyserver keys.gnupg.net --recv #{key}"
      @pre_install_commands.push "gpg --export #{key} | apt-key add -"
      @requirements.add "gnupg"
      
    elsif !key.nil?
      
      # Assume it is a url, download the key using wget
      @pre_install_commands.push "wget -O - #{key} | apt-key add -"
      @requirements.add "wget"
      @requirements.add "ssl-cert"
      
    end

    @pre_install_commands.push "echo '#{deb}' >> /etc/apt/sources.list.d/#{name.downcase}.list"
    @pre_install_commands.push blank

  end
  
  # void (string, string)
  def add_ppa(name, ppa)
    @pre_install_commands.push comment "Adding #{name} PPA"
    @pre_install_commands.push "add-apt-repository -y #{ppa}"
    @pre_install_commands.push blank
    
    @requirements.add "software-properties-common"
    @requirements.add "python-software-properties"
  end
  
  # void (string)
  def install_package(package)
    @packages.add package
  end
  
  # void (string)
  def install_deb(deb)
    @install_commands.push comment "Installing deb package"
    @install_commands.push "wget http://#{@ip_address}:8888/#{deb}"
    @install_commands.push "(dpkg -i #{deb} || true)"
    @install_commands.push blank
    @post_install_commands.push "rm -f #{deb}"
    
    @packages.add "wget"
    @deb_flag = true
  end
    
  # void (string)
  def run(text)
    text.split("\n").each do |line|
      line.strip!
      if line.start_with? "#"
        @run_commands.push comment line[1..-1].strip
      elsif line.match /^\s*$/
        @run_commands.push blank
      else
        @run_commands.push line
      end
    end
    @run_commands.push blank 
  end
  
  # void (string)
  def add_volume(volume)
    @end_commands.push comment "Fixing permission errors for volume"
    @end_commands.push "mkdir -p #{volume}"
    @end_commands.push "chown -R #{@user}:#{@user} #{volume}"
    @end_commands.push "chmod -R 700 #{volume}"
    @end_commands.push blank
    
    @volumes.add volume
  end
  
  ##############################################################################
  private
  
  # string (string)
  def comment(string)
    "`\# #{string}`"
  end
  
  # string ()
  def blank
    "\\"
  end
    
  # [string] ([string])
  def build_install_command(packages)
    
    # Convert the set to an array
    packages = packages.to_a
    
    # Specify the command
    command = "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends"
      
    # Make an array of paddings
    lines = [" " * command.length()] * packages.length
      
    # Overwrite the first line with the command
    lines[0] = command
    
    # Append the packages and backslashes to each line
    lines = lines.zip(packages).collect{|l, p| l += " #{p} \\"}
      
    # Convert the backslash on the last line to "&& \"
    lines[-1] = lines[-1][0..-2] + "&& \\"
    
    # Add comment and blank
    lines.insert(0, comment("Installing packages"))
    lines.push blank
  end
    
  # string ()
  def build_run_command
    
    lines = []
    
    # Any packages that were requirements can be removed from the packages list
    @packages = @packages.difference @requirements

    # Add beginning commands      
    lines += @begin_commands
    
    # If required packages were specified
    if !@requirements.empty?

      # Update the package list
      lines.push comment "Updating Package List"
      lines.push "DEBIAN_FRONTEND=noninteractive apt-get update"
      lines.push blank

      # Install requirements
      lines += build_install_command @requirements
    end
    
    # Run pre-install commands
    lines += @pre_install_commands
        
    # If packages are being installed 
    if @deb_flag || !@packages.empty?

       # Add apt-cacher proxy
       # lines.push comment "Adding apt-cacher-ng proxy"
       # lines.push "echo 'Acquire::http { Proxy \"http://#{@docker_ip}:3142\"; };' > /etc/apt/apt.conf.d/01proxy"
       # lines.push blank

       # Update
       lines.push comment "Updating Package List"
       lines.push "DEBIAN_FRONTEND=noninteractive apt-get update"
       lines.push blank
       
       # Install packages
       lines += build_install_command @packages unless @packages.empty?
       
       # Run install commands
       lines += @install_commands
       
       # If manual deb packages were specified
       if @deb_flag
         # Resolve their dependencies
         lines.push comment "Installing deb package dependencies"
         lines.push "DEBIAN_FRONTEND=noninteractive apt-get -y -f install --no-install-recommends"
         lines.push blank
       end
       
       # Run post-install commands
       if !@post_install_commands.empty?
         lines.push comment "Removing temporary files"
         lines += @post_install_commands
         lines.push blank
       end
       
       # Clean up
       lines.push comment "Cleaning up after installation"
       lines.push "DEBIAN_FRONTEND=noninteractive apt-get clean"
       lines.push "rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*"
       lines.push blank
       
       # Remove apt-cacher proxy
       # lines.push comment "Removing apt-cacher-ng proxy"
       # lines.push "rm -f /etc/apt/apt.conf.d/01proxy"
       # lines.push blank
    end

    # Run commands
    lines += @run_commands
        
    # End commands
    lines += @end_commands
    
    # Determine the longest line
    longest_length = lines.max_by(&:length).length
    
    # For each line
    lines.collect do |l|
      
      # Determine how many spaces needed to indent
      length_to_extend = longest_length - l.length
      
      # Indent the line
      length_to_extend += 1 if l.start_with? "`"
      l.insert(0, " " * (l.start_with?("`") ? 4 : 5))
      
      # Add or Extend end markers 
      if l.end_with? " && \\"
        length_to_extend += 5
        l.insert(-6, " " * length_to_extend)
      elsif l.end_with? " \\"
        length_to_extend += 5
        l.insert(-3, " " * length_to_extend)
      else
        l.insert(-1, " " * length_to_extend)
        l.insert(-1, " && \\")
      end
      
    end
    
    # First line should start with "RUN"
    lines[0][0..2] = "RUN"
    
    # Last line should not end with marker
    lines[-1].gsub! " && \\", ""
    lines[-1].gsub! " \\", ""
    
    # Last line might be blank now, do it again
    if lines[-1].match /^\s*$/
      lines.delete_at -1
      
      # Last line should not end with marker
      lines[-1].gsub! " && \\", ""
      lines[-1].gsub! " \\", ""
    end
      
    # Make a string
    lines.join "\n"
    
  end
end

################################################################################
# Parse Dockerfile.yml

dockerfile = Dockerfile.new
yaml = YAML::load_file("Dockerfile.yml")

# Parse User tag
dockerfile.set_user yaml["User"] if yaml.has_key? "User"

# Parse Startup tag
dockerfile.startup yaml["Startup"] if yaml.has_key? "Startup"

# Parse Env tag
yaml["Env"].each do |e|
  dockerfile.add_env(e.first[0], e.first[1])
end if yaml.has_key? "Env"
    
# Parse Daemon tag
yaml["Daemon"].each do |d|
  dockerfile.add_daemon(d["Name"], d["Command"])
end if yaml.has_key? "Daemon"
  
# Parse Add tag
yaml["Add"].each do |i| 
  if i.is_a? Hash
    dockerfile.add i.first[0], i.first[1]
  else
    dockerfile.add i
  end
end if yaml.has_key? "Add"

# Parse Repositories tag
yaml["Repositories"].each do |r|
  if r["Url"].start_with? "deb "
    dockerfile.add_repository(r["Name"], r["Url"], r["Key"])
  elsif r["Url"].start_with? "ppa:"
    dockerfile.add_ppa(r["Name"], r["Url"])
  end
end if yaml.has_key? "Repositories"

# Parse Install tag
yaml["Install"].each do |package|
  if package.end_with? ".deb"
    dockerfile.install_deb package
  else
    dockerfile.install_package package
  end
end if yaml.has_key? "Install"

# Parse Run tag
dockerfile.run yaml["Run"] if yaml.has_key? "Run"

# Parse Configure tag
yaml["Configure"].each do |i| 
  if i.is_a? Hash
    dockerfile.configure i.first[0], i.first[1]
  else
    dockerfile.configure i
  end
end if yaml.has_key? "Configure"

# Parse Embed tag
yaml["Embed"].each do |i| 
  if i.is_a? Hash
    dockerfile.embed i.first[0], i.first[1]
  else
    dockerfile.embed i
  end
end if yaml.has_key? "Embed"

# Parse Expose tag
yaml["Expose"].each do |port|
  dockerfile.expose port
end if yaml.has_key? "Expose"

# Parse Volumes tag
yaml["Volumes"].each do |volume|
  dockerfile.add_volume volume
end if yaml.has_key? "Volumes"

# Parse Cron tag
yaml["Cron"].each do |cron|
   dockerfile.add_cron(cron["Name"], cron["Command"])
end if yaml.has_key? "Cron"

# Output Dockerfile
puts dockerfile.finalize
