defmodule ErpsTest.CompileTimeTest do
  #
  #  tests on compile time checks
  #
  use ExUnit.Case, async: true

  describe "if the remote procedure identifier is too long" do
    test "the server fails to compile" do
      assert_raise CompileError, fn ->
        __ENV__.file
        |> Path.dirname
        |> Path.join("assets/server_identifier_too_long.exs")
        |> Code.compile_file
      end
    end

    test "the client fails to compile" do
      assert_raise CompileError, fn ->
        __ENV__.file
        |> Path.dirname
        |> Path.join("assets/client_identifier_too_long.exs")
        |> Code.compile_file
      end
    end
  end

end
