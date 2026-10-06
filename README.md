# Easy Tor obfs4 Bridge for macOS

Designed for Mac Minis or any other always-on machine running or emulating MacOS. 

Run from a complete copy of this project, without sudo:

````bash
./install.sh
````

Setup installs missing Homebrew, Colima, Docker CLI, and Compose dependencies,
asks for your contact email, starts the Tor bridge, and checks bootstrap.
Homebrew may request administrator access. Tor and its transport run inside
the maintained Tor container inside Colima.

Your settings are saved in `.env`. The installer explicitly selects this
project's config.

Bridge identity lives in the named Docker volume: deleting that volume deletes the identity.

## Bootstrap and reachability

Bootstrap means Tor connected to its network, but not that inbound connections
can reach your bridge. The check has a five-minute deadline, including Docker
commands. A timeout ends the check without stopping the container.

Once success is observed, a private record is saved under
`~/Library/Application Support/easy-tor-bridge/bootstrap`. It records the
container ID and start time.

Use [Tor's TCP reachability test](https://bridges.torproject.org/scan/) with
your public IP and obfs4 port. Home routers may need TCP forwarding for both
configured ports. Managed networks may block inbound traffic.

## Local network diagnostics

Setup checks for visible port conflicts. After
bootstrap it prints the default IPv4 interface, gateway, and local address;
Docker's published endpoints; and short TCP connection tests against loopback
and that local address for both ports. These connection tests cover IPv4 only. 

The report reads the macOS application firewall's global/block-all settings.
Unknown means the command could not establish the state.

All TCP probes originate on your device. Diagnostics do not create router
mappings, look up your public IP, or send requests to an external checker.

## Optional automatic startup

Answer `y` to start the dedicated `easy-tor-bridge` Colima profile at login.
A per-user LaunchAgent preserves Colima's background processes. Colima 
remains running after logout while the Mac is awake.

Answer `n` on a later run to remove this project's automatic-startup setting.
That does not stop a currently running bridge.
