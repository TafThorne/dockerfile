#!/usr/bin/env ruby

# dockerfile.rb
# Copyright (C) 2016 Joe Ruether jrruethe@gmail.com
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

# require "pry"
require "set"
require "yaml"
require "base64"
require "digest"
require "fileutils"
require "zlib"
require "stringio"

# Patches
class String

  # string (void)
  def gzip
    io = StringIO.new("w")
    gz = Zlib::GzipWriter.new(io)
    gz.write(self)
    gz.close
    return io.string
  end

  # string (void)
  def base64
    return Base64.encode64(self)
  end

  # string (void)
  def flatten
     self.strip.gsub(/\s*\\\s*/, " ")
  end

  # string (void)
  def squash
    self.gsub(/\s+/, " ")
  end

  # string (void)
  def escape
     self.gsub("\"","\\\"").
          gsub("${", "\\${").
          gsub("$(", "\\$(")
  end

  # string (void)
  def comment
     "`\# #{self}`"
  end

  # string (string)
  def echo_to(file)
     "echo \"#{self.escape}\" >> #{file}"
  end

  # [string] (string)
  def write_to(file)
    lines = []
    self.strip.split("\n").each do |line|
      line.strip!
      lines.push line.echo_to(file)
    end
    lines.align(" >> #{file}")
  end

  # string (string)
  def run_as(name)
    "/sbin/setuser #{name} #{self}"
  end

  # string (void)
  def deindent
    # TODO: Derive the 6 from the shortest non-empty line
    self.gsub(/^ {6}/, "")
  end

  # string (map)
  def substitute(mapping)
    s = self.dup
    mapping.each_pair do |k, v|
      s.gsub!(/\$#{k}/, v.to_s)
    end
    return s
  end

end

class Array

  # [string] (int)
  def indent(count)
    self.collect do |l|
      # l.insert(0, " " * count)
      (" " * count) + l
    end
  end

  # [string] (string)
  def append(token)
    self.collect do |l|
      l.insert(-1, token)
    end
  end

  # [string] (string | regexp)
  def align(match)
    longest_length = self.max_by{|s| s.index(match) || 0}.index(match)
    self.collect! do |l| 
      index = l.index(match)
      unless index.nil?
        l.insert(index, " " * (longest_length - index))
      else
        l
      end
    end unless longest_length.nil?
    self
  end

end

class Hash

  def downcase
    self.keys.each do |key|
      new_key = key.to_s.downcase
      self[new_key] = self.delete(key)
      #if self[new_key].is_a? Hash
      #  self[new_key].downcase
      #end
    end
    self
  end

end

class Dockerfile
  
  def initialize

    @from       = "phusion/baseimage:0.9.18"
    @email      = "Unknown"
    @name       = File.basename(Dir.pwd)
    @network    = "bridge"
    @user       = "root"
    @workdir    = ""
    @id         = `id -u`.chomp # 1000
    @app        = ""
    @gui        = false
    @persistent = false
    
    @depends      = Set.new
    @envs         = Set.new
    @packages     = Set.new
    @ports        = Set.new
    @requirements = Set.new
    @volumes      = Set.new

    # Keep a mapping of environment variables
    @environment_variables = {}
    
    # Files to add before and after the run command
    @copies     = []
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
    @docker_ip=`/sbin/ifconfig docker0 | grep "inet addr"`.chomp.strip.split(/[ :]/)[2]
  end
  
  ##############################################################################
  public
  
  # string ()
  def to_s

    lines = []

    # Build the run commands
    run_command = build_run_command

    # Determine working directory
    if !@workdir.empty?
      workdir = @workdir
    elsif @user == "root"
      workdir = "/root"
    else
      workdir = "/home/#{@user}"
    end

    lines.push "# #{@name} #{Time.now}"
    lines.push "FROM #{@from}"
    lines.push "MAINTAINER #{@email}"
    lines.push ""
    lines.push "# Environment Variables"                                     if !@envs.empty?
    @envs.each{|p| lines.push "ENV #{p[0]} #{p[1]}"}
    lines.push ""                                                            if !@envs.empty?
    lines.push "# Exposed Ports"                                             if !@ports.empty?
    @ports.each{|p| lines.push "EXPOSE #{p}"}
    lines.push ""                                                            if !@ports.empty?
    lines.push "# Copy files into the image"                                 if !@copies.empty?
    lines.push ""                                                            if !@copies.empty?
    lines += @copies
    lines.push "# Set working directory"
    lines.push "WORKDIR #{workdir}"
    lines.push ""
    lines.push "# Run commands"                                              if !run_command.empty?
    lines.push run_command                                                   if !run_command.empty?
    lines.push ""                                                            if !run_command.empty?
    lines.push "# Copy files into the image, overwriting any existing files" if !@configures.empty?
    lines.push ""                                                            if !@configures.empty?
    lines += @configures
    lines.push ""                                                            if !@configures.empty?
    lines.push "# Set up external volumes"                                   if !@volumes.empty?
    @volumes.each{|v| lines.push "VOLUME #{v}"}
    lines.push ""                                                            if !@volumes.empty?
    lines.push "# Copy source dockerfiles into the image"
    lines.push "COPY Dockerfile.yml /Dockerfile.yml"
    lines.push "COPY Dockerfile     /Dockerfile"
    lines.push ""
    lines.push "# Enter the container"

    if !@app.empty?
      user = @user != "root" ? "\"setuser\", \"#{@user}\", " : ""
      lines.push "CMD [\"/sbin/my_init\", \"--quiet\", \"--\", #{user}\"#{@app}\"]"
    else
      lines.push "ENTRYPOINT [\"/sbin/my_init\"]"
      lines.push "CMD [\"\"]"
    end

    lines.push ""
    lines.join "\n"
  end
  
  ##############################################################################

  # void (string)
  def app(command)
    if @app.empty?
      @app = command
    else
      @app = "bash"
    end
  end

  # void (string, string)
  def copy(source, destination = nil)
    destination = destination ? destination : source
    @copies.push "# SHA256: #{Digest::SHA256.file(source.substitute(@environment_variables)).hexdigest}"
    @copies.push "COPY #{source} #{destination}"
    @copies.push ""
  end

  # void (string, string)
  def create(file, contents)
    @run_commands.push "Creating #{file}".comment
    @run_commands.push "mkdir -p #{File.dirname(file)}"
    @run_commands += contents.write_to file 
    @run_commands.push "chown #{@user}:#{@user} #{file}"
    @run_commands.push "chmod 755 #{file}"
    @run_commands.push blank
  end

  # void (string, string)
  def cron(name, command = nil)

    if command.nil?
      command = name
      name = "a"
    end

    file = "/etc/cron.hourly/#{name}"
    @run_commands.push "Adding #{name} cronjob".comment
    @run_commands.push "#!/bin/sh -e".echo_to file
    @run_commands.push "logger #{name}: $(".echo_to file
    @run_commands += command.write_to file
    @run_commands.push ")".echo_to file
    @run_commands.align ">> #{file}"
    @run_commands.push "chmod 755 #{file}"
    @run_commands.push blank
  end

  # void (string, string)
  def daemon(name, command = nil)

    if command.nil?
      command = name
      name = @name
    end

    file = "/etc/service/#{name}/run"
    @run_commands.push "Installing #{name} daemon".comment
    @run_commands.push "mkdir -p /etc/service/#{name}"
    @run_commands.push "#!/bin/sh".echo_to file
    @run_commands.push "exec /sbin/setuser #{@user} #{command.flatten}".echo_to file
    @run_commands.align ">> #{file}"
    @run_commands.push "chmod 755 #{file}"
    @run_commands.push blank
  end

  # void (string)
  def deb(deb)
    @install_commands.push "Installing deb package".comment
    @install_commands.push "wget http://#{@ip_address}:8888/#{deb}"
    @install_commands.push "(dpkg -i #{deb} || true)"
    @install_commands.push blank
    @post_install_commands.push "rm -f #{deb}"
    
    @packages.add "wget"
    @deb_flag = true
  end

  # void (string)
  def dependencies(package)
    @depends.add package
  end

  # void (string, string)
  def download(filename, source = nil)
    throw "Not Implemented"
  end

  # void (string)
  def email(email)
    @email = email
  end

  # void (string, string)
  def embed(source, destination = nil)
    destination = destination ? destination : source
    @run_commands.push "Embedding #{source}".comment
    @run_commands.push "echo \\"
    
    s = File.open("#{source}", "rb").read
    e = s.gzip.base64
    e.split("\n").each do |line|
      @run_commands.push "#{line} \\"
    end
    
    @run_commands.push "| tr -d ' ' | base64 -d | gunzip > #{destination}"
    @run_commands.push "chown #{@user}:#{@user} #{destination}"
    @run_commands.push "chmod 755 #{destination}"
    @run_commands.push blank
  end

  # void (string, string)
  def env(key, value)
    @envs.add [key, value]
    @environment_variables[key] = value
  end

  # void (int)
  def expose(port)
    @ports.add port
  end

  # void (string, string)
  def git(path, url)
    throw "Not Implemented"
  end

  # void (bool)
  def gui(enabled)
    throw "Not Implemented"
  end

  # void (string)
  def install(package)
    @packages.add package
  end

  # void (string, string)
  def key(name, key = nil)

    if key.nil?
      key = name
      name = "key"
    end

    @pre_install_commands.push "Adding #{name} to keychain".comment
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
    @pre_install_commands.push blank
  end

  # void (string)
  def name(name)
    @name = name
  end

  # void (string, string)
  def ppa(name, ppa = nil)

    if ppa.nil?
      ppa = name
      name = "external"
    end

    @pre_install_commands.push "Adding #{name} PPA".comment
    @pre_install_commands.push "add-apt-repository -y #{ppa}"
    @pre_install_commands.push blank
    
    @requirements.add "software-properties-common"
    @requirements.add "python-software-properties"
  end

  # void (string, string, string)
  def repository(name, deb = nil)

    if deb.nil?
      deb = name
      name = "external"
    end

    @pre_install_commands.push "Adding #{name} repository".comment
    @pre_install_commands.push deb.echo_to "/etc/apt/sources.list.d/#{name.downcase}.list"
    @pre_install_commands.push blank
  end

  # void (string)
  def run(text)
    text.split("\n").each do |line|
      line.strip!
      if line.start_with? "#"
        @run_commands.push line[1..-1].strip.comment
      elsif line.match /^\s*$/
        @run_commands.push blank
      else
        @run_commands.push line
      end
    end
    @run_commands.push blank 
  end

  # void (string)
  def startup(text)
    @run_commands.push "Defining startup script".comment
    @run_commands.push "echo '#!/bin/sh -e' > /etc/rc.local"
    @run_commands += text.write_to "/etc/rc.local"
    @run_commands.push blank
  end

  # void (string)
  def user(user)
    @user = user
    @begin_commands.push "Creating user / Adjusting user permissions".comment
    @begin_commands.push "(groupadd -g #{@id} #{user} || true)"
    @begin_commands.push "((useradd -u #{@id} -g #{@id} -p #{user} -m #{user}) || \\" 
    @begin_commands.push " (usermod -u #{@id} #{user} && groupmod -g #{@id} #{user}))"
    @begin_commands.push "mkdir -p /home/#{user}"
    @begin_commands.push "chown -R #{user}:#{user} /home/#{user} /opt"
    @begin_commands.push blank
  end

  # void (string)
  def volume(volume)
    @end_commands.push "Fixing permission errors for volume".comment
    @end_commands.push "mkdir -p #{volume}"
    @end_commands.push "chown -R #{@user}:#{@user} #{volume}"
    @end_commands.push "chmod -R 700 #{volume}"
    @end_commands.push blank
    
    @volumes.add volume
  end

  # void (string)
  def workdir(path)
    @workdir = path
  end

  ##############################################################################
  private
    
  # string ()
  def blank
    " \\"
  end

  def backslash
    " \\"
  end
    
  # [string] ([string])
  def build_install_command(packages)
    lines = []
    unless packages.empty?
      lines.push "Installing packages".comment
      lines.push "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \\"
      packages.sort.each{|p| lines.push(p + backslash)}
      lines.push blank
    end
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
      lines.push "Updating Package List".comment
      lines.push "DEBIAN_FRONTEND=noninteractive apt-get update"
      lines.push blank

      # Install requirements
      lines += build_install_command @requirements
    end
    
    # Run pre-install commands
    lines += @pre_install_commands
        
    # If packages are being installed 
    if @deb_flag || !@packages.empty? || !@depends.empty?

       # Update
       lines.push "Updating Package List".comment
       lines.push "DEBIAN_FRONTEND=noninteractive apt-get update"
       lines.push blank
       
       # Install packages
       lines += build_install_command (@packages + @depends)
       
       # Run install commands
       lines += @install_commands
       
       # If manual deb packages were specified
       if @deb_flag
         # Resolve their dependencies
         lines.push "Installing deb package dependencies".comment
         lines.push "DEBIAN_FRONTEND=noninteractive apt-get install -y -f --no-install-recommends"
         lines.push blank
       end
       
       # Run post-install commands
       if !@post_install_commands.empty?
         lines.push "Removing temporary files".comment
         lines += @post_install_commands
         lines.push blank
       end
       
       # Clean up
       lines.push "Cleaning up after installation".comment
       lines.push "DEBIAN_FRONTEND=noninteractive apt-get clean"
       lines.push "rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*"
       lines.push blank

    end

    # Run commands
    lines += @run_commands
        
    # Remove dependencies
    unless @depends.empty?
      lines.push "Removing build dependencies".comment
      lines.push "DEBIAN_FRONTEND=noninteractive apt-get purge -y \\"
      @depends.sort.each{|p| lines.push(p + backslash)}
      lines.push blank
    end

    # End commands
    lines += @end_commands

    # If there are lines to process
    if !lines.empty?    

      # Indent lines
      lines = lines.indent(5)

      # Unindent comments
      lines.select{|l| l.include? " `#"}.collect{|l| l.sub!(" `#", "`#")}

      # Add continuations
      lines.reject{|l| l.end_with? "\\"}.append(" && \\")

      # First line should start with "RUN"
      lines[0][0..2] = "RUN"
      
      # Last line should not end with continuation
      lines[-1].gsub! " && \\", ""
      lines[-1].gsub! " \\", ""
      
      # Last line might be blank now, do it again
      while lines[-1].match /^\s*$/
        lines.delete_at -1
        
        # Last line should not end with continuation
        lines[-1].gsub! " && \\", ""
        lines[-1].gsub! " \\", ""
      end

      # Align continuations
      lines.align(" && \\").align(/\\$/)
    end

    # Make a string
    lines.join "\n"
    
  end
end

class Build

  def initialize
    @name = File.basename(Dir.pwd)
    @server = false
  end

  # void (string)
  def name(name)
    @name = name
  end

  # void (string)
  def deb(deb)
    @server = true
  end

  def to_s
    s = []

    s.push "#!/bin/bash"
    s.push ""

    s.push "# Stopping any existing container"
    s.push "docker stop #{@name} >/dev/null 2>&1 || true"
    s.push ""

    s.push "# Removing any existing container"
    s.push "docker rm #{@name} >/dev/null 2>&1 || true"
    s.push ""
    
    if @server
      s.push "# Starting file server"
      s.push "python -m SimpleHTTPServer 8888 & export PYTHON_PID=$!"
      s.push ""
    end

    s.push "# Building image"
    s.push "docker build -t #{@name} ."
    s.push ""

    if @server
      s.push "# Stopping file server"
      s.push "killall -9 $PYTHON_PID"
      s.push ""
    end

    s.push "# Saving image"
    s.push "echo Saving image..."
    s.push "rm -f #{@name}_*.tar.bz2"
    s.push "docker save #{@name} | bzip2 -9 > #{@name}_`date +%Y%m%d%H%M%S`.tar.bz2"
    s.push ""

    s.join "\n"
  end

end

class Run

  def initialize
    @name    = File.basename(Dir.pwd)
    @network = "bridge"
    @envs    = Set.new
    @ports   = Set.new    
    @volumes = Set.new

    @user        = "root"
    @workdir     = ""
    @app         = ""
    @interactive = false
    @gui         = false
    @persistent  = false
    @priviledged = false
    @seamless    = false
  end

  # string (void)
  def name?
    return @app
  end

  # void (string)
  def app(command)
    @app = command
  end
  
  # void (string, string)
  def env(key, value)
    @envs.add [key, value]
  end

  # void (int)
  def expose(port)
    @ports.add port
  end

  # void (bool)
  def gui(enabled)
    @gui = enabled
  end

  # void (bool)
  def interactive(enabled)
    @interactive = enabled
  end 

  # void (string)
  def name(name)
    @name = name
  end

  # void (string)
  def network(network)
    @network = network
  end

  # void (bool)
  def persistent(enabled)
    @persistent = enabled
  end

  # void (bool)
  def priviledged(enabled)
    @priviledged = enabled
  end

  # void (bool)
  def seamless(enabled)
    puts "Seamless mode active: #{@app}"
    @seamless = enabled
  end

  # void (string)
  def user(name)
    @user = name
  end

  # void (string)
  def volume(volume)
    @volumes.add volume
  end

  # void (string)
  def workdir(path)
    @workdir = path
  end

  # string (void)
  def to_s
    s = []

    s.push "#!/bin/bash"
    s.push ""

    unless @envs.empty?
      s.push "# Setting environment variables"
      s += @envs.collect{|p| "#{p[0]}=#{p[1]}"}
      s.push ""
    end

    if @network != "bridge"
      s.push "# Creating the network"
      s.push "docker network create #{@network} >/dev/null 2>&1 || true"
      s.push ""
    end

    volumes = ""
    unless @volumes.empty?
      s.push "# Determining where to host the volumes"
      s.push "HOST=`readlink -f .`"
      s.push "if [[ $EUID -eq 0 ]]; then"
      s.push "   HOST=/opt"
      s.push "fi"
      s.push ""

      s.push "# Creating directories for hosting volumes"
      volumes = "-v " + @volumes.collect{|v| "${HOST}/#{@name}#{v}:#{v}"}.join(" -v ")
      s += @volumes.collect{|v| "mkdir -p ${HOST}/#{@name}#{v}"}
      s += @volumes.collect{|v| "chown -R 1000:docker ${HOST}/#{@name}#{v}"}
      s += @volumes.collect{|v| "chmod -R 775 ${HOST}/#{@name}#{v}"}
      s.push ""
    end

    ports = ""
    unless @ports.empty?
      ports = "-p " + @ports.collect{|p| "#{p}:#{p}"}.join(" -p ")
    end

    # If the app is interactive
    if !@app.empty? && @interactive
      app = @app
      pipe = ""
      tty = "-t"
    else
      # Pipe app into bash
      app    = @app.empty? ? ""   : "/bin/bash"
      pipe   = @app.empty? ? ""   : "echo \"#{@app} $@\" | "
      tty    = @app.empty? ? "-t" : ""
    end

    # If the app should be run as a specific user
    user = ""
    if !@app.empty? && @user != "root"
      user = "setuser #{@user}"
    end    

    # If the app should be seamless with the host
    seamless = ""
    if @seamless
      seamless = "-v `pwd`:`pwd` -w `pwd`"
    end

    # Run in daemon mode unless there is an app
    daemon = @app.empty? ? "-d" : ""

    # Remove the container unless there is persistence
    persistent = @persistent ? "" : "--rm"

    # Run with priviledged permissions
    priviledged = @priviledged ? "--priviledged" : ""

    # Build the run command
    command = "#{pipe}docker run #{priviledged} -i #{tty} #{persistent} #{daemon} --name #{@name} --net #{@network} #{ports} #{volumes} #{seamless} #{@name} /sbin/my_init --quiet -- #{user} #{app}".squash

    if @persistent
      s.push "# Determine if a container already exists"
      s.push "if [ `docker ps -a -f name=#{@name} | wc -l` -gt 1 ]; then"
      s.push "   # Start the image"
      s.push "   " + "#{pipe}docker start -i -a #{@name}".squash
      s.push "else"
      s.push "   # Run the image"
      s.push "   #{command}"
      s.push "fi"
      s.push ""
    else
      s.push "# Run the image"
      s.push "#{command}"
      s.push ""
    end

    return s.join "\n"
  end

end

class Stop
  
  def initialize
    @name = File.basename(Dir.pwd)
    @persistent = false
  end

  def name(name)
    @name = name
  end

  def persistent(enabled)
    @persistent = enabled
  end

  def to_s

    lines = []

    lines.push "#!/bin/bash"
    lines.push ""
    lines.push "# Stopping the container"
    lines.push "docker stop #{@name} >/dev/null 2>&1 || true"
    lines.push ""

    if !@persistent
      lines.push "# Removing the container"
      lines.push "docker rm #{@name} >/dev/null 2>&1 || true"
      lines.push ""
    end

    return lines.join "\n"

  end

end

class Init

  def initialize
    @name = File.basename(Dir.pwd)
  end

  def name(name)
    @name = name
  end

  def to_s
    <<-EOF.deindent
      #!/bin/sh
      ### BEGIN INIT INFO
      # Provides:          #{@name}
      # Required-Start:    $docker
      # Required-Stop:     $docker
      # Default-Start:     2 3 4 5
      # Default-Stop:      0 1 6
      # Description:       #{@name}
      ### END INIT INFO

      start()
      {
        /opt/#{@name}/run.sh
      }

      stop()
      {
        /opt/#{@name}/stop.sh
      }

      case "$1" in
        start)
          start
          ;;
        stop)
          stop
          ;;
        retart)
          stop
          start
          ;;
        *)
          echo "Usage: $0 {start|stop|restart}"
      esac
    EOF
  end

end

class Install

  def initialize
    @name = File.basename(Dir.pwd)
    @app = true
  end

  def app(name)
    @app = true
  end

  def name(name)
    @name = name
  end

  def to_s

    lines = []

    lines.push "#!/bin/bash"
    lines.push "NAME=#{@name}"
    lines.push "cd /opt/${NAME}"
    lines.push "IMAGE=`ls /opt/${NAME}/${NAME}_*.tar.bz2`"
    lines.push "bunzip2 -c ${IMAGE} | docker load"

    lines.push "update-rc.d ${NAME} defaults" if !@app
    lines.push "/etc/init.d/${NAME} start"    if !@app
    
    lines.push ""
    
    return lines.join "\n"

  end

end

class Uninstall

  def initialize
    @name = File.basename(Dir.pwd)
    @app = false
  end

  def app(name)
    @app = true
  end

  def name(name)
    @name = name
  end

  def to_s

    lines = []

    lines.push "#!/bin/bash"
    lines.push "NAME=#{@name}"

    lines.push "/etc/init.d/${NAME} stop"      if !@app
    lines.push "update-rc.d -f ${NAME} remove" if !@app

    lines.push "docker rmi ${NAME} || true"

    lines.push ""

    return lines.join "\n"

  end

end

class Package

  def initialize
    @name = File.basename(Dir.pwd)
    @email = "Unknown"
    @app = false
  end

  def app(name)
    @app = true
  end

  def email(email)
    @email = email
  end

  def name(name)
    @name = name
  end

  def to_s

    if @app
      extra = "./root/usr=/"
    else
      extra = "./root/etc=/"
    end

    <<-EOF.deindent
      #!/bin/bash

      NAME=#{@name}
      IMAGE=`ls ${NAME}_*.tar.bz2`
      VERSION=`echo ${IMAGE} | sed "s@${NAME}_\\(.*\\)\\.tar\\.bz2@\\1@"`

      rm -f ${NAME}_*.deb

      fpm -s dir -t deb                                 \\
        --name ${NAME}                                  \\
        --version ${VERSION}                            \\
        --maintainer '#{@email}'                        \\
        --vendor '#{@email}'                            \\
        --license 'GPLv3+'                              \\
        --description ${NAME}                           \\
        --depends 'docker-engine > 1.9.0'               \\
        --after-install ./root/opt/${NAME}/install.sh   \\
        --before-remove ./root/opt/${NAME}/uninstall.sh \\
        ./${IMAGE}=/opt/${NAME}/${IMAGE}                \\
        ./root/opt=/                                    \\
        #{extra}

      dpkg --info ${NAME}_${VERSION}_amd64.deb
      dpkg --contents ${NAME}_${VERSION}_amd64.deb
    EOF
  end

end

class Ignore

  def initialize
    @name    = File.basename(Dir.pwd) 
    @volumes = Set.new
  end

  # void (string)
  def name(name)
    @name = name
  end
  
  # string (void)
  def to_s
    s = []

    s.push ".git"    
    s.push "#{@name}*"
    s.push ".dockerignore"
    s.push "build.sh"
    s.push "package.sh"
    s.push "root/*"

    # TODO Add volumes

    s.push ""

    return s.join "\n"
  end

end

class Manager

  def initialize
    @dockerfile = Dockerfile.new
    @build      = Build.new
    @run        = Run.new
    @stop       = Stop.new
    @init       = Init.new
    @install    = Install.new
    @uninstall  = Uninstall.new
    @package    = Package.new
    @ignore     = Ignore.new

    @apps = []
    @name = File.basename(Dir.pwd)
  end

  # Forward a method call to the top-level classes
  def forward(method, *args)
    self.instance_variables.each do |v| 
      if self.instance_variable_get(v).respond_to? method
        self.instance_variable_get(v).send(method, *args) 
      end
    end
  end

  # Forward a method call to all classes
  def forward_all(method, *args)
    self.instance_variables.each do |v| 
      if self.instance_variable_get(v).respond_to? method
        self.instance_variable_get(v).send(method, *args) 
      elsif self.instance_variable_get(v).class == Array
        self.instance_variable_get(v).each do |a|
          a.send(method, *args) if a.respond_to? method
        end
      end
    end
  end

  # If the manager doesn't understand a method, forward it on
  def method_missing(method, *args, &block)
    forward_all(method, *args)
  end

  # void (string)
  def app(name)
    run = Run.new
    run.app name
    @apps.push run
    forward(:app, name)
  end

  # void (string)
  def name(name)
    @name = name
    forward_all(:name, name)
  end

  # string (void)
  def to_s
    @dockerfile.to_s    
  end

  # void (string, object)
  def write(filename, object)
    dir = File.dirname filename
    FileUtils.mkdir_p dir
    File.open(filename, "w"){|f| f.write(object.to_s)}
    File.chmod(0755, filename)
  end

  # void (void)
  def create_files
    files = 
    {
      "Dockerfile"                     => @dockerfile,
      "build.sh"                       => @build,
      "root/opt/#{@name}/install.sh"   => @install,
      "root/opt/#{@name}/uninstall.sh" => @uninstall,
      "package.sh"                     => @package,
      ".dockerignore"                  => @ignore
    }

    # If apps were specified, make a file for each one
    if !@apps.empty?
      @apps.each do |a|
        files["root/usr/local/bin/#{a.name?}"] = a
      end
    else
      # Otherwise, create the default run and stop scripts
      files["root/opt/#{@name}/run.sh"]  = @run
      files["root/opt/#{@name}/stop.sh"] = @stop
      files["root/etc/init.d/#{@name}"]  = @init
    end

    files.each_pair{|k, v| write(k, v)}
  end

end

class Parser

  def initialize(yaml, recipient)
    @yaml = yaml
    @recipient = recipient
  end

  def parse(name)

    # Work with lowercase names
    name.downcase!
  
    # See if the yaml file contains the command
    if @yaml.has_key? name

      # Grab the node
      node = @yaml[name]

      # Call the recipient depending on the format of the node
      case node
        when TrueClass  then @recipient.send(name, node)
        when FalseClass then @recipient.send(name, node)
        when String     then @recipient.send(name, node)
        when Fixnum     then @recipient.send(name, node)
        when Hash       then @recipient.send(name, node.first[0], node.first[1])
        when Array
          node.each do |item|
            case item
              when String then @recipient.send(name, item)
              when Fixnum then @recipient.send(name, item)
              when Hash   then @recipient.send(name, item.first[0], item.first[1])
              else throw "Unknown format for #{name}"
            end
          end
        else throw "Unknown format for #{name}"
      end
    end
  end
end

class Main

  def initialize(argv)

    # Parse apps first so the manager can create the proper run scripts
    # Parse environment variables next so they can be substituted into strings.
    # The rest are just parsed alphabetically
    @commands = 
    [
     "app",          # Set the application to run
     "env",          # Specify an environment variable

     "copy",         # Copy a file from the host into the image
     "create",       # Create a file
     "cron",         # Specify a command to run every hour
     "daemon",       # Specify a daemon to run
     "deb",          # Manually install a deb package from the host
     "dependencies", # Temporarily install these dependencies during the build stage
     "download",     # Download a file into the image
     "email",        # Specify the maintainer email address
     "embed",        # Embed a file from the host into the dockerfile
     "expose",       # Expose ports
     "git",          # Clone a git repository
     "gui",          # Set to true to enable GUI support
     "install",      # Install these packages to the image
     "interactive",  # Allocates a tty when running
     "key",          # Load a GPG key
     "name",         # Specify the name of the image
     "network",      # Specify networks to join
     "persistent",   # Set to true to enable persistence between runs
     "ppa",          # Add an Ubuntu PPA to the image
     "priviledged",  # Run the image with priviledged permissions
     "repository",   # Add repositories to the image
     "run",          # Add a run script to the image
     "seamless",     # Mount the current directory and set as the working directory
     "startup",      # Define a startup script
     "user",         # Specify the user to create and use
     "volume",       # Specify an external volume
     "workdir"       # Specify the working directory 
    ]

  end

  def run
    yaml = YAML::load_file("Dockerfile.yml").downcase
    manager = Manager.new
    parser = Parser.new(yaml, manager)
    @commands.each{|command| parser.parse(command)}
    manager.create_files
    puts manager.to_s
  end

end

if __FILE__ == $0
  main = Main.new(ARGV)
  main.run
end
