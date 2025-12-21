defmodule TripleStore.Dictionary.InputValidationTest do
  @moduledoc """
  Tests for input validation (Concern C1).

  Covers:
  - Term size validation
  - Null byte detection in URIs
  - UTF-8 validation
  - Unicode normalization
  """
  use ExUnit.Case, async: true

  alias TripleStore.Dictionary

  describe "validate_term/2" do
    test "accepts valid URI" do
      assert :ok = Dictionary.validate_term("http://example.org/resource", :uri)
    end

    test "accepts valid blank node identifier" do
      assert :ok = Dictionary.validate_term("_:b0", :bnode)
    end

    test "accepts valid literal" do
      assert :ok = Dictionary.validate_term("Hello, World!", :literal)
    end

    test "accepts empty string" do
      assert :ok = Dictionary.validate_term("", :uri)
    end

    test "rejects term exceeding max size" do
      large_term = String.duplicate("a", Dictionary.max_term_size() + 1)
      assert {:error, :term_too_large} = Dictionary.validate_term(large_term, :uri)
    end

    test "accepts term at exactly max size" do
      max_term = String.duplicate("a", Dictionary.max_term_size())
      assert :ok = Dictionary.validate_term(max_term, :uri)
    end

    test "rejects null byte in URI" do
      assert {:error, :null_byte_in_uri} = Dictionary.validate_term("http://example\0.org", :uri)
    end

    test "rejects null byte at start of URI" do
      assert {:error, :null_byte_in_uri} = Dictionary.validate_term("\0http://example.org", :uri)
    end

    test "rejects null byte at end of URI" do
      assert {:error, :null_byte_in_uri} = Dictionary.validate_term("http://example.org\0", :uri)
    end

    test "allows null byte in blank node" do
      # Blank nodes shouldn't have null bytes in practice, but we don't reject them
      assert :ok = Dictionary.validate_term("_:b\0", :bnode)
    end

    test "allows null byte in literal" do
      # Literals can contain null bytes (binary data in base64, etc.)
      assert :ok = Dictionary.validate_term("data\0here", :literal)
    end

    test "rejects invalid UTF-8" do
      invalid_utf8 = <<0xFF, 0xFE>>
      assert {:error, :invalid_utf8} = Dictionary.validate_term(invalid_utf8, :uri)
    end

    test "accepts valid UTF-8 with Unicode" do
      assert :ok = Dictionary.validate_term("http://example.org/資源", :uri)
    end

    test "accepts emojis" do
      assert :ok = Dictionary.validate_term("Hello 🌍", :literal)
    end
  end

  describe "normalize_unicode/1" do
    test "normalizes composed form" do
      # 'é' as single character (NFC form)
      composed = "café"
      assert Dictionary.normalize_unicode(composed) == composed
    end

    test "normalizes decomposed to composed" do
      # 'é' as 'e' + combining acute accent (NFD form)
      decomposed = "cafe\u0301"
      normalized = Dictionary.normalize_unicode(decomposed)
      # Should be normalized to single 'é' character
      assert String.length(normalized) == 4
      assert normalized == "café"
    end

    test "handles ASCII strings unchanged" do
      ascii = "hello world"
      assert Dictionary.normalize_unicode(ascii) == ascii
    end

    test "handles empty string" do
      assert Dictionary.normalize_unicode("") == ""
    end

    test "handles various Unicode characters" do
      # Test various Unicode blocks
      test_strings = [
        "日本語",
        "العربية",
        "中文",
        "한국어",
        "Ελληνικά",
        "עברית"
      ]

      for string <- test_strings do
        # Should not raise and should return a string
        result = Dictionary.normalize_unicode(string)
        assert is_binary(result)
      end
    end
  end

  describe "term size limits" do
    test "max_term_size is 16KB" do
      assert Dictionary.max_term_size() == 16_384
    end

    test "term size is checked in bytes, not characters" do
      # Each Chinese character is 3 bytes in UTF-8
      # 5461 characters * 3 bytes = 16383 bytes (just under limit)
      chinese_chars = String.duplicate("中", 5461)
      assert :ok = Dictionary.validate_term(chinese_chars, :literal)

      # 5462 characters * 3 bytes = 16386 bytes (over limit)
      too_many_chars = String.duplicate("中", 5462)
      assert {:error, :term_too_large} = Dictionary.validate_term(too_many_chars, :literal)
    end
  end

  describe "edge cases" do
    test "handles binary with only null bytes" do
      nulls = <<0, 0, 0>>
      assert {:error, :null_byte_in_uri} = Dictionary.validate_term(nulls, :uri)
    end

    test "handles very long valid URI" do
      # Just under the limit
      long_uri = "http://example.org/" <> String.duplicate("a", Dictionary.max_term_size() - 20)
      assert :ok = Dictionary.validate_term(long_uri, :uri)
    end

    test "handles URI with Unicode path" do
      uri = "http://example.org/path/to/资源"
      assert :ok = Dictionary.validate_term(uri, :uri)
    end

    test "handles literal with all printable ASCII" do
      printable_ascii = for c <- 32..126, into: "", do: <<c>>
      assert :ok = Dictionary.validate_term(printable_ascii, :literal)
    end
  end
end
