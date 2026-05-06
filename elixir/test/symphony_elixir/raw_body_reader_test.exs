defmodule SymphonyElixirWeb.RawBodyReaderTest do
  use SymphonyElixir.TestSupport

  import Plug.Test

  alias SymphonyElixirWeb.RawBodyReader

  defmodule ErrorAdapter do
    def read_req_body(:state, _opts), do: {:error, :closed}
  end

  test "stores each raw body chunk as the body is read" do
    conn = conn(:post, "/", "abcdef")

    assert {:more, "abc", conn} = RawBodyReader.read_body(conn, length: 3)
    assert conn.private.raw_body == ["abc"]

    assert {:ok, "def", conn} = RawBodyReader.read_body(conn, length: 3)
    assert conn.private.raw_body == ["def", "abc"]
  end

  test "passes read body errors through without storing raw body" do
    conn = %Plug.Conn{adapter: {ErrorAdapter, :state}}

    assert {:error, :closed} = RawBodyReader.read_body(conn, [])
  end
end
