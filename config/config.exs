import Config

config :n2o,
  port: 8082,
  protocols: [:nitro_n2o, :n2o_heart],
  routes: :rtp_routes,
  mq: :rtp_syn,
  session: :n2o_session,
  origin: <<"*">>,
  pickler: :n2o_secret,
  event: :pickle

config :rtp,
  hls_format: :ts

config :logger, :default_handler,
  config: [file: ~c"log/rtp.log"]
