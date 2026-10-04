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

## Optional automatic startup

Answer `y` to start the dedicated `easy-tor-bridge` Colima profile at login.
A per-user LaunchAgent preserves Colima's background processes after the
startup command exits and retries failed starts. It does not supervise the
VM continuously after a successful start. Colima remains running after logout
while the Mac is awake; nothing runs before the first login after a reboot.

Answer `n` on a later run to remove this project's automatic-startup setting.
That does not stop a currently running bridge.
