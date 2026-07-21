defmodule Rtp.N2O do
  require N2O

  def init(args) do {:ok, N2O.cx(module: Keyword.get(args, :module, :login))} end

  def handle_in({"N2O," <> _ = msg, _}, state),       do: response(:n2o_proto.stream({:text, msg}, [], state))
  def handle_in({"PING", _}, state),                  do: {:reply, :ok, {:text, "PONG"}, state}
  def handle_in({msg, _}, state) when is_binary(msg), do: response(:n2o_proto.stream({:binary, msg}, [], state))
  def handle_info(msg, state),                        do: response(:n2o_proto.info(msg, [], state))
  def terminate(_reason, _state),                     do: :ok

  def response({:reply, {:binary, r}, _, s}), do: {:reply, :ok, {:binary, r}, s}
  def response({:reply, {:text,   r}, _, s}), do: {:reply, :ok, {:text, r}, s}
  def response({:reply, {:bert,   r}, _, s}), do: {:reply, :ok, {:binary, :n2o_bert.encode(r)}, s}
  def response({:ok, s}),                     do: {:ok, s}
  def response(other),                        do: {:ok, elem(other, tuple_size(other) - 1)}

end
