# Dockerfile Generator

This is a script to generate consistent, easy to read Dockerfiles from a simple yaml description.  
The resulting images are small with minimal layers. This tool adds more functionality to normal Dockerfile specifications while remaining simple and concise.

Generated Dockerfiles are all based on [Phusion's Base Image](https://github.com/phusion/baseimage-docker) and utilize many of the features their base image provides. In addition, apt-cacher-ng is automatically used when downloading packages, so rebuilding images is more bandwidth efficient.

To generate a Dockerfile, simply run the following command from any directory containing `Dockerfile.yml`:

    dockerfile.rb

Optionally you can put the name of a target .yml file on the command line:

    dockerfile.rb Dockerfile.someOtherFile.yml
    
The generated Dockerfile will be output to stdout. To save it as a Dockerfile:

    dockerfile.rb > Dockerfile
    
---   

# Dockerfile.yml

Below is a description of all the supported tags in Dockerfile.yml.  
Each tag is optional.

## Maintainer

    # Format
    Maintainer: name
    
    # Example
    Maintainer: Joe Ruether

Sets the image maintainer at the top of the file. Defaults to me if not specified!

## User

    # Format
    User: username
    
    # Example
    User: joe  
    
Creates a user, sets permissions to UID 1000 (which typically matches the host in a single-user case), and runs daemons as that user. Defaults to root if not specified.

## Env

    # Format
    Env:
     - key: value
    
    # Example
    Env:
     - DISPLAY: ":100"

Sets an environment variable global to the container.

## Expose

    # Format
    Expose:
     - port_number
    
    # Example:
    Expose:
     - 9999

Exposes a port to linked containers, and optionally the host (depending on run flags)

## Volumes

    # Format
    Volumes:
     - /path/
    
    # Example
    Volumes:
     - /mnt

The specified folder is made a volume that can be exposed to the host. The volume is specified at the *end* of the Dockerfile such that the contents of the specified directory are copied to the volume.

## Add

    # Format
    Add:
     - something.tar                                   # Unpacks tar file to /
     - Foo.txt : /home/user                            # Adds Foo.txt to /home/user
     - http://www.foo.com/Foo.txt : /home/user/bar.txt # Downloads Foo.txt and stores it as Bar.txt

Adds a file to the image. Default location is `/`, files or directories can be specified as destinations. Source can be local or remote, and tar files are automatically unpacked to the destination. Useful for adding source code.

Files are added to image *before* the `RUN` section.

## Configure

    # Format
    Configure:
     - something.tar                                   # Unpacks tar file to /
     - Foo.txt : /home/user                            # Adds Foo.txt to /home/user
     - http://www.foo.com/Foo.txt : /home/user/bar.txt # Downloads Foo.txt and stores it as Bar.txt

Exactly the same as `Add`, except that files are added *after* the run section (overwriting existing files). Useful for adding configuration files.

## Embed

    # Format
    Embed:
     - something.tar                                   # Unpacks tar file to /
     - Foo.txt : /home/user                            # Adds Foo.txt to /home/user
     - http://www.foo.com/Foo.txt : /home/user/bar.txt # Downloads Foo.txt and stores it as Bar.txt

Same as `Add` and `Configure`, however the file is encoded in base64 and embedded inside the Dockerfile. This is useful for small scripts or configuration files when you want to have everything needed in one Dockerfile.

## Repositories

    # Format
    Repositories:
     - Name: name_of_repository
       Url: url_of_repository OR url_of_ppa
       Key: url_of_key OR gpg_fingerprint   # Optional
       
    # Example
    Repositories:
     - Name: xpra
       Url : deb http://winswitch.org/ trusty main
       Key : http://winswitch.org/gpg.asc
       
     - Name: tor
       Url: deb http://deb.torproject.org/torproject.org trusty main
       Key: A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89

Add a repository. Url is the same format as found in `sources.list`, or a PPA can be specified (`ppa:webupd8team/tor-browser`). Key is optional and can be completely omitted (including "Key:". If specified, key should be a either a gpg key file, or a fingerprint. Local files can be specified if they are inside the same folder as the Dockerfile.

## Install

    # Format
    Install:
     - some_package
     - some_deb_file.deb
    
    # Example
    Install:
     - xpra
     - bitcoinxt_0.11B-1_amd64.deb

List any packages that should be installed. Alternatively, `.deb` packages can be listed as long as they are found in the same folder as the Dockerfile.

## Run

    # Format:
    Run: command(s)
    
    # Example 1
    Run: echo "Hello World"
    
    # Example 2
    Run: |
     # Multiple commands (and comments) supported
     echo "Hello"
     echo "World"

Generates a single `RUN` command from the command text. Treat it as if it were a script; comments are supported, etc. Note the pipe character and indentation when using multiple lines.

## Startup

    # Format:
    Startup: command(s)
    
    # Example 1
    Startup: echo "Hello World"
    
    # Example 2
    Startup: |
     # Multiple commands (and comments) supported
     echo "Hello"
     echo "World"

Adds the commands to the `/etc/rc.local` file where they will run on startup. Treat the command text as if it were a bash script. Note the pipe character and indentation when using multiple lines.

## Daemon

    # Format
    Daemon:
    
     - Name: name_of_daemon
       Command: command_to_run
       
     # Example
     - Name: xpra
       Command: xpra start $DISPLAY --bind-tcp=0.0.0.0:9999 --daemon=no
       
Runs any number of daemons automatically, restarting them if they exit. For this to work, the command must NOT immediately exit (ie: it must block).

## Cron

    # Format
    Cron:
     - Name: name_of_cron
       Command: command_to_run
       
    # Example
    Cron:
     - Name: Date
       Command: date
       
Runs any number of cron jobs hourly, logging output to the system logger.

# Examples:

See Dockerfile.yml and it's generated Dockerfile in this repository for a description of an image that sets up GUI support, which could be used as a base for other images.

# Currently not fully implemented:

 - Maintainer keyword
 - Ability to download local repository keys
 - Embedded tar files should be unpacked to remain consistent with add / configure
 - Embedding of remote files
 - Ability to disable apt-cacher-ng support

# Coming Soon

## Case insensitive support
Currently, the yaml file requires capitalized keys. I chose this because it is the most human readable (in my opinion). However, using all uppercase keys is more consistent with the standard dockerfile format, and having all lowercase keys is more "machine-like". The latter is especially if someone autogenerates Dockerfile.yml, or uses the json format (remember that the yaml parser can read json format).

## Gui
Will automatically add all the commands needed to connect a GUI

## SSH
Will automatically add specified ssh keys and set up the ssh daemon
    
## From
Ability to change the "from" image, as long as the "from" image is derived from `phusion/baseimage-docker`
