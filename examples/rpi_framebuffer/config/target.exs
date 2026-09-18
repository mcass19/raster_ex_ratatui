import Config

# The panel as a surface. This entry is what makes the application start
# `RpiFramebuffer.Surface` (the host has none and runs the dashboard in a
# terminal instead). Nothing here describes the panel: its size and depth are
# read from sysfs at boot. The keys are RasterExRatatui.Framebuffer.Surface's:
#
#   * `rotate:` - 0, 90, 180, or 270, clockwise: how the stand holds the panel.
#     The Touch Display 2 is portrait; 90 or 270 makes it landscape, whichever
#     puts the text the right way up
#   * `scale:` - integer font scale, default :auto (about 100 columns on the long side)
#   * `framebuffer:` - default "fb0"; `framebuffer_timeout:` - default 30_000 ms
#   * `console:` - the framebuffer console to unbind, default "vtcon1", or false
#   * `keyboard:` - true (default), a /dev/input/eventN path, or false
#   * `touch:` - the touch panel, the same way (default false)
#   * `app_opts:` - for the dashboard: `spin_ms:` between two turns of the object
config :rpi_framebuffer, RpiFramebuffer.Surface, rotate: 90

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
