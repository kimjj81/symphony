defmodule SymphonyElixirWeb.RawBodyReader do
  @moduledoc false

  alias Plug.Conn

  @spec read_body(Conn.t(), keyword()) ::
          {:ok, binary(), Conn.t()} | {:more, binary(), Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, store_raw_body(conn, body)}

      {:more, body, conn} ->
        {:more, body, store_raw_body(conn, body)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_raw_body(conn, body) when is_binary(body) do
    chunks = Map.get(conn.private, :raw_body, [])
    Conn.put_private(conn, :raw_body, [body | chunks])
  end
end
