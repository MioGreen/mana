defmodule ExthTest do
  use ExUnit.Case
  doctest Exth

  test "greets the world" do
    assert Exth.hello() == :world
  end
end
