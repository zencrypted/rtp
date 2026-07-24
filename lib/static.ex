defmodule RTP.Static do
  use Plug.Router

  plug RTP.HLS
  plug Plug.Static, at: "/app", from: {:rtp, "priv/static/app"}
  plug Plug.Static, at: "/",    from: {:rtp, "priv/static"}, headers: [{"cache-control", "no-cache"}]
  plug :match
  plug :dispatch

  match _ do
    send_resp(conn, 404, "not found")
  end
end
