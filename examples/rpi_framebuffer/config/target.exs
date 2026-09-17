import Config

# The panel as a surface. This entry is what makes the application start
# `RpiFramebuffer.Surface` (the host has none and runs the dashboard in a
# terminal instead). Nothing here describes the panel: its size and depth are
# read from sysfs at boot. Optional keys:
#
#   * `scale:` - integer font scale; the default is derived from the panel size
#   * `framebuffer:` - default "fb0"
#   * `console:` - the framebuffer console to unbind, default "vtcon1"
#   * `keyboard:` - false to skip looking for a USB keyboard
config :rpi_framebuffer, RpiFramebuffer.Surface, []

# Use Ringlogger as the logger backend and remove :console.
config :logger, backends: [RingLogger]

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

config :nerves_runtime, startup_guard_enabled: true

# The panel belongs to the dashboard, so the Erlang console moves from tty1 to
# the GPIO serial port (`enable_uart=1` is already in the system's config.txt).
# IEx stays reachable over SSH and serial.
config :nerves, :erlinit,
  update_clock: true,
  ctty: "ttyS0"

# SSH access for IEx and firmware updates, with the public keys of the build host.
keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    """)

config :nerves_ssh, authorized_keys: Enum.map(keys, &File.read!/1)

# usb0 is the USB-C gadget link: one cable to the laptop carries power and a
# point-to-point network, and mdns_lite answers as nerves.local on it.
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

config :mdns_lite,
  hosts: [:hostname, "nerves"],
  ttl: 120,
  services: [
    %{protocol: "ssh", transport: "tcp", port: 22},
    %{protocol: "sftp-ssh", transport: "tcp", port: 22},
    %{protocol: "epmd", transport: "tcp", port: 4369}
  ]
