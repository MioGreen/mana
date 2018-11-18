defmodule Exth do
  @moduledoc """
  General helper functions, like for inspection.
  """
  require Logger

  @spec inspect(any(), String.t() | nil) :: any()
  def inspect(variable, prefix \\ nil) do
    args = if prefix, do: [prefix, variable], else: variable

    # credo:disable-for-next-line
    IO.inspect(args, limit: :infinity)

    variable
  end

  @spec trace((() -> String.t())) :: :ok
  def trace(fun) do
    _ = if System.get_env("TRACE"), do: Logger.debug(fun)

    :ok
  end

  @spec maybe_decode_unsigned(integer() | binary()) :: integer()
  def maybe_decode_unsigned(val) when is_integer(val), do: val

  def maybe_decode_unsigned(val) when is_binary(val) do
    :binary.decode_unsigned(val)
  end

  @spec encode_hex(binary()) :: String.t()
  def encode_hex(bin) do
    "0x#{Base.encode16(bin, case: :lower)}"
  end
end
