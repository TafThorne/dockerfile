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

# Patches
class String

   # string (void)
   def flatten
      self.strip.gsub(/\s*\\\s*/, " ")
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

end

class Array

  # [string] (int)
  def indent(count)
    self.collect do |l|
      l.insert(0, " " * count)
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

    @from    = "phusion/baseimage:0.9.18"
    @email   = "Unknown"
    @name    = File.basename(Dir.pwd)
    @network = "bridge"
    @user    = "root"
    @id      = `id -u`.chomp # 1000
    
    @requirements = Set.new
    @packages     = Set.new
    @depends      = Set.new
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
    @docker_ip=`/sbin/ifconfig docker0 | grep "inet addr"`.chomp.strip.split(/[ :]/)[2]
  end
  
  ##############################################################################
  public
  
  # string ()
  def to_s
    lines = []

    lines.push "# #{@name} #{Time.now}"
    lines.push "FROM #{@from}"
    lines.push "MAINTAINER #{@email}"
    lines.push ""
    @envs.each{|p| lines.push "ENV #{p[0]} #{p[1]}"}
    lines.push "" if !@envs.empty?
    @ports.each{|p| lines.push "EXPOSE #{p}"}
    lines.push "" if !@ports.empty?
    lines += @adds
    lines.push "" if !@adds.empty?
    lines.push "COPY Dockerfile /Dockerfile"
    lines.push "COPY Dockerfile.yml /Dockerfile.yml"
    lines.push ""
    lines.push build_run_command
    lines.push ""
    lines += @configures
    lines.push "" if !@configures.empty?
    @volumes.each{|v| lines.push "VOLUME #{v}"}
    lines.push "" if !@volumes.empty?
    lines.push "ENTRYPOINT [\"/sbin/my_init\"]"
    lines.push "CMD [\"\"]"
    lines.push ""

    lines.join "\n"
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
  def name(name)
    @name = name
  end

  # void (string)
  def email(email)
    @email = email
  end

  # void (string)
  def startup(text)
    @run_commands.push "Defining startup script".comment
    @run_commands.push "echo '#!/bin/sh -e' > /etc/rc.local"
    @run_commands += text.write_to "/etc/rc.local"
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
  
  # void (string, string)
  def env(key, value)
    @envs.add [key, value]
  end
  
  # void (string, string)
  def copy(source, destination = "/")
    @adds.push "COPY #{source} #{destination}"
  end
    
  # void (string, string)
  def embed(source, destination = "/")
    @run_commands.push "Embedding #{source}".comment
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
    @run_commands.push "Creating #{file}".comment
    @run_commands.push "mkdir -p #{File.dirname(file)}"
    @run_commands += contents.write_to file 
    @run_commands.push "chown #{@user}:#{@user} #{file}"
    @run_commands.push blank
  end
    
  # void (int)
  def expose(port)
    @ports.add port
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
  
  # void (string)
  def install(package)
    @packages.add package
  end
  
  # void (string)
  def depend(package)
    @depends.add package
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
  def volume(volume)
    @end_commands.push "Fixing permission errors for volume".comment
    @end_commands.push "mkdir -p #{volume}"
    @end_commands.push "chown -R #{@user}:#{@user} #{volume}"
    @end_commands.push "chmod -R 700 #{volume}"
    @end_commands.push blank
    
    @volumes.add volume
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
    
    # Indent lines
    lines.indent(5)

    # Unindent comments
    lines.select{|l| l.include? " `#"}.collect{|l| l.sub!(" `#", "`#")}

    # Add continuations
    lines.reject{|l| l.end_with? "\\"}.append(" && \\")

    # Align continuations
    lines.align(" && \\").align(/\\$/)

    # First line should start with "RUN"
    lines[0][0..2] = "RUN"
    
    # Last line should not end with continuation
    lines[-1].gsub! " && \\", ""
    lines[-1].gsub! " \\", ""
    
    # Last line might be blank now, do it again
    if lines[-1].match /^\s*$/
      lines.delete_at -1
      
      # Last line should not end with continuation
      lines[-1].gsub! " && \\", ""
      lines[-1].gsub! " \\", ""
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
  end

  # void (string)
  def name(name)
    @name = name
  end
  
  # void (string, string)
  def env(key, value)
    @envs.add [key, value]
  end

  # void (int)
  def expose(port)
    @ports.add port
  end

  # void (string)
  def volume(volume)
    @volumes.add volume
  end

  # void (string)
  def network(network)
    @network = network
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

    s.push "# Stopping any existing container"
    s.push "docker stop #{@name} >/dev/null 2>&1 || true"
    s.push ""

    s.push "# Removing any existing container"
    s.push "docker rm #{@name} >/dev/null 2>&1 || true"
    s.push ""

    if @network != "bridge"
      s.push "# Creating the network"
      s.push "docker network create #{@network} >/dev/null 2>&1 || true"
      s.push ""
    end

    s.push "# Determining where to host the volumes"
    s.push "HOST=`readlink -f .`"
    s.push "if [[ $EUID -eq 0 ]]; then"
    s.push "   HOST=/opt"
    s.push "fi"
    s.push ""

    volumes = ""
    unless @volumes.empty?
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

    s.push "# Running the image"
    s.push "docker run -it -d --name #{@name} --net #{@network} #{ports} #{volumes} #{@name} /bin/bash"
    s.push ""

    return s.join "\n"
  end

end

class Stop
  
  def initialize
    @name = File.basename(Dir.pwd)
  end

  def name(name)
    @name = name
  end

  def to_s

    <<-EOF.gsub(/^\s{6}/, "")
      #!/bin/bash

      # Stopping the container
      docker stop #{@name} >/dev/null 2>&1 || true

      # Removing the container
      docker rm #{@name} >/dev/null 2>&1 || true
    EOF

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
    <<-EOF.gsub(/^\s{6}/, "")
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
  end

  def name(name)
    @name = name
  end

  def to_s
    <<-EOF.gsub(/^\s{6}/, "")
      #!/bin/bash
      NAME=#{@name}
      cd /opt/${NAME}
      IMAGE=`ls ${NAME}_*.tgz`
      VERSION=`echo ${IMAGE} | sed "s@${NAME}_\\(.*\\)\\.tar\\.bz2@\\1@"`
      bunzip2 -c /opt/${NAME}/${IMAGE} | docker load
      update-rc.d ${NAME} defaults
      /etc/init.d/${NAME} start
    EOF
  end

end

class Uninstall

  def initialize
    @name = File.basename(Dir.pwd)
  end

  def name(name)
    @name = name
  end

  def to_s
    <<-EOF.gsub(/^\s{6}/, "")
      #!/bin/bash
      NAME=#{@name}
      /etc/init.d/${NAME} stop
      update-rc.d -f ${NAME} remove
      docker rmi ${NAME}
    EOF
  end

end

class Package

  def initialize
    @name = File.basename(Dir.pwd)
    @email = "Unknown"
  end

  def name(name)
    @name = name
  end

  def email(email)
    @email = email
  end

  def to_s
    <<-EOF.gsub(/^\s{6}/, "")
      #!/bin/bash

      NAME=#{@name}
      IMAGE=`ls ${NAME}_*.tar.bz2`
      VERSION=`echo ${IMAGE} | sed "s@${NAME}_\\(.*\\)\\.tar\\.bz2@\\1@"`

      rm -f ${NAME}_*.deb

      fpm -s dir -t deb                   \\
        --name ${NAME}                    \\
        --version ${VERSION}              \\
        --maintainer '#{@email}'          \\
        --vendor '#{@email}'              \\
        --license 'GPLv3+'                \\
        --description ${NAME}             \\
        --depends 'docker-engine > 1.9.0' \\
        --after-install ./install.sh      \\
        --before-remove ./uninstall.sh    \\
        ./${IMAGE}=/opt/${NAME}/${IMAGE}  \\
        ./run.sh=/opt/${NAME}/run.sh      \\
        ./stop.sh=/opt/${NAME}/stop.sh    \\
        ./init.sh=/etc/init.d/${NAME}

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
    s.push "run.sh"
    s.push "stop.sh"
    s.push "init.sh"
    s.push "install.sh"
    s.push "uninstall.sh"
    s.push "package.sh"
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
  end

  def method_missing(method, *args, &block)
    self.instance_variables.each{|v| self.instance_variable_get(v).send(method, *args, &block) if self.instance_variable_get(v).respond_to? method}
  end

  # string (void)
  def to_s
    @dockerfile.to_s    
  end

  # void (void)
  def write
    File.open("Dockerfile",    "w"){|f| f.write(@dockerfile.to_s)}
    File.open("build.sh",      "w"){|f| f.write(@build.to_s)}
    File.open("run.sh",        "w"){|f| f.write(@run.to_s)}
    File.open("stop.sh",       "w"){|f| f.write(@stop.to_s)}
    File.open("init.sh",       "w"){|f| f.write(@init.to_s)}
    File.open("install.sh",    "w"){|f| f.write(@install.to_s)}
    File.open("uninstall.sh",  "w"){|f| f.write(@uninstall.to_s)}
    File.open("package.sh",    "w"){|f| f.write(@package.to_s)}
    File.open(".dockerignore", "w"){|f| f.write(@ignore.to_s)}

    File.chmod(0755, "build.sh")
    File.chmod(0755, "run.sh")
    File.chmod(0755, "stop.sh")
    File.chmod(0755, "init.sh")
    File.chmod(0755, "install.sh")
    File.chmod(0755, "uninstall.sh")
    File.chmod(0755, "package.sh")
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
        when String then @recipient.send(name, node)
        when Fixnum then @recipient.send(name, node)
        when Hash   then @recipient.send(name, node.first[0], node.first[1])
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

    @commands = 
    [
     "name",
     "email",
     "user",
     "env",     
     "copy",
     "embed",
     "create",
     "download",
     "git",
     "repository",
     "ppa",
     "key",
     "install",
     "depend",
     "deb",
     "run",
     "startup",
     "daemon",
     "cron",
     "expose",
     "volume",
     "network"
    ]

  end

  def run
    yaml = YAML::load_file("Dockerfile.yml").downcase
    manager = Manager.new
    parser = Parser.new(yaml, manager)
    @commands.each{|command| parser.parse(command)}
    manager.write
  end

end

if __FILE__ == $0
  main = Main.new(ARGV)
  main.run
end
