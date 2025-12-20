defmodule TripleStoreTest do
  use ExUnit.Case, async: true
  doctest TripleStore

  describe "module structure" do
    test "TripleStore module is defined" do
      assert Code.ensure_loaded?(TripleStore)
    end

    test "TripleStore.Application module is defined" do
      assert Code.ensure_loaded?(TripleStore.Application)
    end

    test "TripleStore.Backend module is defined" do
      assert Code.ensure_loaded?(TripleStore.Backend)
    end

    test "TripleStore.Dictionary module is defined" do
      assert Code.ensure_loaded?(TripleStore.Dictionary)
    end

    test "TripleStore.Index module is defined" do
      assert Code.ensure_loaded?(TripleStore.Index)
    end
  end

  describe "supervision tree" do
    test "application starts successfully" do
      # The application should already be started by the test framework
      assert Process.whereis(TripleStore.Supervisor) != nil
    end
  end
end
