defmodule TripleStore.Dictionary do
  @moduledoc """
  Dictionary encoding for RDF terms.

  Maps RDF terms (URIs, blank nodes, literals) to 64-bit integer IDs
  with type tagging. This enables compact storage and fast comparisons.

  ## Type Tags

  The high 4 bits of each ID encode the term type:
  - `0b0001` - URI
  - `0b0010` - Blank node
  - `0b0011` - Literal (dictionary lookup required)
  - `0b0100` - xsd:integer (inline encoded)
  - `0b0101` - xsd:decimal (inline encoded)
  - `0b0110` - xsd:dateTime (inline encoded)

  ## Inline Encoding

  Numeric types that fit within 60 bits are encoded directly in the ID,
  avoiding dictionary lookup for common values like counts and timestamps.
  """

  # Type tag constants (high 4 bits of 64-bit ID)
  @type_uri 0b0001
  @type_bnode 0b0010
  @type_literal 0b0011
  @type_integer 0b0100
  @type_decimal 0b0101
  @type_datetime 0b0110

  @doc "Type tag for URIs"
  def type_uri, do: @type_uri

  @doc "Type tag for blank nodes"
  def type_bnode, do: @type_bnode

  @doc "Type tag for literals requiring dictionary lookup"
  def type_literal, do: @type_literal

  @doc "Type tag for inline-encoded integers"
  def type_integer, do: @type_integer

  @doc "Type tag for inline-encoded decimals"
  def type_decimal, do: @type_decimal

  @doc "Type tag for inline-encoded datetimes"
  def type_datetime, do: @type_datetime
end
