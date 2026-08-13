# LinuxGSM server auto pause

This repo provides a script to 'pause' dedicated game servers provisioned through LinuxGSM, so that once all clients disconnect and no network traffic is observed, after some time, the server shuts down. If network traffic is detected, and the server is stopped, it is automatically started.

## Introduction

My personal use case was for a Palworld dedicated server, which at the time of writing cannot actually be paused via a game/RCON command. Manually shutting the server down and starting it back up when you want to play is cumbersome, but also problematic if you play with friends that want to play in their own time, when you're unavailable to start the server for them.

Using this script, everyone can go offline without having to worry that bases will get raided, food stocks for pals will not run out, and it conserves CPU/RAM on already limited hardware/VM's.

Of course, there are several downsides too. Stopped servers cannot be queried/discovered (so connections must be made via IP/port or bookmarks), and there is no offline/AFK farming.

I looked around for how others solved it, but could not really find anything relatively simple, so here we are.

## How it works

Pseudocode for the script operation:
- Sniff the network interface for incoming traffic on a specific port/protocol.
  - Is the game server running?
    - If there is incoming traffic, reset timer.
    - If the timer expires, stop the server using LGSM script.
  - Is the game server stopped?
    - If there is incoming traffic, start the server using LGSM script.

## How to use

> Note: `sudo` is required for initial set up/configuration. If you are renting a server, you may not be able to use this script.

### Install/configure dependency `tcpdump`

`tcpdump` is used to determine if there is active inbound network traffic to the game server. It is the basis for how this script functions.

Log in with a user with `sudo` permission and install `tcpdump`.

```bash
sudo apt install tcpdump -y
```

`tcpdump` requires a specific (elevated) permission/capability, normally reserved for users in the `sudo` group. Instead of giving the LinuxGSM user `sudo` (which is strongly discouraged), we configure a new user group that provides the required permission/capability. This way, we avoid giving too much permissions.

```bash
# Add/configure pcap group for tcpdump.
sudo groupadd pcap
sudo chgrp pcap /usr/bin/tcpdump
sudo setcap cap_net_raw=eip /usr/bin/tcpdump
# Optional, add self to the group (if currently logged in as root).
sudo usermod -aG pcap $USER
```

Finally, add the LinuxGSM user account that runs the game server to the group:

```bash
# Replace linux_gsm_user with the user your game server runs under.
sudo usermod -aG pcap linux_gsm_user
```

To confirm everything works, run `tcpdump`. You should not be prompted for `sudo` anymore.

### Install the script

- Log in with the LinuxGSM user
- Confirm/ensure you are in the home folder `cd ~`
- Clone from this repo into the home folder
  ```bash
  curl -sL https://github.com/skwasjer/lgsm-autopause/archive/refs/tags/v2.0.0.tar.gz | tar -zxf - lgsm-autopause-2.0.0/autopause.sh && mv ~/lgsm-autopause-2.0.0/autopause.sh ~/ && rmdir ~/lgsm-autopause-2.0.0 && chmod 775 ~/autopause.sh
  ```

### Test the script

For CLI arguments/usage, run the script without arguments:

```bash
./autopause.sh
```

#### Palworld example

Run the script with at least as argument the LinuxGSM shell script. The script will read the LGSM config and extract the required configuration (port and server executable). There are some optional arguments such as specifying that the protocol is UDP (`--udp`). It is not required, but recommended to limit what that only UDP traffic can trigger a server start.

For example, Palworld uses UDP and the LGSM command is `pwserver`.
In this example, the `-t` argument also specifies how long to wait after the last client disconnects, before the server is shut down.

```bash
./autopause.sh ./pwserver --udp -t 30
```

> Test your configuration, by connecting to the server, leaving it, wait longer than the stop delay interval, and try to reconnect again as well. Observe the console output while doing so to verify everything functions as expected.
Once you are done testing, you can stop the script. You are now ready to configure it as a service (see below)

### Register as a `systemd` service

Once satisfied everything is functioning, register the script as a service so that it will started at boot time.

#### Create the service unit

```bash
sudo nano /etc/systemd/system/lgsm-autopause.service
```
> You may want to give it a more specific name if you host multiple servers on the same box (as each will need their own auto start/stop unit)

Paste in the unit definition below, modifying to your needs. Make sure to use the correct user and path for your LinuxGSM server. Note that the script cannot be run as root.

The example below is specifically for a Palworld server.

```console
[Unit]
Description=Palworld autopause service
After=network.target

[Service]
User=pwserver
WorkingDirectory=/home/pwserver
ExecStart=/home/pwserver/autopause.sh /home/pwserver/pwserver --udp -t 30
Type=simple
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

> Make sure to use absolute paths in the service file.


#### Enable the new service

```bash
sudo systemctl daemon-reload
sudo systemctl enable lgsm-autopause.service
sudo systemctl start lgsm-autopause.service
```

And done!


### Caveats

- For game servers that are slow to start up, the (first) client may experience connection timeouts. There is not much that can be done, other than the user simply retry to connect. If a game server is really slow to start/stop, it is probably not a good idea to use this script.
- If you followed LinuxGSM documentation, you are probably aware of how server updates/monitoring/backups are managed via CRON jobs. I have not fully tested how this script behaves, when one of these CRON jobs is actively executing.

  My advice is to schedule these jobs during timeframes when it is unlikely that anyone would be playing to avoid issues. I will update this section when I have further evidence/tested its behavior under those conditions.

  I'd also advice disabling the `systemd` service when you are manually performing maintenance.

## Supported game servers

Tested support for:
- Palworld

> If you use my script for other game servers supported by LinuxGSM, please let me know via a GitHub issue or send a pull request to update this list, so that future gamers know what servers are confirmed supported!

## Links

- https://linuxgsm.com/
