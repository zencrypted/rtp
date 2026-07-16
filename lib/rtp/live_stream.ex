defmodule Rtp.LiveStream do
  import Plug.Conn

  def init(options), do: options

  def call(conn, _opts) do
    case conn.path_info do
      ["rooms", room_name, "recording.mp4"] ->
        file_path = "priv/static/rooms/#{room_name}/recording.mp4"
        if File.exists?(file_path) do
          conn = conn
                 |> put_resp_header("content-type", "video/mp4")
                 |> put_resp_header("cache-control", "no-cache")
                 |> send_chunked(200)
          
          stream_growing_file(conn, file_path, 0)
        else
          send_resp(conn, 404, "Not Found")
        end
      ["rooms", room_name, "index.m3u8"] ->
        file_path = "priv/static/rooms/#{room_name}/index.m3u8"
        if File.exists?(file_path) do
          conn
          |> put_resp_header("content-type", "application/vnd.apple.mpegurl")
          |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate, max-age=0")
          |> send_resp(200, File.read!(file_path))
        else
          send_resp(conn, 404, "Not Found")
        end
      _ ->
        conn
    end
  end

  defp stream_growing_file(conn, file_path, offset) do
    case File.open(file_path, [:read, :binary]) do
      {:ok, file} ->
        :file.position(file, {:bof, offset})
        case IO.binread(file, 65536) do
          :eof ->
            File.close(file)
            :timer.sleep(500)
            stream_growing_file(conn, file_path, offset)
          data when is_binary(data) ->
            File.close(file)
            case chunk(conn, data) do
              {:ok, conn} ->
                stream_growing_file(conn, file_path, offset + byte_size(data))
              {:error, :closed} ->
                conn
            end
        end
      {:error, _} ->
        :timer.sleep(500)
        stream_growing_file(conn, file_path, offset)
    end
  end
end
