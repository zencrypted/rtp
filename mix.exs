defmodule Rtp.MixProject do
  use Mix.Project

  def project do
    [
      app: :rtp,
      version: "0.1.0",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :mnesia, :crypto, :ssl, :inets],
      mod: {:rtp_app, []}
    ]
  end

  defp deps do
    [
      {:bandit, "1.12.0"},
      {:websock_adapter, "0.5.9"},
      {:n2o, "10.12.4"},
      {:nitro, "11.4.16"},
      {:kvs, "10.8.3"},
      {:jsone, "1.7.0"},
      {:syn, git: "https://github.com/ostinelli/syn.git", tag: "3.4.2"},
      {:ex_doc, ">= 0.0.0", only: [:dev, :test]}
    ]
  end
end
