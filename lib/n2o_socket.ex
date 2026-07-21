defmodule Rtp.N2OSocket do
  require N2O

  def init(args) do
    mod = Keyword.get(args, :module, :login)
    {:ok, N2O.cx(module: mod)}
  end

  def handle_in({"N2O," <> _ = msg, _}, state),
    do: response(:n2o_proto.stream({:text, msg}, [], state))

  def handle_in({"PING", _}, state),
    do: {:reply, :ok, {:text, "PONG"}, state}

  def handle_in({msg, _}, state) when is_binary(msg),
    do: response(:n2o_proto.stream({:binary, msg}, [], state))

  def handle_info(msg, state),
    do: response(:n2o_proto.info(msg, [], state))

  def terminate(_reason, _state), do: :ok

  defp response({:reply, {:binary, r}, _, s}), do: {:reply, :ok, {:binary, r}, s}
  defp response({:reply, {:text,   r}, _, s}), do: {:reply, :ok, {:text, r}, s}
  defp response({:reply, {:bert,   r}, _, s}), do: {:reply, :ok, {:binary, :n2o_bert.encode(r)}, s}
  defp response({:ok, s}),                     do: {:ok, s}
  defp response(other) do
    IO.inspect(other, label: "Rtp.N2OSocket unhandled")
    {:ok, elem(other, tuple_size(other) - 1)}
  end
end
