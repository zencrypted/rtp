defmodule Rtp.MixProject do
  use Mix.Project

  def project do
    [
      app: :rtp,
      description: "ERP/1: GST RTP RTC ICE SDP H.264 AVC H.265 HEVC MP4 MPEG-2 HLS",
      version: "0.7.21",
      package: package(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia, :crypto, :ssl, :inets ],
      mod: {:rtp_app, []}
    ]
  end

  def package do
    [
      files: ~w(include config lib src priv mix.exs rebar.config README.md GST.md rtp.pdf),
      licenses: ["ISC"],
      maintainers: ["Namdak Tonpa"],
      name: :rtp,
      links: %{"GitHub" => "https://github.com/zencrypted/rtp"}
    ]
  end

  def deps do
    [
      {:bandit, "1.12.0"},
      {:websock_adapter, "0.5.9"},
      {:n2o, "10.12.4"},
      {:nitro, "11.4.16"},
      {:kvs, "10.8.3"},
      {:jsone, "1.7.0"},
      {:syn, "3.4.2"},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      compile: [&compile_gst/1, "compile"]
    ]
  end

  defp compile_gst(_) do
    File.mkdir_p!("priv")
    cmd = "cc -O3 c_src/gst.c -o priv/gst $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-webrtc-1.0 gstreamer-sdp-1.0 json-glib-1.0)"
    case System.shell(cmd) do
      {_, 0} -> :ok
      {output, status} ->
        IO.puts(output)
        raise "Compilation of gst.c failed with status #{status}"
    end
  end

end
