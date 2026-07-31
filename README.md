# TrailCam Alert — installer

Photos arrive from trail cameras by FTP, get checked for people, vehicles and
animals, and turn into **one alert per event** — not one per photo — on Telegram
and/or ntfy, with a web interface for reviewing everything afterwards.

Runs on a Raspberry Pi 5, or any machine that can run Docker.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Riaan007/trailcam-install/main/install.sh | sudo bash
```

It checks the machine, installs Docker if it is missing, pulls the images and
starts the stack — then prints a URL and a setup code. Everything after that
happens in the browser: your account, the first camera (which produces the FTP
details to type into it), and where alerts should go.

Re-running is safe. An existing install keeps its passwords and its data.

### What it needs

- 64-bit Linux on arm64 or amd64
- Docker (installed for you if absent)
- Ports **8098** (web, configurable), **21** and **40000-40100** (FTP) free
- 5 GB free to start with, and **not an SD card** — trail cameras write
  constantly and SD cards do not survive it. The installer warns if it sees one.

### Options

```bash
WEB_PORT=9000 TRAILCAM_DATA=/mnt/ssd/trailcam \
  curl -fsSL https://raw.githubusercontent.com/Riaan007/trailcam-install/main/install.sh | sudo -E bash
```

`sudo -E` matters — without it the environment does not survive.

## Afterwards

```bash
cd /opt/trailcam

./trailcam status                # what is running, what has arrived
./trailcam add-camera dam "Dam"  # new camera, FTP account and folder
./trailcam credentials dam       # what to type into the camera
./trailcam selftest              # every check; exits 0 only if all pass
./trailcam update                # pull new images and restart
./trailcam backup                # database dump
```

Photos live at `/srv/trailcam/archive`, outside any container, in
`camera/YYYY/MM/DD/` folders. They are ordinary JPEGs — nothing here traps them.

## Updating

```bash
cd /opt/trailcam && ./trailcam update && ./selftest.sh
```

## Keep it off the internet

This system knows when a property is empty, and the camera map shows exactly
where the blind spots are. Keep it on the LAN; to reach it from outside, put it
behind Tailscale or a VPN rather than forwarding a port.

---

Source is private. Issues and requests: <https://github.com/Riaan007/trailcam-install/issues>
