defmodule Rtp.WS do
  use Plug.Router

  plug :match
  plug :dispatch

  # N2O app WebSocket upgrade
  get "/ws/app/:mod" do
    target_mod = case mod do
      "login.htm" -> :login
      "login"     -> :login
      "index.htm" -> :index
      "index"     -> :index
      _           -> :login
    end
    conn
    |> WebSockAdapter.upgrade(Rtp.N2OSocket, [module: target_mod], timeout: 60_000)
    |> halt()
  end

  # WebRTC signaling WebSocket upgrade
  get "/ws/signaling" do
    conn = Plug.Conn.fetch_query_params(conn)
    user = Map.get(conn.query_params, "user", "Anonymous")
    room = Map.get(conn.query_params, "room", "default")
    role = Map.get(conn.query_params, "role", "participant")
    token = Map.get(conn.query_params, "token", "")
    conn
    |> WebSockAdapter.upgrade(:n2o_signaling, {user, room, role, token}, timeout: 60_000)
    |> halt()
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
