import Config

config :n2o,
  routes: :rtp_routes,
  mq: :rtp_syn

config :rtp,
  hls_format: :ts

config :logger, :default_handler,
  config: [file: ~c"log/rtp.log"]
