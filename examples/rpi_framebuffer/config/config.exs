import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information
config :nerves, source_date_epoch: "1757721600"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
